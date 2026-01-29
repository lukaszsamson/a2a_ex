defmodule A2A.AgentCardValidationTest do
  use ExUnit.Case, async: false

  test "discover validates agent card by default" do
    server = A2A.TestHTTPServer.start(A2A.TestInvalidAgentCardPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    assert {:error, %A2A.Error{type: :invalid_agent_response}} =
             A2A.Client.discover(server.base_url)
  end

  test "discover can skip validation" do
    server = A2A.TestHTTPServer.start(A2A.TestInvalidAgentCardPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    assert {:ok, %A2A.Types.AgentCard{url: "https://agent.example.com"}} =
             A2A.Client.discover(server.base_url, validate_card: false)
  end

  test "discover succeeds with valid card" do
    server = A2A.TestHTTPServer.start(A2A.TestAgentCardPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    assert {:ok, %A2A.Types.AgentCard{name: "demo"}} = A2A.Client.discover(server.base_url)
  end

  test "validate rejects missing url for v0.3" do
    card = %A2A.Types.AgentCard{
      name: "demo",
      capabilities: %A2A.Types.AgentCapabilities{streaming: true}
    }

    assert {:error, %A2A.Error{message: message}} =
             A2A.AgentCard.validate(card, version: :v0_3)

    assert message =~ "url"
  end

  test "validate rejects missing capabilities" do
    card = %A2A.Types.AgentCard{name: "demo", url: "https://agent.example.com"}

    assert {:error, %A2A.Error{message: message}} =
             A2A.AgentCard.validate(card, version: :v0_3)

    assert message =~ "capabilities"
  end

  test "validates latest supported interfaces" do
    server = A2A.TestHTTPServer.start(A2A.TestLatestAgentCardPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    assert {:ok, %A2A.Types.AgentCard{name: "latest-demo"}} =
             A2A.Client.discover(server.base_url, version: :latest)
  end

  test "rejects invalid latest supported interfaces" do
    server = A2A.TestHTTPServer.start(A2A.TestInvalidLatestAgentCardPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    assert {:error, %A2A.Error{type: :invalid_agent_response}} =
             A2A.Client.discover(server.base_url, version: :latest)
  end

  test "preserves unknown fields in agent card raw" do
    map = %{
      "name" => "demo",
      "capabilities" => %{},
      "url" => "https://agent.example.com",
      "extraField" => "value",
      "supportedInterfaces" => [
        %{
          "protocolBinding" => "JSONRPC",
          "url" => "https://rpc.example.com",
          "extra" => "interface-value"
        }
      ]
    }

    card = A2A.Types.AgentCard.from_map(map)
    assert card.raw["extraField"] == "value"

    [interface] = card.supported_interfaces
    assert interface.raw["extra"] == "interface-value"

    encoded = A2A.Types.AgentCard.to_map(card, version: :latest)
    assert encoded["extraField"] == "value"
    assert List.first(encoded["supportedInterfaces"])["extra"] == "interface-value"
  end
end
