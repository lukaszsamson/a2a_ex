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

  test "v1 card uses the A2A media type and supports conditional GET" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      description: "demo agent",
      version: "1.0.0",
      capabilities: %A2A.Types.AgentCapabilities{},
      default_input_modes: ["text/plain"],
      default_output_modes: ["text/plain"],
      skills: [],
      supported_interfaces: [
        %A2A.Types.AgentInterface{
          protocol_binding: "HTTP+JSON",
          protocol_version: "1.0",
          url: "https://agent.example.com"
        }
      ]
    }

    opts = A2A.Server.AgentCardPlug.init(card: card, version: :v1_0)

    first =
      conn(:get, "/.well-known/agent-card.json")
      |> A2A.Server.AgentCardPlug.call(opts)

    assert first.status == 200
    assert get_resp_header(first, "content-type") == ["application/a2a+json; charset=utf-8"]
    assert get_resp_header(first, "cache-control") == ["public, max-age=300"]
    assert [etag] = get_resp_header(first, "etag")

    second =
      conn(:get, "/.well-known/agent-card.json")
      |> put_req_header("if-none-match", etag)
      |> A2A.Server.AgentCardPlug.call(opts)

    assert second.status == 304
    assert second.resp_body == ""
    assert get_resp_header(second, "etag") == [etag]
    assert get_resp_header(second, "cache-control") == ["public, max-age=300"]
  end

  test "v1 card caching can be disabled" do
    opts =
      A2A.Server.AgentCardPlug.init(
        card: %A2A.Types.AgentCard{name: "demo"},
        version: :v1_0,
        cache_control: false,
        etag: false
      )

    conn =
      conn(:get, "/.well-known/agent-card.json")
      |> A2A.Server.AgentCardPlug.call(opts)

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "etag") == []
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
