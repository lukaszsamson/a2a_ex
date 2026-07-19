defmodule A2A.V1TCKExecutor do
  @moduledoc false

  def start_link do
    case Agent.start_link(
           fn -> %{push_configs: %{}, task_ids: MapSet.new(), subscribers: %{}} end,
           name: __MODULE__
         ) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
  end

  def handle_send_message(request, _ctx) do
    message_id = request.message.message_id

    if String.contains?(message_id, "message-response") do
      {:ok,
       %A2A.Types.Message{
         message_id: A2A.Context.generate_id(),
         context_id: request.message.context_id || A2A.Context.generate_id(),
         role: :agent,
         parts: [%A2A.Types.Part{text: "Direct message response"}]
       }}
    else
      task_response(request, message_id)
    end
  end

  defp task_response(request, message_id) do
    task_id = request.message.task_id || A2A.Context.generate_id()
    context_id = request.message.context_id || A2A.Context.generate_id()
    return_immediately = request.configuration && request.configuration.return_immediately

    state =
      cond do
        String.contains?(message_id, "input-required") -> :input_required
        return_immediately -> :working
        true -> :completed
      end

    Agent.update(__MODULE__, &update_in(&1, [:task_ids], fn ids -> MapSet.put(ids, task_id) end))

    if state == :completed and request.message.task_id do
      broadcast(task_id, context_id, :completed)
    end

    {:ok,
     %A2A.Types.Task{
       id: task_id,
       context_id: context_id,
       status: %A2A.Types.TaskStatus{state: state, timestamp: DateTime.utc_now()},
       history: [request.message],
       artifacts: [
         %A2A.Types.Artifact{
           artifact_id: A2A.Context.generate_id(),
           name: "echo",
           parts: artifact_parts(message_id)
         }
       ]
     }}
  end

  defp artifact_parts(message_id) do
    cond do
      String.contains?(message_id, "artifact-file-url") ->
        [
          %A2A.Types.Part{
            url: "https://example.com/output.txt",
            filename: "output.txt",
            media_type: "text/plain"
          }
        ]

      String.contains?(message_id, "artifact-file") ->
        [
          %A2A.Types.Part{
            raw: Base.encode64("Generated file content"),
            filename: "output.txt",
            media_type: "text/plain"
          }
        ]

      String.contains?(message_id, "artifact-data") ->
        [%A2A.Types.Part{data: %{"key" => "value", "count" => 42}}]

      true ->
        [%A2A.Types.Part{text: "Generated text content"}]
    end
  end

  def handle_stream_message(request, _ctx, emit) do
    task_id = request.message.task_id || A2A.Context.generate_id()
    context_id = request.message.context_id || A2A.Context.generate_id()

    task = %A2A.Types.Task{
      id: task_id,
      context_id: context_id,
      status: %A2A.Types.TaskStatus{state: :working, timestamp: DateTime.utc_now()},
      history: [request.message]
    }

    emit.(task)

    completed = %A2A.Types.TaskStatus{
      state: :completed,
      timestamp: DateTime.utc_now()
    }

    emit.(%A2A.Types.TaskStatusUpdateEvent{
      task_id: task_id,
      context_id: context_id,
      status: completed
    })

    {:ok, %{task | status: completed}}
  end

  def handle_get_task(_task_id, _query, _ctx), do: {:error, :not_found}

  def handle_cancel_task(task_id, _ctx) do
    if Agent.get(__MODULE__, &MapSet.member?(&1.task_ids, task_id)) do
      {:ok,
       %A2A.Types.Task{
         id: task_id,
         status: %A2A.Types.TaskStatus{state: :canceled, timestamp: DateTime.utc_now()}
       }}
    else
      {:error, :not_found}
    end
  end

  def handle_subscribe(task_id, _ctx, emit) do
    ref = make_ref()
    subscriber = {ref, self(), emit}

    Agent.update(__MODULE__, fn state ->
      update_in(state, [:subscribers, task_id], fn subscribers ->
        [subscriber | subscribers || []]
      end)
    end)

    receive do
      {:a2a_tck_complete, ^ref} -> {:ok, :subscribed}
    after
      5_000 -> {:ok, :subscribed}
    end
  end

  defp broadcast(task_id, context_id, state) do
    subscribers = Agent.get(__MODULE__, &(get_in(&1, [:subscribers, task_id]) || []))

    event = %A2A.Types.TaskStatusUpdateEvent{
      task_id: task_id,
      context_id: context_id,
      status: %A2A.Types.TaskStatus{state: state, timestamp: DateTime.utc_now()}
    }

    Enum.each(subscribers, fn {ref, pid, emit} ->
      emit.(event)
      send(pid, {:a2a_tck_complete, ref})
    end)

    Agent.update(__MODULE__, &put_in(&1, [:subscribers, task_id], []))
  end

  def handle_push_notification_config_set(task_id, config, _ctx) do
    config = %{config | id: config.id || A2A.Context.generate_id(), task_id: task_id}
    Agent.update(__MODULE__, &put_in(&1, [:push_configs, {task_id, config.id}], config))
    {:ok, config}
  end

  def handle_push_notification_config_get(task_id, config_id, _ctx) do
    case Agent.get(__MODULE__, &get_in(&1, [:push_configs, {task_id, config_id}])) do
      nil -> {:error, A2A.Error.new(:task_not_found, "Push config not found")}
      config -> {:ok, config}
    end
  end

  def handle_push_notification_config_list(task_id, _query, _ctx) do
    configs =
      Agent.get(__MODULE__, fn state ->
        for {{stored_task_id, _id}, config} <- state.push_configs,
            stored_task_id == task_id,
            do: config
      end)

    {:ok, %A2A.Types.ListTaskPushNotificationConfigsResponse{configs: configs}}
  end

  def handle_push_notification_config_delete(task_id, config_id, _ctx) do
    Agent.update(
      __MODULE__,
      &update_in(&1, [:push_configs], fn configs -> Map.delete(configs, {task_id, config_id}) end)
    )

    :ok
  end
end
