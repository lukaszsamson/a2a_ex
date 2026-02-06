defmodule A2A.TransportWireMatrixTest do
  use ExUnit.Case, async: false

  defmodule RESTWireCapturePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      parent = Keyword.fetch!(opts, :parent)
      {:ok, body, conn} = read_body(conn)
      payload = if body == "", do: %{}, else: Jason.decode!(body)
      send(parent, {:rest_wire_payload, payload})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "task" => %{
            "id" => "task-1",
            "contextId" => "ctx-1",
            "status" => %{"state" => "submitted"}
          }
        })
      )
    end
  end

  defmodule JSONRPCWireCapturePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      parent = Keyword.fetch!(opts, :parent)
      {:ok, body, conn} = read_body(conn)
      payload = if body == "", do: %{}, else: Jason.decode!(body)
      send(parent, {:jsonrpc_wire_payload, payload})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => payload["id"],
          "result" => %{
            "task" => %{
              "id" => "task-1",
              "contextId" => "ctx-1",
              "status" => %{"state" => "submitted"}
            }
          }
        })
      )
    end
  end

  defp request do
    %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{
        message_id: "msg-1",
        role: :user,
        parts: [%A2A.Types.TextPart{text: "hello"}]
      }
    }
  end

  test "REST latest + spec_json keeps spec message fields" do
    server = A2A.TestHTTPServer.start(RESTWireCapturePlug, plug_opts: [parent: self()])
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.REST,
        version: :latest,
        wire_format: :spec_json
      )

    assert {:ok, %A2A.Types.Task{id: "task-1"}} =
             A2A.Transport.REST.send_message(config, request())

    assert_received {:rest_wire_payload, payload}
    assert payload["message"]["role"] == "user"
    assert payload["message"]["parts"] == [%{"kind" => "text", "text" => "hello"}]
    refute Map.has_key?(payload["message"], "content")
  end

  test "REST latest + proto_json emits proto-style message fields" do
    server = A2A.TestHTTPServer.start(RESTWireCapturePlug, plug_opts: [parent: self()])
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.REST,
        version: :latest,
        wire_format: :proto_json
      )

    assert {:ok, %A2A.Types.Task{id: "task-1"}} =
             A2A.Transport.REST.send_message(config, request())

    assert_received {:rest_wire_payload, payload}
    assert payload["message"]["role"] == "ROLE_USER"
    assert payload["message"]["content"] == [%{"text" => "hello"}]
    refute Map.has_key?(payload["message"], "parts")
  end

  test "JSON-RPC latest ignores wire_format override and still emits proto-style params" do
    server = A2A.TestHTTPServer.start(JSONRPCWireCapturePlug, plug_opts: [parent: self()])
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.JSONRPC,
        version: :latest,
        wire_format: :spec_json
      )

    assert {:ok, %A2A.Types.Task{id: "task-1"}} =
             A2A.Transport.JSONRPC.send_message(config, request())

    assert_received {:jsonrpc_wire_payload, payload}
    assert payload["method"] == "SendMessage"
    assert payload["params"]["message"]["role"] == "ROLE_USER"
    assert payload["params"]["message"]["content"] == [%{"text" => "hello"}]
    refute Map.has_key?(payload["params"]["message"], "parts")
  end
end
