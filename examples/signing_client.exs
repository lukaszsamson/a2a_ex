# Elixir Client for Python Signing Server
#
# First start the Python signing server:
#   cd a2a-samples/samples/python/agents/signing_and_verifying
#   uv run .
#
# Then run this client:
#   elixir examples/signing_client.exs

Mix.install([
  {:a2a_ex, path: "."},
  {:jose, "~> 1.11"}
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

defmodule SigningClient do
  @base_url "http://localhost:9999"

  # Helper to build structs at runtime
  defp message(fields), do: struct(A2A.Types.Message, fields)
  defp text_part(fields), do: struct(A2A.Types.TextPart, fields)

  def run do
    IO.puts("=" |> String.duplicate(60))
    IO.puts("Elixir Client -> Python Signing Server")
    IO.puts("=" |> String.duplicate(60))
    IO.puts("")

    # Step 1: Fetch and verify public agent card
    IO.puts("Fetching and verifying public agent card from #{@base_url}...")

    case A2A.Client.discover(@base_url,
           transport: A2A.Transport.JSONRPC,
           verify_signatures: true,
           signature_verifier: &verify_signature/2
         ) do
      {:ok, card} ->
        IO.puts("Successfully fetched and verified public agent card:")
        IO.puts("  Name: #{card.name}")
        IO.puts("  Description: #{card.description}")
        IO.puts("  Version: #{card.version}")
        IO.puts("  Signatures: #{length(card.signatures || [])}")

        Enum.each(card.skills || [], fn skill ->
          IO.puts("  Skill: #{skill.name} - #{skill.description}")
        end)

        IO.puts("")

        # Try extended card
        if card.supports_authenticated_extended_card do
          IO.puts("Public card supports authenticated extended card.")
          fetch_extended_card()
        end

        # Send a message
        send_message()

      {:error, error} ->
        IO.puts("Failed: #{inspect(error)}")
    end

    IO.puts("\nClient demo completed!")
  end

  defp fetch_extended_card do
    IO.puts("Attempting to fetch extended agent card...")

    # Note: Extended card verification would need separate implementation
    # The Python SDK's extended card path is different
    case A2A.Client.get_extended_agent_card(
           @base_url,
           transport: A2A.Transport.JSONRPC,
           headers: [{"authorization", "Bearer dummy-token"}]
         ) do
      {:ok, card} ->
        IO.puts("Successfully fetched extended agent card:")
        IO.puts("  Name: #{card.name}")
        IO.puts("  Version: #{card.version}")
        IO.puts("  Skills: #{length(card.skills || [])}")
        IO.puts("")

      {:error, error} ->
        IO.puts("Failed to fetch extended card: #{inspect(error)}")
        IO.puts("")
    end
  end

  defp send_message do
    IO.puts("-" |> String.duplicate(40))
    IO.puts("Sending message...")
    IO.puts("-" |> String.duplicate(40))

    msg = message(
      message_id: random_hex_id(),
      role: :user,
      parts: [text_part(text: "Verify me please!")]
    )

    case A2A.Client.send_message(@base_url, [message: msg], transport: A2A.Transport.JSONRPC) do
      {:ok, response} ->
        IO.puts("Response received:")
        print_response(response)

      {:error, error} ->
        IO.puts("Error: #{inspect(error)}")
    end

    IO.puts("")
  end

  defp print_response(%{role: role} = msg) when not is_nil(role) do
    IO.puts("  Message role: #{role}")
    print_message_parts(msg)
  end

  defp print_response(%{id: id, status: status} = _task) when not is_nil(id) do
    IO.puts("  Task ID: #{id}")
    IO.puts("  Status: #{status && status.state}")
  end

  defp print_response(other) do
    IO.puts("  #{inspect(other)}")
  end

  defp print_message_parts(%{parts: parts}) when is_list(parts) do
    Enum.each(parts, fn part ->
      case part do
        %{text: text} when is_binary(text) ->
          IO.puts("    Text: #{text}")
        other ->
          IO.puts("    Part: #{inspect(other)}")
      end
    end)
  end

  defp print_message_parts(_), do: :ok

  defp random_hex_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # Signature verification function
  defp verify_signature(card, signature) do
    IO.puts("  Verifying signature...")

    with {:ok, protected_json} <- decode_protected(signature.protected),
         {:ok, jku} <- Map.fetch(protected_json, "jku"),
         {:ok, kid} <- Map.fetch(protected_json, "kid"),
         {:ok, _alg} <- Map.fetch(protected_json, "alg"),
         {:ok, public_key} <- fetch_public_key(jku, kid),
         :ok <- verify_jws(card, signature, public_key) do
      IO.puts("  Signature verified successfully!")
      :ok
    else
      error ->
        IO.puts("  Signature verification failed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp decode_protected(protected_b64) do
    case Base.url_decode64(protected_b64, padding: false) do
      {:ok, json} -> Jason.decode(json)
      :error -> {:error, :invalid_base64}
    end
  end

  defp fetch_public_key(jku, kid) do
    IO.puts("  Fetching public key from #{jku} (kid: #{kid})...")

    case Req.get(jku) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        case Map.get(body, kid) do
          nil -> {:error, :key_not_found}
          pem -> {:ok, pem}
        end

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, keys} ->
            case Map.get(keys, kid) do
              nil -> {:error, :key_not_found}
              pem -> {:ok, pem}
            end
          error -> error
        end

      error ->
        {:error, {:fetch_failed, error}}
    end
  end

  defp verify_jws(card, signature, public_key_pem) do
    # Canonicalize the card using RFC 8785 (JCS)
    card_map = A2A.Types.AgentCard.to_map(card)
    # Remove signatures from the card for verification
    card_map = Map.delete(card_map, "signatures")
    canonical_json = JCS.encode(card_map)

    IO.puts("  Canonical payload (#{byte_size(canonical_json)} bytes): #{String.slice(canonical_json, 0, 100)}...")

    payload_b64 = Base.url_encode64(canonical_json, padding: false)

    compact_jws = "#{signature.protected}.#{payload_b64}.#{signature.signature}"

    # Load public key
    jwk = JOSE.JWK.from_pem(public_key_pem)

    # Verify
    case JOSE.JWS.verify(jwk, compact_jws) do
      {true, _payload, _jws} -> :ok
      {false, _, _} -> {:error, :invalid_signature}
    end
  end
end

SigningClient.run()
