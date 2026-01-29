defmodule A2A.ClientStreamTest do
  use ExUnit.Case, async: true

  test "cancel invokes cancel function" do
    parent = self()

    stream = A2A.Client.Stream.new([], fn -> send(parent, :cancelled) end)

    assert :ok == A2A.Client.Stream.cancel(stream)
    assert_received :cancelled
  end
end
