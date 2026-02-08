defmodule A2A.ClientSelectionMatrixTest do
  use ExUnit.Case, async: true

  test "binding matching is case-sensitive and falls back to default interface" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      supported_interfaces: [
        %A2A.Types.AgentInterface{protocol_binding: "HTTP+JSON", url: "https://rest.example.com"}
      ]
    }

    interface = A2A.Client.select_interface(card, protocol_binding: "http+json")

    assert interface.protocol_binding == "HTTP+JSON"
    assert interface.url == "https://rest.example.com"
  end

  test "prefers first interface when duplicate bindings are present" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      supported_interfaces: [
        %A2A.Types.AgentInterface{
          protocol_binding: "HTTP+JSON",
          url: "https://rest-1.example.com"
        },
        %A2A.Types.AgentInterface{
          protocol_binding: "HTTP+JSON",
          url: "https://rest-2.example.com"
        }
      ]
    }

    interface = A2A.Client.select_interface(card, protocol_binding: "HTTP+JSON")
    assert interface.url == "https://rest-1.example.com"
  end

  test "uses preferred transport and card URL when interfaces are absent" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      preferred_transport: "JSONRPC",
      url: "https://rpc.example.com"
    }

    config = A2A.Client.Config.from_agent_card(card)
    assert config.base_url == "https://rpc.example.com"
    assert config.transport == A2A.Transport.JSONRPC
  end

  test "falls back to REST transport when binding is unknown" do
    assert A2A.Client.transport_for_binding("WEBSOCKET") == A2A.Transport.REST
  end

  test "default interface is nil when no URL and no interfaces" do
    card = %A2A.Types.AgentCard{name: "demo"}
    assert A2A.Client.select_interface(card) == nil
  end
end
