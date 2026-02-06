defmodule A2A.TaskStoreContractTest do
  use ExUnit.Case, async: true

  defp new_ets_store do
    name = String.to_atom("task_store_contract_" <> Integer.to_string(System.unique_integer([:positive])))
    {:ok, table} = A2A.TaskStore.ETS.init(name: name)
    {A2A.TaskStore.ETS, table}
  end

  defp run_contract({module, ref}) do
    task = %A2A.Types.Task{
      id: "task-1",
      context_id: "ctx-1",
      status: %A2A.Types.TaskStatus{state: :submitted}
    }

    assert :ok = module.put_task(ref, task)
    assert {:ok, %A2A.Types.Task{id: "task-1"}} = module.get_task(ref, "task-1")

    assert {:ok, updated} =
             module.update_task(ref, "task-1", fn stored ->
               %{stored | status: %A2A.Types.TaskStatus{state: :working}}
             end)

    assert updated.status.state == :working

    assert {:ok, %{tasks: tasks, next_page_token: _token, total_size: total_size}} =
             module.list_tasks(ref, %{"pageSize" => 10})

    assert Enum.any?(tasks, &(&1.id == "task-1"))
    assert total_size >= 1
  end

  test "task store contract is satisfied by ETS backend" do
    run_contract(new_ets_store())
  end
end
