defmodule A2A.Server.TaskStoreExecutor do
  @moduledoc """
  Wraps executor callbacks to persist tasks in a task store.
  """

  @spec handle_send_message(map() | keyword(), A2A.Types.SendMessageRequest.t(), map()) ::
          {:ok, A2A.Types.Task.t() | A2A.Types.Message.t()} | {:error, A2A.Error.t()}
  def handle_send_message(opts, %A2A.Types.SendMessageRequest{} = request, ctx) do
    {message, context_id} = A2A.Context.ensure_context_id(request.message)
    request = %{request | message: message}

    history_length = request.configuration && request.configuration.history_length

    with :ok <- ensure_not_terminal(opts, message.task_id),
         {:ok, response} <- delegate(opts, :handle_send_message, [request, ctx]) do
      response = response |> ensure_response_context(context_id) |> limit_history(history_length)
      store_response(opts, response)
      {:ok, response}
    end
  end

  @spec handle_stream_message(
          map() | keyword(),
          A2A.Types.SendMessageRequest.t(),
          map(),
          (term() -> :ok)
        ) :: {:ok, A2A.Types.Task.t() | A2A.Types.Message.t()} | {:error, A2A.Error.t()}
  def handle_stream_message(opts, %A2A.Types.SendMessageRequest{} = request, ctx, emit) do
    {message, context_id} = A2A.Context.ensure_context_id(request.message)
    request = %{request | message: message}

    emit = fn event ->
      store_event(opts, event)
      emit.(event)
    end

    history_length = request.configuration && request.configuration.history_length

    with :ok <- ensure_not_terminal(opts, message.task_id),
         {:ok, response} <- delegate(opts, :handle_stream_message, [request, ctx, emit]) do
      response = response |> ensure_response_context(context_id) |> limit_history(history_length)
      store_response(opts, response)
      {:ok, response}
    end
  end

  @spec handle_get_task(map() | keyword(), String.t(), keyword() | map(), map()) ::
          {:ok, A2A.Types.Task.t()} | {:error, A2A.Error.t()}
  def handle_get_task(opts, task_id, query, ctx) do
    case get_task(opts, task_id) do
      {:ok, task} ->
        {:ok, apply_history_limit(task, query)}

      {:error, :not_found} ->
        delegate(opts, :handle_get_task, [task_id, query, ctx])
        |> normalize_not_found()

      {:error, error} ->
        {:error, error}
    end
  end

  @spec handle_list_tasks(map() | keyword(), A2A.Types.ListTasksRequest.t(), map()) ::
          {:ok, A2A.Types.ListTasksResponse.t()} | {:error, A2A.Error.t()}
  def handle_list_tasks(opts, request, _ctx) do
    query = A2A.Types.ListTasksRequest.to_map(request, version: :v0_3)

    case list_tasks(opts, query) do
      {:ok, %{tasks: tasks, next_page_token: token, total_size: total_size}} ->
        {:ok,
         %A2A.Types.ListTasksResponse{
           tasks: tasks,
           next_page_token: token,
           total_size: total_size
         }}

      {:ok, %{tasks: tasks, next_page_token: token}} ->
        {:ok, %A2A.Types.ListTasksResponse{tasks: tasks, next_page_token: token}}

      {:error, error} ->
        {:error, error}
    end
  end

  @spec handle_cancel_task(map() | keyword(), String.t(), map()) ::
          {:ok, A2A.Types.Task.t()} | {:error, A2A.Error.t()}
  def handle_cancel_task(opts, task_id, ctx) do
    case get_task(opts, task_id) do
      {:ok, task} ->
        if A2A.TaskState.terminal?(task.status.state) do
          {:error, A2A.Error.new(:task_not_cancelable, "Task is terminal")}
        else
          with {:ok, response} <- delegate(opts, :handle_cancel_task, [task_id, ctx]) do
            store_response(opts, response)
            {:ok, response}
          end
        end

      {:error, :not_found} ->
        delegate(opts, :handle_cancel_task, [task_id, ctx])

      {:error, error} ->
        {:error, error}
    end
  end

  @spec handle_subscribe(map() | keyword(), String.t(), map(), (term() -> :ok)) ::
          {:ok, :subscribed} | {:error, A2A.Error.t()}
  def handle_subscribe(opts, task_id, ctx, emit) do
    emit = fn event ->
      store_event(opts, event)
      emit.(event)
    end

    delegate(opts, :handle_subscribe, [task_id, ctx, emit])
  end

  @spec handle_resubscribe(map() | keyword(), String.t(), map(), map(), (term() -> :ok)) ::
          {:ok, :subscribed} | {:error, A2A.Error.t()}
  def handle_resubscribe(opts, task_id, resume, ctx, emit) do
    emit = fn event ->
      store_event(opts, event)
      emit.(event)
    end

    delegate(opts, :handle_resubscribe, [task_id, resume, ctx, emit])
  end

  @spec handle_push_notification_config_set(
          map() | keyword(),
          String.t(),
          map(),
          map()
        ) :: {:ok, map()} | {:error, A2A.Error.t()}
  def handle_push_notification_config_set(opts, task_id, config, ctx) do
    with :ok <- validate_push_config(opts, config) do
      delegate(opts, :handle_push_notification_config_set, [task_id, config, ctx])
    end
  end

  @spec handle_push_notification_config_get(
          map() | keyword(),
          String.t(),
          String.t(),
          map()
        ) :: {:ok, map()} | {:error, A2A.Error.t()}
  def handle_push_notification_config_get(opts, task_id, config_id, ctx) do
    delegate(opts, :handle_push_notification_config_get, [task_id, config_id, ctx])
  end

  @spec handle_push_notification_config_list(
          map() | keyword(),
          String.t(),
          map(),
          map()
        ) :: {:ok, list()} | {:error, A2A.Error.t()}
  def handle_push_notification_config_list(opts, task_id, query, ctx) do
    delegate(opts, :handle_push_notification_config_list, [task_id, query, ctx])
  end

  @spec handle_push_notification_config_delete(
          map() | keyword(),
          String.t(),
          String.t(),
          map()
        ) :: :ok | {:error, A2A.Error.t()}
  def handle_push_notification_config_delete(opts, task_id, config_id, ctx) do
    delegate(opts, :handle_push_notification_config_delete, [task_id, config_id, ctx])
  end

  @spec handle_get_extended_agent_card(map() | keyword(), map()) ::
          {:ok, A2A.Types.AgentCard.t()} | {:error, A2A.Error.t()}
  def handle_get_extended_agent_card(opts, ctx) do
    delegate(opts, :handle_get_extended_agent_card, [ctx])
  end

  defp delegate(opts, fun, args) do
    executor = fetch_opt(opts, :executor)
    A2A.Server.ExecutorRunner.call(executor, fun, args)
  end

  defp ensure_not_terminal(_opts, nil), do: :ok

  defp ensure_not_terminal(opts, task_id) do
    case get_task(opts, task_id) do
      {:ok, %A2A.Types.Task{status: %A2A.Types.TaskStatus{state: state}}} ->
        if A2A.TaskState.terminal?(state) do
          {:error, A2A.Error.new(:unsupported_operation, "Task is terminal")}
        else
          :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp get_task(opts, task_id) do
    with {:ok, {store_module, store}} <- fetch_store(opts) do
      store_module.get_task(store, task_id)
    end
  end

  defp list_tasks(opts, query) do
    with {:ok, {store_module, store}} <- fetch_store(opts) do
      store_module.list_tasks(store, query)
    end
  end

  defp store_response(opts, %A2A.Types.Task{} = task) do
    with {:ok, {store_module, store}} <- fetch_store(opts) do
      task =
        case store_module.get_task(store, task.id) do
          {:ok, existing} -> merge_task(existing, task)
          _ -> task
        end

      store_module.put_task(store, task)
    end
  end

  defp store_response(_opts, _response), do: :ok

  defp store_event(opts, %A2A.Types.Task{} = task), do: store_response(opts, task)

  defp store_event(opts, %A2A.Types.TaskStatusUpdateEvent{task_id: task_id, status: status}) do
    with {:ok, {store_module, store}} <- fetch_store(opts) do
      store_module.update_task(store, task_id, fn task -> %{task | status: status} end)
    end
  end

  defp store_event(opts, %A2A.Types.TaskArtifactUpdateEvent{task_id: task_id, artifact: artifact}) do
    with {:ok, {store_module, store}} <- fetch_store(opts) do
      store_module.update_task(store, task_id, fn task ->
        artifacts = task.artifacts || []
        %{task | artifacts: artifacts ++ [artifact]}
      end)
    end
  end

  defp store_event(_opts, _event), do: :ok

  defp merge_task(%A2A.Types.Task{} = existing, %A2A.Types.Task{} = task) do
    %A2A.Types.Task{
      task
      | context_id: task.context_id || existing.context_id,
        status: task.status || existing.status,
        artifacts: if(task.artifacts == nil, do: existing.artifacts, else: task.artifacts),
        history: if(task.history == nil, do: existing.history, else: task.history),
        metadata: task.metadata || existing.metadata
    }
  end

  defp ensure_response_context(%A2A.Types.Task{} = task, context_id) do
    case task.context_id do
      nil -> %{task | context_id: context_id}
      _ -> task
    end
  end

  defp ensure_response_context(%A2A.Types.Message{} = message, context_id) do
    case message.context_id do
      nil -> %{message | context_id: context_id}
      _ -> message
    end
  end

  defp ensure_response_context(response, _context_id), do: response

  defp limit_history(%A2A.Types.Task{} = task, nil), do: task

  defp limit_history(%A2A.Types.Task{} = task, history_length)
       when is_integer(history_length) and history_length >= 0 do
    history = task.history || []
    %{task | history: Enum.take(history, history_length)}
  end

  defp limit_history(task, _history_length), do: task

  defp apply_history_limit(%A2A.Types.Task{} = task, query) do
    history_length =
      case query do
        %{history_length: value} -> value
        %{"history_length" => value} -> value
        %{"historyLength" => value} -> value
        _ -> nil
      end

    if is_integer(history_length) and history_length >= 0 do
      history = task.history || []
      %{task | history: Enum.take(history, history_length)}
    else
      task
    end
  end

  defp apply_history_limit(task, _query), do: task

  defp fetch_store(opts) do
    case fetch_opt(opts, :task_store) do
      {module, store} when is_atom(module) -> {:ok, {module, store}}
      nil -> {:error, A2A.Error.new(:invalid_agent_response, "Task store not configured")}
      _ -> {:error, A2A.Error.new(:invalid_agent_response, "Invalid task store")}
    end
  end

  defp normalize_not_found({:error, :not_found}) do
    {:error, A2A.Error.new(:task_not_found, "Task not found")}
  end

  defp normalize_not_found(result), do: result

  defp validate_push_config(opts, config) do
    allow_http = fetch_opt(opts, :allow_http) || false
    security_opts = fetch_opt(opts, :push_security) || []
    security_opts = Keyword.put_new(security_opts, :allow_http, allow_http)

    url =
      case config do
        %A2A.Types.PushNotificationConfig{url: url} -> url
        %{} -> Map.get(config, :url) || Map.get(config, "url")
        _ -> nil
      end

    A2A.Server.Push.Security.validate_destination(url, security_opts)
  end

  defp fetch_opt(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp fetch_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
end
