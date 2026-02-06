defmodule A2A.TransportJSONRPCTest do
  use ExUnit.Case, async: false

  defmodule JSONRPCPushCompatPlug do
    def init(opts), do: opts

    def call(conn, _opts) do
      import A2A.TestServerHelpers

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      id = payload["id"]
      params = payload["params"] || %{}

      case payload["method"] do
        "tasks/pushNotificationConfig/set" ->
          if Map.has_key?(params, "pushNotificationConfig") and Map.has_key?(params, "taskId") do
            send_json(conn, %{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "taskId" => params["taskId"],
                "pushNotificationConfig" => params["pushNotificationConfig"]
              }
            })
          else
            send_json(conn, %{
              "jsonrpc" => "2.0",
              "id" => id,
              "error" => %{"code" => -32602, "message" => "bad set params"}
            })
          end

        "tasks/pushNotificationConfig/get" ->
          if Map.has_key?(params, "id") and Map.has_key?(params, "pushNotificationConfigId") do
            send_json(conn, %{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "taskId" => params["id"],
                "pushNotificationConfig" => %{
                  "id" => params["pushNotificationConfigId"],
                  "url" => "https://example.com/webhook"
                }
              }
            })
          else
            send_json(conn, %{
              "jsonrpc" => "2.0",
              "id" => id,
              "error" => %{"code" => -32602, "message" => "bad get params"}
            })
          end

        "tasks/pushNotificationConfig/list" ->
          if Map.has_key?(params, "id") do
            send_json(conn, %{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => [
                %{
                  "taskId" => params["id"],
                  "pushNotificationConfig" => %{
                    "id" => "cfg-1",
                    "url" => "https://example.com/webhook"
                  }
                }
              ]
            })
          else
            send_json(conn, %{
              "jsonrpc" => "2.0",
              "id" => id,
              "error" => %{"code" => -32602, "message" => "bad list params"}
            })
          end

        "tasks/pushNotificationConfig/delete" ->
          if Map.has_key?(params, "id") and Map.has_key?(params, "pushNotificationConfigId") do
            send_json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
          else
            send_json(conn, %{
              "jsonrpc" => "2.0",
              "id" => id,
              "error" => %{"code" => -32602, "message" => "bad delete params"}
            })
          end

        _ ->
          send_json(conn, %{
            "jsonrpc" => "2.0",
            "id" => id,
            "error" => %{"code" => -32601, "message" => "Method not found"}
          })
      end
    end
  end

  setup_all do
    server = A2A.TestHTTPServer.start(A2A.TestJSONRPCSuccessPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)
    {:ok, base_url: server.base_url}
  end

  test "send_message returns task", %{base_url: base_url} do
    config = A2A.Client.Config.new(base_url, transport: A2A.Transport.JSONRPC)

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    assert {:ok, %A2A.Types.Task{id: "task-1"}} =
             A2A.Transport.JSONRPC.send_message(config, request)
  end

  test "stream_message returns stream responses", %{base_url: base_url} do
    config = A2A.Client.Config.new(base_url, transport: A2A.Transport.JSONRPC)

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    {:ok, stream} = A2A.Transport.JSONRPC.stream_message(config, request)
    events = Enum.to_list(stream)
    assert [%A2A.Types.StreamResponse{task: %A2A.Types.Task{id: "task-1"}}] = events
  end

  test "stream_message surfaces error events" do
    server = A2A.TestHTTPServer.start(A2A.TestJSONRPCStreamErrorPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config = A2A.Client.Config.new(server.base_url, transport: A2A.Transport.JSONRPC)

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    {:ok, stream} = A2A.Transport.JSONRPC.stream_message(config, request)
    [event] = Enum.take(stream, 1)

    assert %A2A.Types.StreamError{error: %A2A.Error{code: -32601}} = event
  end

  test "stream_message returns raw details on handshake error" do
    server = A2A.TestHTTPServer.start(A2A.TestJSONRPCStreamHandshakeErrorPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config = A2A.Client.Config.new(server.base_url, transport: A2A.Transport.JSONRPC)

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    assert {:error, %A2A.Error{type: :http_error, raw: raw}} =
             A2A.Transport.JSONRPC.stream_message(config, request)

    assert raw.status == 400
  end

  test "list_tasks returns response", %{base_url: base_url} do
    config = A2A.Client.Config.new(base_url, transport: A2A.Transport.JSONRPC)
    request = %A2A.Types.ListTasksRequest{}

    assert {:ok, %A2A.Types.ListTasksResponse{tasks: []}} =
             A2A.Transport.JSONRPC.list_tasks(config, request)
  end

  test "send_message returns error object" do
    server = A2A.TestHTTPServer.start(A2A.TestJSONRPCErrorPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.JSONRPC,
        req_options: [retry: false]
      )

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    assert {:error, %A2A.Error{type: :task_not_found, raw: raw}} =
             A2A.Transport.JSONRPC.send_message(config, request)

    assert raw.status == 200
  end

  test "preserves JSON-RPC error code" do
    server = A2A.TestHTTPServer.start(A2A.TestJSONRPCErrorPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.JSONRPC,
        req_options: [retry: false]
      )

    assert {:error, %A2A.Error{code: -32601}} =
             A2A.Transport.JSONRPC.cancel_task(config, "task-1")
  end

  test "list_tasks returns invalid JSON error" do
    server = A2A.TestHTTPServer.start(A2A.TestJSONRPCErrorPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.JSONRPC,
        req_options: [retry: false]
      )

    request = %A2A.Types.ListTasksRequest{}

    assert {:error, %A2A.Error{type: :invalid_agent_response}} =
             A2A.Transport.JSONRPC.list_tasks(config, request)
  end

  test "push config operations support js sdk compatibility params" do
    server = A2A.TestHTTPServer.start(JSONRPCPushCompatPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.JSONRPC,
        transport_opts: [jsonrpc_push_compat: :js_sdk]
      )

    req = %A2A.Types.PushNotificationConfig{id: "cfg-1", url: "https://example.com/webhook"}

    assert {:ok, %A2A.Types.PushNotificationConfig{id: "cfg-1"}} =
             A2A.Transport.JSONRPC.push_notification_config_set(config, "task-1", req)

    assert {:ok, %A2A.Types.PushNotificationConfig{id: "cfg-1"}} =
             A2A.Transport.JSONRPC.push_notification_config_get(config, "task-1", "cfg-1")

    assert {:ok, [%A2A.Types.PushNotificationConfig{id: "cfg-1"}]} =
             A2A.Transport.JSONRPC.push_notification_config_list(config, "task-1", %{})

    assert :ok =
             A2A.Transport.JSONRPC.push_notification_config_delete(config, "task-1", "cfg-1")
  end
end
