defmodule A2A.ContextTest do
  use ExUnit.Case, async: true

  test "ensure_context_id preserves existing message context" do
    message = %A2A.Types.Message{message_id: "msg-1", role: :user, context_id: "ctx-1"}

    assert {^message, "ctx-1"} = A2A.Context.ensure_context_id(message)
  end

  test "ensure_context_id generates message context when missing" do
    message = %A2A.Types.Message{message_id: "msg-1", role: :user, context_id: nil}

    {updated, context_id} = A2A.Context.ensure_context_id(message)

    assert updated.context_id == context_id
    assert context_id =~ ~r/^[0-9a-f]{32}$/
  end

  test "ensure_context_id preserves existing task context" do
    task = %A2A.Types.Task{id: "task-1", context_id: "ctx-1"}

    assert {^task, "ctx-1"} = A2A.Context.ensure_context_id(task)
  end

  test "ensure_context_id generates task context when missing" do
    task = %A2A.Types.Task{id: "task-1", context_id: nil}

    {updated, context_id} = A2A.Context.ensure_context_id(task)

    assert updated.context_id == context_id
    assert context_id =~ ~r/^[0-9a-f]{32}$/
  end

  test "generate_id returns different lowercase hex identifiers" do
    id1 = A2A.Context.generate_id()
    id2 = A2A.Context.generate_id()

    assert id1 != id2
    assert id1 =~ ~r/^[0-9a-f]{32}$/
    assert id2 =~ ~r/^[0-9a-f]{32}$/
  end
end
