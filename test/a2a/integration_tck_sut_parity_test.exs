defmodule A2A.IntegrationTCKSUTParityTest do
  use ExUnit.Case, async: false

  defmodule TCKSUTExecutor do
    @behaviour A2A.Server.Executor

    def handle_send_message(request, _ctx) do
      task_id = request.message.task_id || "task-1"
      context_id = request.message.context_id || "ctx-1"

      {:ok,
       %A2A.Types.Task{
         id: task_id,
         context_id: context_id,
         status: %A2A.Types.TaskStatus{state: :submitted},
         history: [request.message]
       }}
    end

    def handle_stream_message(request, _ctx, emit) do
      task_id = request.message.task_id || "task-1"
      context_id = request.message.context_id || "ctx-1"

      emit.(%A2A.Types.Task{
        id: task_id,
        context_id: context_id,
        status: %A2A.Types.TaskStatus{state: :submitted}
      })

      emit.(%A2A.Types.TaskStatusUpdateEvent{
        task_id: task_id,
        context_id: context_id,
        status: %A2A.Types.TaskStatus{
          state: :working,
          message: %A2A.Types.Message{
            message_id: "agent-working",
            role: :agent,
            task_id: task_id,
            context_id: context_id,
            parts: [%A2A.Types.TextPart{text: "Processing your question"}]
          }
        },
        final: false
      })

      emit.(%A2A.Types.TaskStatusUpdateEvent{
        task_id: task_id,
        context_id: context_id,
        status: %A2A.Types.TaskStatus{
          state: :input_required,
          message: %A2A.Types.Message{
            message_id: "agent-final",
            role: :agent,
            task_id: task_id,
            context_id: context_id,
            parts: [%A2A.Types.TextPart{text: "Hello world!"}]
          }
        },
        final: true
      })

      {:ok,
       %A2A.Types.Task{
         id: task_id,
         context_id: context_id,
         status: %A2A.Types.TaskStatus{state: :input_required}
       }}
    end

    def handle_get_task(_task_id, _query, _ctx), do: {:error, :not_found}

    def handle_list_tasks(_request, _ctx), do: {:ok, %A2A.Types.ListTasksResponse{tasks: []}}

    def handle_cancel_task(task_id, _ctx) do
      {:ok,
       %A2A.Types.Task{
         id: task_id,
         context_id: "ctx-1",
         status: %A2A.Types.TaskStatus{state: :canceled}
       }}
    end
  end

  test "REST SUT-like streaming emits submitted -> working -> input_required transitions" do
    table = new_store()

    wrapped_executor = wrapped_executor(table)

    plug_opts = [
      executor: wrapped_executor,
      capabilities: %{streaming: true}
    ]

    server = A2A.TestHTTPServer.start(A2A.Server.REST.Plug, plug_opts: plug_opts)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    {:ok, stream} =
      A2A.Client.stream_message(server.base_url,
        message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
      )

    events = Enum.to_list(stream)

    assert Enum.any?(events, fn
             %A2A.Types.StreamResponse{
               task: %A2A.Types.Task{status: %A2A.Types.TaskStatus{state: :submitted}}
             } ->
               true

             _ ->
               false
           end)

    assert Enum.any?(events, fn
             %A2A.Types.StreamResponse{
               status_update: %A2A.Types.TaskStatusUpdateEvent{
                 status: %A2A.Types.TaskStatus{state: :working},
                 final: false
               }
             } ->
               true

             _ ->
               false
           end)

    assert Enum.any?(events, fn
             %A2A.Types.StreamResponse{
               status_update: %A2A.Types.TaskStatusUpdateEvent{
                 status: %A2A.Types.TaskStatus{state: :input_required},
                 final: true
               }
             } ->
               true

             _ ->
               false
           end)
  end

  test "JSON-RPC SUT-like flow supports send -> cancel -> get_task via task store" do
    table = new_store()

    wrapped_executor = wrapped_executor(table)

    plug_opts = [
      executor: wrapped_executor,
      capabilities: %{streaming: true}
    ]

    server = A2A.TestHTTPServer.start(A2A.Server.JSONRPC.Plug, plug_opts: plug_opts)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    {:ok, sent_task} =
      A2A.Client.send_message(
        server.base_url,
        [message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}],
        transport: A2A.Transport.JSONRPC
      )

    assert sent_task.status.state == :submitted

    {:ok, canceled_task} =
      A2A.Client.cancel_task(server.base_url, sent_task.id, transport: A2A.Transport.JSONRPC)

    assert canceled_task.status.state == :canceled

    {:ok, fetched_task} =
      A2A.Client.get_task(server.base_url, sent_task.id, transport: A2A.Transport.JSONRPC)

    assert fetched_task.status.state == :canceled
  end

  defp new_store do
    name =
      String.to_atom("tck_sut_store_" <> Integer.to_string(System.unique_integer([:positive])))

    {:ok, table} = A2A.TaskStore.ETS.init(name: name)
    table
  end

  defp wrapped_executor(table) do
    {A2A.Server.TaskStoreExecutor,
     %{executor: TCKSUTExecutor, task_store: {A2A.TaskStore.ETS, table}}}
  end
end
