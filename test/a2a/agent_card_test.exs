defmodule A2A.AgentCardTest do
  use ExUnit.Case, async: true

  test "verifies signatures with custom verifier" do
    card = %A2A.Types.AgentCard{
      name: "agent",
      signatures: [%A2A.Types.AgentCardSignature{protected: "p", signature: "s"}]
    }

    verifier = fn _card, _sig -> :ok end
    assert :ok == A2A.AgentCard.verify_signatures(card, verifier: verifier)
  end

  test "fails when verifier missing" do
    card = %A2A.Types.AgentCard{
      name: "agent",
      signatures: [%A2A.Types.AgentCardSignature{protected: "p", signature: "s"}]
    }

    assert {:error, %A2A.Error{type: :invalid_agent_response}} =
             A2A.AgentCard.verify_signatures(card, [])
  end
end
