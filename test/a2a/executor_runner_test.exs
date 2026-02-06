defmodule A2A.ExecutorRunnerTest do
  use ExUnit.Case, async: true

  defmodule PlainExecutor do
    def handle_send_message(request, ctx), do: {:plain, request, ctx}
  end

  defmodule OptExecutor do
    def handle_send_message(opts, request, ctx), do: {:with_opts, opts, request, ctx}
    def handle_get_task(task_id, ctx), do: {:without_opts, task_id, ctx}
  end

  defmodule LazyTaskExecutor do
    def handle_send_message(request, _ctx) do
      {:ok,
       %A2A.Types.Task{
         id: "task-1",
         context_id: request.message.context_id || "ctx-1",
         status: %A2A.Types.TaskStatus{state: :submitted}
       }}
    end
  end

  test "calls module callback directly for plain executor" do
    assert {:plain, :request, %{foo: :bar}} =
             A2A.Server.ExecutorRunner.call(PlainExecutor, :handle_send_message, [
               :request,
               %{foo: :bar}
             ])
  end

  test "prefers callback arity with executor options" do
    executor = {OptExecutor, %{mode: :strict}}

    assert {:with_opts, %{mode: :strict}, :request, %{foo: :bar}} =
             A2A.Server.ExecutorRunner.call(executor, :handle_send_message, [
               :request,
               %{foo: :bar}
             ])
  end

  test "falls back to callback arity without executor options" do
    executor = {OptExecutor, %{mode: :strict}}

    assert {:without_opts, "task-1", %{foo: :bar}} =
             A2A.Server.ExecutorRunner.call(executor, :handle_get_task, [
               "task-1",
               %{foo: :bar}
             ])
  end

  test "exported? handles tuple and module executors" do
    assert A2A.Server.ExecutorRunner.exported?(PlainExecutor, :handle_send_message, 2)
    refute A2A.Server.ExecutorRunner.exported?(PlainExecutor, :handle_send_message, 3)

    assert A2A.Server.ExecutorRunner.exported?({OptExecutor, %{}}, :handle_send_message, 2)
    assert A2A.Server.ExecutorRunner.exported?({OptExecutor, %{}}, :handle_get_task, 2)
    refute A2A.Server.ExecutorRunner.exported?({OptExecutor, %{}}, :does_not_exist, 1)
  end

  test "supports lazily loaded modules when selecting arity" do
    assert Code.ensure_loaded?(A2A.Server.TaskStoreExecutor)

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    assert {:ok, %A2A.Types.Task{id: "task-1"}} =
             A2A.Server.ExecutorRunner.call(
               {A2A.Server.TaskStoreExecutor, %{executor: LazyTaskExecutor, task_store: nil}},
               :handle_send_message,
               [request, %{}]
             )
  end
end
