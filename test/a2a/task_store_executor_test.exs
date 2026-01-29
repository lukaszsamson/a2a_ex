defmodule A2A.TaskStoreExecutorTest do
  use ExUnit.Case, async: true

  defmodule StubExecutor do
    @behaviour A2A.Server.Executor

    def handle_send_message(request, _ctx) do
      {:ok,
       %A2A.Types.Task{
         id: "task-1",
         context_id: request.message.context_id,
         status: %A2A.Types.TaskStatus{state: :submitted}
       }}
    end

    def handle_get_task(_task_id, _query, _ctx),
      do: {:error, A2A.Error.new(:task_not_found, "missing")}

    def handle_list_tasks(_request, _ctx), do: {:ok, %A2A.Types.ListTasksResponse{tasks: []}}

    def handle_cancel_task(_task_id, _ctx),
      do: {:error, A2A.Error.new(:task_not_found, "missing")}
  end

  defmodule NotFoundExecutor do
    def handle_get_task(_task_id, _query, _ctx), do: {:error, :not_found}
  end

  defmodule PushConfigExecutor do
    def handle_push_notification_config_set(_task_id, config, _ctx) do
      send(self(), {:push_config_set, config})
      {:ok, config}
    end
  end

  defmodule UpdateExecutor do
    def handle_stream_message(_request, _ctx, emit) do
      emit.(%A2A.Types.TaskStatusUpdateEvent{
        task_id: "task-1",
        context_id: "ctx-1",
        status: %A2A.Types.TaskStatus{state: :working},
        final: false
      })

      emit.(%A2A.Types.TaskStatusUpdateEvent{
        task_id: "task-1",
        context_id: "ctx-1",
        status: %A2A.Types.TaskStatus{state: :completed},
        final: true
      })

      {:ok,
       %A2A.Types.Task{
         id: "task-1",
         context_id: "ctx-1",
         status: %A2A.Types.TaskStatus{state: :completed}
       }}
    end
  end

  defmodule ConcurrentUpdateExecutor do
    def handle_stream_message(_request, _ctx, emit) do
      parent = self()

      updates =
        [
          %A2A.Types.TaskStatusUpdateEvent{
            task_id: "task-1",
            context_id: "ctx-1",
            status: %A2A.Types.TaskStatus{state: :working},
            final: false
          },
          %A2A.Types.TaskArtifactUpdateEvent{
            task_id: "task-1",
            context_id: "ctx-1",
            artifact: %A2A.Types.Artifact{artifact_id: "art-1", parts: []},
            append: true,
            last_chunk: false
          }
        ]

      updates
      |> Task.async_stream(fn event -> emit.(event) end, max_concurrency: 2)
      |> Enum.each(fn result -> send(parent, {:update_result, result}) end)

      {:ok,
       %A2A.Types.Task{
         id: "task-1",
         context_id: "ctx-1",
         status: %A2A.Types.TaskStatus{state: :working}
       }}
    end
  end

  defmodule HistoryExecutor do
    def handle_send_message(_request, _ctx) do
      {:ok,
       %A2A.Types.Task{
         id: "task-1",
         context_id: "ctx-1",
         status: %A2A.Types.TaskStatus{state: :submitted},
         history: [
           %A2A.Types.Message{message_id: "m1", role: :user, parts: []},
           %A2A.Types.Message{message_id: "m2", role: :agent, parts: []},
           %A2A.Types.Message{message_id: "m3", role: :agent, parts: []}
         ]
       }}
    end
  end

  test "generates context id and stores task" do
    table = new_store()
    opts = %{executor: StubExecutor, task_store: {A2A.TaskStore.ETS, table}}

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    {:ok, task} = A2A.Server.TaskStoreExecutor.handle_send_message(opts, request, %{})
    assert is_binary(task.context_id)

    {:ok, stored} = A2A.TaskStore.ETS.get_task(table, task.id)
    assert stored.context_id == task.context_id
  end

  test "rejects terminal task references" do
    table = new_store()
    opts = %{executor: StubExecutor, task_store: {A2A.TaskStore.ETS, table}}

    terminal = %A2A.Types.Task{
      id: "task-1",
      context_id: "ctx-1",
      status: %A2A.Types.TaskStatus{state: :completed}
    }

    :ok = A2A.TaskStore.ETS.put_task(table, terminal)

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, task_id: "task-1", parts: []}
    }

    assert {:error, %A2A.Error{type: :unsupported_operation}} =
             A2A.Server.TaskStoreExecutor.handle_send_message(opts, request, %{})
  end

  test "maps :not_found from executor to task_not_found" do
    table = new_store()
    opts = %{executor: NotFoundExecutor, task_store: {A2A.TaskStore.ETS, table}}

    assert {:error, %A2A.Error{type: :task_not_found}} =
             A2A.Server.TaskStoreExecutor.handle_get_task(opts, "missing", %{}, %{})
  end

  test "rejects insecure push notification config" do
    table = new_store()
    opts = %{executor: PushConfigExecutor, task_store: {A2A.TaskStore.ETS, table}}

    config = %{"url" => "http://example.com/webhook"}

    assert {:error, %A2A.Error{type: :invalid_agent_response}} =
             A2A.Server.TaskStoreExecutor.handle_push_notification_config_set(
               opts,
               "task-1",
               config,
               %{}
             )

    refute_received {:push_config_set, _}
  end

  test "allows http push notification config when enabled" do
    table = new_store()

    opts = %{
      executor: PushConfigExecutor,
      task_store: {A2A.TaskStore.ETS, table},
      allow_http: true
    }

    config = %{"url" => "http://example.com/webhook"}

    assert {:ok, ^config} =
             A2A.Server.TaskStoreExecutor.handle_push_notification_config_set(
               opts,
               "task-1",
               config,
               %{}
             )

    assert_received {:push_config_set, ^config}
  end

  test "rejects push config when security strict" do
    table = new_store()

    opts = %{
      executor: PushConfigExecutor,
      task_store: {A2A.TaskStore.ETS, table},
      push_security: [strict: true]
    }

    config = %{"url" => "https://127.0.0.1/webhook"}

    assert {:error, %A2A.Error{type: :invalid_agent_response}} =
             A2A.Server.TaskStoreExecutor.handle_push_notification_config_set(
               opts,
               "task-1",
               config,
               %{}
             )
  end

  test "trims task history by history_length" do
    table = new_store()
    opts = %{executor: HistoryExecutor, task_store: {A2A.TaskStore.ETS, table}}

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []},
      configuration: %A2A.Types.SendMessageConfiguration{history_length: 2}
    }

    {:ok, task} = A2A.Server.TaskStoreExecutor.handle_send_message(opts, request, %{})

    assert [%A2A.Types.Message{message_id: "m1"}, %A2A.Types.Message{message_id: "m2"}] =
             task.history
  end

  test "applies latest status update to stored task" do
    table = new_store()

    initial = %A2A.Types.Task{
      id: "task-1",
      context_id: "ctx-1",
      status: %A2A.Types.TaskStatus{state: :submitted}
    }

    :ok = A2A.TaskStore.ETS.put_task(table, initial)
    opts = %{executor: UpdateExecutor, task_store: {A2A.TaskStore.ETS, table}}

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    {:ok, _task} =
      A2A.Server.TaskStoreExecutor.handle_stream_message(opts, request, %{}, fn _ -> :ok end)

    {:ok, stored} = A2A.TaskStore.ETS.get_task(table, "task-1")
    assert stored.status.state == :completed
  end

  test "handles concurrent status and artifact updates" do
    table = new_store()

    initial = %A2A.Types.Task{
      id: "task-1",
      context_id: "ctx-1",
      status: %A2A.Types.TaskStatus{state: :submitted},
      artifacts: []
    }

    :ok = A2A.TaskStore.ETS.put_task(table, initial)
    opts = %{executor: ConcurrentUpdateExecutor, task_store: {A2A.TaskStore.ETS, table}}

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    {:ok, _task} =
      A2A.Server.TaskStoreExecutor.handle_stream_message(opts, request, %{}, fn _ -> :ok end)

    assert_receive {:update_result, {:ok, :ok}}
    assert_receive {:update_result, {:ok, :ok}}

    {:ok, stored} = A2A.TaskStore.ETS.get_task(table, "task-1")
    assert stored.status.state == :working
    assert [%A2A.Types.Artifact{artifact_id: "art-1"}] = stored.artifacts
  end

  defp new_store do
    name =
      String.to_atom("task_store_exec_" <> Integer.to_string(System.unique_integer([:positive])))

    {:ok, table} = A2A.TaskStore.ETS.init(name: name)
    table
  end
end
