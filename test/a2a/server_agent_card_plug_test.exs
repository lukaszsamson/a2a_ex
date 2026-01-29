defmodule A2A.ServerAgentCardPlugTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  test "serves agent card on well-known path" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      url: "https://agent.example.com",
      capabilities: %A2A.Types.AgentCapabilities{streaming: true}
    }

    conn =
      conn(:get, "/.well-known/agent-card.json")
      |> A2A.Server.AgentCardPlug.call(A2A.Server.AgentCardPlug.init(card: card))

    assert conn.status == 200
    assert conn.halted
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    body = Jason.decode!(conn.resp_body)
    assert body["name"] == "demo"
  end

  test "serves legacy path when configured" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      url: "https://agent.example.com",
      capabilities: %A2A.Types.AgentCapabilities{streaming: true}
    }

    conn =
      conn(:get, "/.well-known/agent.json")
      |> A2A.Server.AgentCardPlug.call(
        A2A.Server.AgentCardPlug.init(card: card, legacy_path: "/.well-known/agent.json")
      )

    assert conn.status == 200
    assert conn.halted
    body = Jason.decode!(conn.resp_body)
    assert body["name"] == "demo"
  end

  test "passes through for other paths" do
    conn =
      conn(:get, "/other")
      |> A2A.Server.AgentCardPlug.call(
        A2A.Server.AgentCardPlug.init(card: %A2A.Types.AgentCard{})
      )

    assert conn.status == nil
  end
end
