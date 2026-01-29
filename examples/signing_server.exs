# Elixir Signing Server - Compatible with Python signing_and_verifying test_client.py
#
# This server signs agent cards using ES256 (ECDSA with P-256 and SHA-256)
# and serves the public key for verification.
#
# Run:
#   elixir examples/signing_server.exs
#
# Then test with Python client:
#   cd a2a-samples/samples/python/agents/signing_and_verifying
#   uv run python test_client.py

Mix.install([
  {:a2a_ex, path: "."},
  {:jose, "~> 1.11"},
  {:plug_cowboy, "~> 2.7"}
])

defmodule JCS do
  @moduledoc """
  JSON Canonicalization Scheme (RFC 8785) implementation.
  Produces deterministic JSON output with sorted keys and no whitespace.

  Compatible with Python's A2A SDK canonicalization which uses:
  - exclude_defaults=True
  - exclude_none=True
  - by_alias=True
  """

  # Default values that Python's AgentCard excludes during canonicalization
  # These match the defaults in Python's pydantic model
  @agent_card_defaults %{
    "protocolVersion" => "0.3.0",
    "preferredTransport" => "JSONRPC"
  }

  @doc """
  Canonicalize a map to JSON string following RFC 8785.
  - Keys sorted lexicographically (by UTF-8 bytes)
  - No whitespace
  - Empty values removed (nil, empty strings, empty lists, empty maps)
  - Default values removed (matching Python's exclude_defaults behavior)
  """
  def encode(data) do
    data
    |> remove_defaults()
    |> clean_empty()
    |> do_encode()
  end

  # Remove known default values to match Python's exclude_defaults=True
  defp remove_defaults(map) when is_map(map) do
    map
    |> Enum.reject(fn {k, v} ->
      Map.get(@agent_card_defaults, k) == v
    end)
    |> Enum.map(fn {k, v} -> {k, remove_defaults(v)} end)
    |> Map.new()
  end

  defp remove_defaults(list) when is_list(list) do
    Enum.map(list, &remove_defaults/1)
  end

  defp remove_defaults(value), do: value

  # Clean empty values recursively
  defp clean_empty(nil), do: nil
  defp clean_empty(""), do: nil
  defp clean_empty([]), do: nil
  defp clean_empty(map) when map == %{}, do: nil

  defp clean_empty(map) when is_map(map) do
    cleaned =
      map
      |> Enum.map(fn {k, v} -> {k, clean_empty(v)} end)
      |> Enum.reject(fn {_k, v} -> v == nil end)
      |> Map.new()

    if cleaned == %{}, do: nil, else: cleaned
  end

  defp clean_empty(list) when is_list(list) do
    cleaned =
      list
      |> Enum.map(&clean_empty/1)
      |> Enum.reject(&is_nil/1)

    if cleaned == [], do: nil, else: cleaned
  end

  defp clean_empty(value), do: value

  # Encode to JSON with sorted keys
  defp do_encode(nil), do: "null"
  defp do_encode(true), do: "true"
  defp do_encode(false), do: "false"
  defp do_encode(n) when is_integer(n), do: Integer.to_string(n)
  defp do_encode(n) when is_float(n), do: Float.to_string(n)

  defp do_encode(s) when is_binary(s) do
    # JSON string encoding
    Jason.encode!(s)
  end

  defp do_encode(list) when is_list(list) do
    elements = Enum.map(list, &do_encode/1)
    "[" <> Enum.join(elements, ",") <> "]"
  end

  defp do_encode(map) when is_map(map) do
    # Sort keys lexicographically
    pairs =
      map
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map(fn {k, v} ->
        key_str = if is_atom(k), do: Atom.to_string(k), else: k
        Jason.encode!(key_str) <> ":" <> do_encode(v)
      end)

    "{" <> Enum.join(pairs, ",") <> "}"
  end
end

defmodule SigningServerPlug do
  @moduledoc """
  Agent card definitions and signing utilities.
  """

  # Generate EC key pair at startup
  @ec_key JOSE.JWK.generate_key({:ec, "P-256"})
  @kid "my-key"
  @jku "http://localhost:9999/public_keys.json"

  def ec_key, do: @ec_key
  def kid, do: @kid
  def jku, do: @jku

  # Helper to build structs at runtime
  defp agent_card(fields), do: struct(A2A.Types.AgentCard, fields)
  defp capabilities(fields), do: struct(A2A.Types.AgentCapabilities, fields)
  defp skill(fields), do: struct(A2A.Types.AgentSkill, fields)

  def public_agent_card do
    card = agent_card(
      name: "Signed Agent",
      description: "An Agent that is signed",
      url: "http://localhost:9999/",
      version: "1.0.0",
      default_input_modes: ["text"],
      default_output_modes: ["text"],
      capabilities: capabilities(streaming: true),
      skills: [
        skill(
          id: "reminder",
          name: "Verification Reminder",
          description: "Reminds the user to verify the Agent Card.",
          tags: ["verify me"],
          examples: ["Verify me!"]
        )
      ],
      supports_authenticated_extended_card: true
    )

    sign_card(card)
  end

  def extended_agent_card do
    card = agent_card(
      name: "Signed Agent - Extended Edition",
      description: "The full-featured signed agent for authenticated users.",
      url: "http://localhost:9999/",
      version: "1.0.1",
      default_input_modes: ["text"],
      default_output_modes: ["text"],
      capabilities: capabilities(streaming: true),
      skills: [
        skill(
          id: "reminder",
          name: "Verification Reminder",
          description: "Reminds the user to verify the Agent Card.",
          tags: ["verify me"],
          examples: ["Verify me!"]
        ),
        skill(
          id: "reminder-please",
          name: "Verification Reminder Please!",
          description: "Politely reminds user to verify the Agent Card.",
          tags: ["verify me", "pretty please", "extended"],
          examples: ["Verify me, pretty please! :)", "Please verify me."]
        )
      ],
      supports_authenticated_extended_card: true
    )

    sign_card(card)
  end

  defp sign_card(card) do
    # Convert card to map and canonicalize using RFC 8785
    card_map = A2A.Types.AgentCard.to_map(card)
    # Remove signatures field if present (should not be signed)
    card_map = Map.delete(card_map, "signatures")
    canonical_json = JCS.encode(card_map)

    IO.puts("DEBUG: Canonical JSON for signing (#{byte_size(canonical_json)} bytes):")
    IO.puts(canonical_json)

    # Create JWS with detached payload
    protected_header = %{
      "alg" => "ES256",
      "kid" => @kid,
      "jku" => @jku
    }

    # Sign using JOSE - create JWS with the canonical JSON as payload
    {_, compact} = JOSE.JWS.sign(@ec_key, canonical_json, protected_header)
                   |> JOSE.JWS.compact()

    # Parse the compact JWS to extract protected and signature
    [protected_b64, _payload_b64, signature_b64] = String.split(compact, ".")

    IO.puts("DEBUG: Protected header B64: #{protected_b64}")
    IO.puts("DEBUG: Signature B64: #{signature_b64}")

    # Create signature struct with the values
    sig = %A2A.Types.AgentCardSignature{
      protected: protected_b64,
      signature: signature_b64
    }

    # Add signature to card
    %{card | signatures: [sig]}
  end

  def public_key_json do
    # Export public key as PEM
    {_type, public_key} = JOSE.JWK.to_public(@ec_key) |> JOSE.JWK.to_pem()
    Jason.encode!(%{@kid => public_key})
  end
end

# Executor that returns "Verify me!"
defmodule SignedAgentExecutor do
  @behaviour A2A.Server.Executor

  defp message_struct(fields), do: struct(A2A.Types.Message, fields)
  defp text_part(fields), do: struct(A2A.Types.TextPart, fields)
  defp task(fields), do: struct(A2A.Types.Task, fields)
  defp task_status(fields), do: struct(A2A.Types.TaskStatus, fields)

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  def handle_send_message(request, _ctx) do
    task_id = "task-#{random_id()}"
    context_id = request.context_id || "ctx-#{random_id()}"

    agent_message = message_struct(
      message_id: "msg-#{random_id()}",
      role: :agent,
      parts: [text_part(text: "Verify me!")]
    )

    result = task(
      id: task_id,
      context_id: context_id,
      status: task_status(
        state: :completed,
        message: agent_message,
        timestamp: DateTime.utc_now()
      ),
      history: [request.message, agent_message]
    )

    {:ok, result}
  end

  def handle_stream_message(request, _ctx, emit) do
    task_id = "task-#{random_id()}"
    context_id = request.context_id || "ctx-#{random_id()}"

    agent_message = message_struct(
      message_id: "msg-#{random_id()}",
      role: :agent,
      parts: [text_part(text: "Verify me!")]
    )

    # Emit the message
    emit.(agent_message)

    result = task(
      id: task_id,
      context_id: context_id,
      status: task_status(
        state: :completed,
        message: agent_message,
        timestamp: DateTime.utc_now()
      ),
      history: [request.message, agent_message]
    )

    {:ok, result}
  end

  def handle_get_task(_task_id, _query, _ctx) do
    {:error, A2A.Error.new(:task_not_found, "Task not found")}
  end

  def handle_list_tasks(_request, _ctx) do
    {:ok, struct(A2A.Types.ListTasksResponse, tasks: [])}
  end

  def handle_cancel_task(_task_id, _ctx) do
    {:error, A2A.Error.new(:task_not_cancelable, "Cancel not supported")}
  end

  def handle_get_extended_agent_card(_ctx) do
    {:ok, SigningServerPlug.extended_agent_card()}
  end
end

# Custom plug to serve public keys
defmodule PublicKeysPlug do
  import Plug.Conn

  def init(opts), do: opts

  def call(%{request_path: "/public_keys.json", method: "GET"} = conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, SigningServerPlug.public_key_json())
    |> halt()
  end

  def call(conn, _opts), do: conn
end

# Custom plug to serve extended agent card at the path Python expects
defmodule ExtendedCardPlug do
  import Plug.Conn

  def init(opts), do: opts

  def call(%{request_path: "/agent/authenticatedExtendedCard", method: "GET"} = conn, _opts) do
    card = SigningServerPlug.extended_agent_card()
    card_json = Jason.encode!(A2A.Types.AgentCard.to_map(card))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, card_json)
    |> halt()
  end

  def call(conn, _opts), do: conn
end

# Main server plug
defmodule FinalServerPlug do
  use Plug.Builder

  # Serve public keys for verification
  plug PublicKeysPlug

  # Serve extended agent card at /agent/authenticatedExtendedCard (Python expected path)
  plug ExtendedCardPlug

  # Serve public agent card at /.well-known/agent-card.json
  plug A2A.Server.AgentCardPlug,
    card_fun: &SigningServerPlug.public_agent_card/0

  # JSON-RPC transport for Python compatibility
  plug A2A.Server.JSONRPC.Plug,
    executor: SignedAgentExecutor,
    capabilities: %{streaming: true, extended_agent_card: true}
end

IO.puts("""
Starting Elixir Signing Server on http://localhost:9999

Endpoints:
  GET  /.well-known/agent-card.json  - Signed public agent card
  GET  /public_keys.json             - Public keys for verification
  GET  /agent/authenticatedExtendedCard - Signed extended agent card
  POST /                             - JSON-RPC endpoint

Key ID: #{SigningServerPlug.kid()}
JKU: #{SigningServerPlug.jku()}

This server is compatible with the Python test_client.py from:
  a2a-samples/samples/python/agents/signing_and_verifying

Press Ctrl+C to stop.
""")

{:ok, _} = Plug.Cowboy.http(FinalServerPlug, [], port: 9999)
Process.sleep(:infinity)
