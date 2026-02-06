defmodule A2A.IntegrationJSONRPCExtensionsE2ETest do
  use ExUnit.Case, async: false

  setup_all do
    plug_opts = [executor: A2A.TestExecutor, required_extensions: ["urn:required"]]
    server = A2A.TestHTTPServer.start(A2A.Server.JSONRPC.Plug, plug_opts: plug_opts)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)
    {:ok, base_url: server.base_url}
  end

  test "missing required extension returns JSON-RPC extension_support_required error", %{
    base_url: base_url
  } do
    payload = message_send_payload("msg-missing-ext")
    {:ok, response} = post_jsonrpc(base_url, payload)
    assert response.status == 200

    body = decode_body(response.body)
    assert get_in(body, ["error", "data", "type"]) == "ExtensionSupportRequiredError"
  end

  test "accepts required extension and echoes extension header", %{base_url: base_url} do
    payload = message_send_payload("msg-required-ext")
    {:ok, response} = post_jsonrpc(base_url, payload, [{"a2a-extensions", "urn:required"}])
    assert response.status == 200

    body = decode_body(response.body)
    assert get_in(body, ["result", "task", "id"]) == "task-1"

    assert header_value(response.headers, "a2a-extensions") == "urn:required"
  end

  defp message_send_payload(message_id) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "message/send",
      "params" => %{
        "message" => %{
          "messageId" => message_id,
          "role" => "user",
          "parts" => [%{"kind" => "text", "text" => "hello"}]
        }
      }
    }
  end

  defp post_jsonrpc(base_url, payload, extra_headers \\ []) do
    headers = [{"content-type", "application/json"} | extra_headers]
    Req.post(url: base_url, headers: headers, body: Jason.encode!(payload))
  end

  defp decode_body(body) when is_binary(body), do: Jason.decode!(body)
  defp decode_body(body) when is_map(body), do: body

  defp header_value(headers, key) when is_map(headers) do
    case Map.get(headers, key) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp header_value(headers, key) when is_list(headers) do
    headers
    |> Enum.find_value(fn {k, v} ->
      if String.downcase(to_string(k)) == String.downcase(key) do
        case v do
          [head | _] -> head
          value when is_binary(value) -> value
          _ -> nil
        end
      end
    end)
  end
end
