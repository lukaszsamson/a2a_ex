defmodule A2A.TaskStateTest do
  use ExUnit.Case, async: true

  test "encodes and decodes task states" do
    assert A2A.TaskState.decode("TASK_STATE_CANCELLED") == :canceled
    assert A2A.TaskState.decode("canceled") == :canceled
    assert A2A.TaskState.encode(:auth_required, version: :v0_3) == "auth-required"
    assert A2A.TaskState.encode(:auth_required, version: :latest) == "TASK_STATE_AUTH_REQUIRED"
    assert A2A.TaskState.decode("TASK_STATE_FUTURE") == {:unknown, "TASK_STATE_FUTURE"}
    assert A2A.TaskState.terminal?(:completed)
    refute A2A.TaskState.terminal?(:working)
  end
end
