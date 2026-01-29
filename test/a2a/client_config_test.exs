defmodule A2A.ClientConfigTest do
  use ExUnit.Case, async: true

  test "selects preferred interface for v0.3" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      preferred_transport: "HTTP+JSON",
      url: "https://agent.example.com"
    }

    interface = A2A.Client.select_interface(card)
    assert interface.protocol_binding == "HTTP+JSON"
    assert interface.url == "https://agent.example.com"

    config = A2A.Client.Config.from_agent_card(card)
    assert config.base_url == "https://agent.example.com"
    assert config.transport == A2A.Transport.REST
  end

  test "selects supported interface for latest" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      supported_interfaces: [
        %A2A.Types.AgentInterface{protocol_binding: "JSONRPC", url: "https://rpc.example.com"}
      ]
    }

    interface = A2A.Client.select_interface(card)
    assert interface.protocol_binding == "JSONRPC"
    assert interface.url == "https://rpc.example.com"
  end

  test "selects interface for transport override" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      supported_interfaces: [
        %A2A.Types.AgentInterface{protocol_binding: "HTTP+JSON", url: "https://rest.example.com"},
        %A2A.Types.AgentInterface{protocol_binding: "JSONRPC", url: "https://rpc.example.com"}
      ]
    }

    config = A2A.Client.Config.from_agent_card(card, transport: A2A.Transport.JSONRPC)

    assert config.base_url == "https://rpc.example.com"
    assert config.transport == A2A.Transport.JSONRPC
  end

  test "selects interface for protocol binding override" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      supported_interfaces: [
        %A2A.Types.AgentInterface{protocol_binding: "HTTP+JSON", url: "https://rest.example.com"},
        %A2A.Types.AgentInterface{protocol_binding: "JSONRPC", url: "https://rpc.example.com"}
      ]
    }

    config = A2A.Client.Config.from_agent_card(card, protocol_binding: "JSONRPC")

    assert config.base_url == "https://rpc.example.com"
    assert config.transport == A2A.Transport.JSONRPC
  end

  test "selects additional interface when supported is missing" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      additional_interfaces: [
        %A2A.Types.AgentInterface{protocol_binding: "JSONRPC", url: "https://rpc.example.com"}
      ]
    }

    interface = A2A.Client.select_interface(card)
    assert interface.protocol_binding == "JSONRPC"
    assert interface.url == "https://rpc.example.com"

    config = A2A.Client.Config.from_agent_card(card)
    assert config.base_url == "https://rpc.example.com"
    assert config.transport == A2A.Transport.JSONRPC
  end

  test "selects preferred transport when supported is empty" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      url: "https://rest.example.com",
      preferred_transport: "HTTP+JSON",
      supported_interfaces: []
    }

    interface = A2A.Client.select_interface(card)
    assert interface.protocol_binding == "HTTP+JSON"
    assert interface.url == "https://rest.example.com"
  end

  defmodule AuthModule do
    def headers(_opts), do: [{"authorization", "Bearer module"}]
  end

  test "builds request headers with extensions and auth" do
    config =
      A2A.Client.Config.new("https://example.com",
        headers: [{"x-base", "1"}],
        extensions: ["urn:test:ext"],
        auth: {AuthModule, []},
        legacy_extensions_header: true
      )

    headers = A2A.Client.Config.request_headers(config, headers: [{"x-extra", "2"}])

    assert {"x-base", "1"} in headers
    assert {"x-extra", "2"} in headers
    assert {"x-a2a-extensions", "urn:test:ext"} in headers
    assert {"authorization", "Bearer module"} in headers
  end

  test "adds version header for latest" do
    config = A2A.Client.Config.new("https://example.com", version: :latest)
    headers = A2A.Client.Config.request_headers(config)

    assert {"a2a-version", "0.3"} in headers
  end

  test "supports auth function" do
    config =
      A2A.Client.Config.new("https://example.com",
        auth: fn -> [{"authorization", "Bearer fn"}] end
      )

    headers = A2A.Client.Config.request_headers(config)
    assert {"authorization", "Bearer fn"} in headers
  end

  test "allows per-request extensions override" do
    config = A2A.Client.Config.new("https://example.com")

    headers =
      A2A.Client.Config.request_headers(config, extensions: ["urn:test:override"])

    assert {"a2a-extensions", "urn:test:override"} in headers
  end
end
