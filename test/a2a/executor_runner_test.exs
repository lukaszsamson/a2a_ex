defmodule A2A.ExecutorRunnerTest do
  use ExUnit.Case, async: true

  defmodule PlainExecutor do
    def handle_send_message(request, ctx), do: {:plain, request, ctx}
  end

  defmodule OptExecutor do
    def handle_send_message(opts, request, ctx), do: {:with_opts, opts, request, ctx}
    def handle_get_task(task_id, ctx), do: {:without_opts, task_id, ctx}
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
end
