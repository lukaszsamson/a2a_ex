defmodule A2A.TransportJSONRPCWireFormatTest do
  use ExUnit.Case, async: false

  defmodule ProtoJSONCapturePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      parent = Keyword.fetch!(opts, :parent)
      {:ok, body, conn} = read_body(conn)
      payload = if body == "", do: %{}, else: Jason.decode!(body)
      send(parent, {:jsonrpc_proto_request_payload, payload})

      response = %{
        "jsonrpc" => "2.0",
        "id" => payload["id"],
        "result" => %{
          "message" => %{
            "messageId" => "msg-2",
            "role" => "ROLE_AGENT",
            "content" => [%{"text" => "hello from proto"}]
          }
        }
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    end
  end

  test "send_message keeps spec-json params shape for JSON-RPC calls" do
    server = A2A.TestHTTPServer.start(ProtoJSONCapturePlug, plug_opts: [parent: self()])
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.JSONRPC,
        wire_format: :proto_json
      )

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{
        message_id: "msg-1",
        role: :user,
        parts: [%A2A.Types.TextPart{text: "hello"}]
      }
    }

    assert {:ok,
            %A2A.Types.Message{
              role: :agent,
              parts: [%A2A.Types.TextPart{text: "hello from proto"}]
            }} =
             A2A.Transport.JSONRPC.send_message(config, request)

    assert_received {:jsonrpc_proto_request_payload, payload}

    assert payload["params"]["message"]["role"] == "user"
    assert payload["params"]["message"]["parts"] == [%{"kind" => "text", "text" => "hello"}]
    refute Map.has_key?(payload["params"]["message"], "content")
  end
end
