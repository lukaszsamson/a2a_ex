defmodule A2A.TaskStoreETSTest do
  use ExUnit.Case, async: true

  test "lists tasks with pagination and filters" do
    name = String.to_atom("task_store_" <> Integer.to_string(System.unique_integer([:positive])))
    {:ok, table} = A2A.TaskStore.ETS.init(name: name)

    now = DateTime.utc_now()
    earlier = DateTime.add(now, -60, :second)

    task1 = %A2A.Types.Task{
      id: "task-1",
      context_id: "ctx-1",
      status: %A2A.Types.TaskStatus{state: :working, timestamp: earlier},
      artifacts: [%A2A.Types.Artifact{artifact_id: "art-1", parts: []}]
    }

    task2 = %A2A.Types.Task{
      id: "task-2",
      context_id: "ctx-1",
      status: %A2A.Types.TaskStatus{state: :completed, timestamp: now},
      artifacts: [%A2A.Types.Artifact{artifact_id: "art-2", parts: []}]
    }

    :ok = A2A.TaskStore.ETS.put_task(table, task1)
    :ok = A2A.TaskStore.ETS.put_task(table, task2)

    {:ok, result} = A2A.TaskStore.ETS.list_tasks(table, %{"pageSize" => 1})
    assert [first] = result.tasks
    assert first.id == "task-2"
    assert result.next_page_token == "#{DateTime.to_unix(now, :millisecond)}:task-2"
    assert result.total_size == 2

    {:ok, result} =
      A2A.TaskStore.ETS.list_tasks(table, %{
        "pageSize" => 1,
        "pageToken" => result.next_page_token
      })

    assert [%A2A.Types.Task{id: "task-1"}] = result.tasks

    {:ok, result} =
      A2A.TaskStore.ETS.list_tasks(table, %{"status" => "working", "includeArtifacts" => false})

    assert [%A2A.Types.Task{id: "task-1", artifacts: nil}] = result.tasks

    {:ok, result} =
      A2A.TaskStore.ETS.list_tasks(table, %{"updatedAfter" => DateTime.to_iso8601(earlier)})

    assert [%A2A.Types.Task{id: "task-2"}] = result.tasks

    {:ok, result} =
      A2A.TaskStore.ETS.list_tasks(table, %{
        "pageSize" => 1,
        "updatedAfter" => DateTime.to_iso8601(earlier)
      })

    assert [%A2A.Types.Task{id: "task-2"}] = result.tasks
    assert result.next_page_token == nil
  end

  test "handles concurrent updates" do
    name = String.to_atom("task_store_" <> Integer.to_string(System.unique_integer([:positive])))
    {:ok, table} = A2A.TaskStore.ETS.init(name: name)

    task = %A2A.Types.Task{
      id: "task-1",
      context_id: "ctx-1",
      status: %A2A.Types.TaskStatus{state: :submitted}
    }

    :ok = A2A.TaskStore.ETS.put_task(table, task)

    states = [:working, :completed, :canceled, :rejected, :failed]

    results =
      states
      |> Task.async_stream(
        fn state ->
          A2A.TaskStore.ETS.update_task(table, "task-1", fn task ->
            %{task | status: %A2A.Types.TaskStatus{state: state}}
          end)
        end,
        max_concurrency: 5
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn
             {:ok, {:ok, %A2A.Types.Task{}}} -> true
             _ -> false
           end)

    {:ok, updated} = A2A.TaskStore.ETS.get_task(table, "task-1")
    assert updated.status.state in states
  end

  test "handles concurrent updates to different tasks" do
    name = String.to_atom("task_store_" <> Integer.to_string(System.unique_integer([:positive])))
    {:ok, table} = A2A.TaskStore.ETS.init(name: name)

    tasks =
      for index <- 1..10 do
        %A2A.Types.Task{
          id: "task-#{index}",
          context_id: "ctx-#{index}",
          status: %A2A.Types.TaskStatus{state: :submitted}
        }
      end

    Enum.each(tasks, &A2A.TaskStore.ETS.put_task(table, &1))

    results =
      tasks
      |> Task.async_stream(
        fn task ->
          A2A.TaskStore.ETS.update_task(table, task.id, fn stored ->
            %{stored | status: %A2A.Types.TaskStatus{state: :working}}
          end)
        end,
        max_concurrency: 5
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn
             {:ok, {:ok, %A2A.Types.Task{status: %A2A.Types.TaskStatus{state: :working}}}} -> true
             _ -> false
           end)

    for task <- tasks do
      assert {:ok, %A2A.Types.Task{status: %A2A.Types.TaskStatus{state: :working}}} =
               A2A.TaskStore.ETS.get_task(table, task.id)
    end
  end

  test "handles concurrent updates and list" do
    name = String.to_atom("task_store_" <> Integer.to_string(System.unique_integer([:positive])))
    {:ok, table} = A2A.TaskStore.ETS.init(name: name)

    task = %A2A.Types.Task{
      id: "task-1",
      context_id: "ctx-1",
      status: %A2A.Types.TaskStatus{state: :submitted, timestamp: DateTime.utc_now()}
    }

    :ok = A2A.TaskStore.ETS.put_task(table, task)

    update_task =
      Task.async(fn ->
        Enum.each(1..20, fn _ ->
          A2A.TaskStore.ETS.update_task(table, "task-1", fn stored ->
            %{
              stored
              | status: %A2A.Types.TaskStatus{state: :working, timestamp: DateTime.utc_now()}
            }
          end)
        end)
      end)

    list_results =
      Task.async(fn ->
        Enum.map(1..10, fn _ -> A2A.TaskStore.ETS.list_tasks(table, %{}) end)
      end)

    Task.await(update_task)
    results = Task.await(list_results)

    assert Enum.all?(results, fn
             {:ok, %{tasks: tasks}} when is_list(tasks) -> true
             _ -> false
           end)
  end
end
