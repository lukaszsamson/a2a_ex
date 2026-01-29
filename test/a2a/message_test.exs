defmodule A2A.MessageTest do
  use ExUnit.Case, async: true

  test "encodes role and parts across versions" do
    message = %A2A.Types.Message{
      message_id: "msg-1",
      role: :user,
      parts: [%A2A.Types.TextPart{text: "Hello"}]
    }

    v0_map = A2A.Types.Message.to_map(message, version: :v0_3)
    assert v0_map["role"] == "user"
    assert v0_map["parts"] == [%{"text" => "Hello", "kind" => "text"}]

    latest_map = A2A.Types.Message.to_map(message, version: :latest)
    assert latest_map["role"] == "ROLE_USER"
    assert latest_map["parts"] == [%{"text" => "Hello"}]

    decoded = A2A.Types.Message.from_map(v0_map, version: :v0_3)
    assert decoded.role == :user
    assert [%A2A.Types.TextPart{text: "Hello"}] = decoded.parts
  end
end
