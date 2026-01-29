defmodule A2A.IntegrationRESTTest do
  use ExUnit.Case, async: false

  defmodule SlowStreamExecutor do
    def handle_stream_message(_request, _ctx, emit) do
      emit.(%A2A.Types.Task{
        id: "task-1",
        context_id: "ctx-1",
        status: %A2A.Types.TaskStatus{state: :submitted}
      })

      Process.sleep(500)

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
  end

  setup_all do
    plug_opts = [executor: A2A.TestExecutor, capabilities: %{streaming: true}]

    server = A2A.TestHTTPServer.start(A2A.Server.REST.Plug, plug_opts: plug_opts)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)
    {:ok, base_url: server.base_url}
  end

  test "client sends message and lists tasks", %{base_url: base_url} do
    {:ok, task} =
      A2A.Client.send_message(base_url,
        message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
      )

    assert task.id == "task-1"

    {:ok, response} = A2A.Client.list_tasks(base_url, %A2A.Types.ListTasksRequest{})
    assert [%A2A.Types.Task{}] = response.tasks
  end

  test "client streams message", %{base_url: base_url} do
    {:ok, stream} =
      A2A.Client.stream_message(base_url,
        message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
      )

    events = Enum.to_list(stream)

    assert [%A2A.Types.StreamResponse{task: %A2A.Types.Task{id: "task-1"}} | _] = events

    assert Enum.any?(events, fn event ->
             match?(
               %A2A.Types.StreamResponse{status_update: %A2A.Types.TaskStatusUpdateEvent{}},
               event
             )
           end)
  end

  test "stream emits before handler completion" do
    plug_opts = [executor: SlowStreamExecutor, capabilities: %{streaming: true}]
    server = A2A.TestHTTPServer.start(A2A.Server.REST.Plug, plug_opts: plug_opts)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    start_time = System.monotonic_time(:millisecond)

    {:ok, stream} =
      A2A.Client.stream_message(server.base_url,
        message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
      )

    [event] = Enum.take(stream, 1)
    elapsed_ms = System.monotonic_time(:millisecond) - start_time

    assert match?(%A2A.Types.StreamResponse{task: %A2A.Types.Task{}}, event)

    assert elapsed_ms < 300
  end
end
