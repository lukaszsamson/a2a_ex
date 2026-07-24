defmodule A2A.ClientSelectionMatrixTest do
  use ExUnit.Case, async: true

  test "binding matching is case-sensitive and does not silently negotiate another binding" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      supported_interfaces: [
        %A2A.Types.AgentInterface{protocol_binding: "HTTP+JSON", url: "https://rest.example.com"}
      ]
    }

    interface = A2A.Client.select_interface(card, protocol_binding: "http+json")

    assert interface == nil
  end

  test "does not negotiate a future protocol minor as v1.0" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      supported_interfaces: [
        %A2A.Types.AgentInterface{
          protocol_binding: "HTTP+JSON",
          protocol_version: "1.1",
          url: "https://future.example.com"
        }
      ]
    }

    assert A2A.Client.select_interface(card, version: :v1_0) == nil

    assert_raise ArgumentError, fn ->
      A2A.Client.Config.from_agent_card(card, version: :v1_0)
    end
  end

  test "does not automatically negotiate a future protocol minor" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      supported_interfaces: [
        %A2A.Types.AgentInterface{
          protocol_binding: "HTTP+JSON",
          protocol_version: "1.1",
          url: "https://future.example.com"
        }
      ]
    }

    assert A2A.Client.select_interface(card) == nil
    assert_raise ArgumentError, fn -> A2A.Client.Config.from_agent_card(card) end
  end

  test "skips a future interface and selects the first supported version" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      supported_interfaces: [
        %A2A.Types.AgentInterface{
          protocol_binding: "HTTP+JSON",
          protocol_version: "1.1",
          url: "https://future.example.com"
        },
        %A2A.Types.AgentInterface{
          protocol_binding: "JSONRPC",
          protocol_version: "1.0",
          url: "https://v1.example.com"
        }
      ]
    }

    config = A2A.Client.Config.from_agent_card(card)
    assert config.version == :v1_0
    assert config.base_url == "https://v1.example.com"
    assert config.transport == A2A.Transport.JSONRPC
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
