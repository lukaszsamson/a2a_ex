defmodule A2A.TestExecutor do
  @moduledoc false

  @behaviour A2A.Server.Executor

  def handle_send_message(_request, _ctx) do
    {:ok,
     %A2A.Types.Task{
       id: "task-1",
       context_id: "ctx-1",
       status: %A2A.Types.TaskStatus{state: :submitted}
     }}
  end

  def handle_stream_message(_request, _ctx, emit) do
    emit.(%A2A.Types.TaskStatusUpdateEvent{
      task_id: "task-1",
      context_id: "ctx-1",
      status: %A2A.Types.TaskStatus{state: :working},
      final: false
    })

    {:ok,
     %A2A.Types.Task{
       id: "task-1",
       context_id: "ctx-1",
       status: %A2A.Types.TaskStatus{state: :submitted}
     }}
  end

  def handle_get_task(task_id, _query, _ctx) do
    {:ok,
     %A2A.Types.Task{
       id: task_id,
       context_id: "ctx-1",
       status: %A2A.Types.TaskStatus{state: :completed}
     }}
  end

  def handle_list_tasks(_request, _ctx) do
    {:ok,
     %A2A.Types.ListTasksResponse{
       tasks: [
         %A2A.Types.Task{
           id: "task-1",
           context_id: "ctx-1",
           status: %A2A.Types.TaskStatus{state: :completed}
         }
       ]
     }}
  end

  def handle_cancel_task(task_id, _ctx) do
    {:ok,
     %A2A.Types.Task{
       id: task_id,
       context_id: "ctx-1",
       status: %A2A.Types.TaskStatus{state: :canceled}
     }}
  end

  def handle_subscribe(_task_id, _ctx, _emit), do: {:ok, :subscribed}

  def handle_resubscribe(_task_id, _resume, _ctx, emit) do
    emit.(%A2A.Types.TaskStatusUpdateEvent{
      task_id: "task-1",
      context_id: "ctx-1",
      status: %A2A.Types.TaskStatus{state: :working},
      final: false
    })

    {:ok, :subscribed}
  end

  def handle_push_notification_config_set(
        _task_id,
        %A2A.Types.PushNotificationConfig{} = config,
        _ctx
      ) do
    {:ok, %{config | id: config.id || "cfg-1"}}
  end

  def handle_push_notification_config_get(_task_id, config_id, _ctx) do
    {:ok, %A2A.Types.PushNotificationConfig{id: config_id, url: "https://example.com/webhook"}}
  end

  def handle_push_notification_config_list(_task_id, _query, _ctx) do
    {:ok, [%A2A.Types.PushNotificationConfig{id: "cfg-1", url: "https://example.com/webhook"}]}
  end

  def handle_push_notification_config_delete(_task_id, _config_id, _ctx), do: :ok

  def handle_get_extended_agent_card(_ctx) do
    {:ok,
     %A2A.Types.AgentCard{
       name: "extended",
       capabilities: %A2A.Types.AgentCapabilities{streaming: true}
     }}
  end
end
