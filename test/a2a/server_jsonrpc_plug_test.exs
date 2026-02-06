defmodule A2A.ServerJSONRPCPlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @opts A2A.Server.JSONRPC.Plug.init(executor: A2A.TestExecutor, capabilities: %{streaming: true})

  defmodule SlowExecutor do
    def handle_stream_message(_request, _ctx, _emit) do
      Process.sleep(50)

      {:ok,
       %A2A.Types.Task{
         id: "task-1",
         context_id: "ctx-1",
         status: %A2A.Types.TaskStatus{state: :submitted}
       }}
    end
  end

  defmodule SlowRequestExecutor do
    def handle_send_message(_request, _ctx) do
      Process.sleep(50)

      {:ok,
       %A2A.Types.Task{
         id: "task-1",
         context_id: "ctx-1",
         status: %A2A.Types.TaskStatus{state: :submitted}
       }}
    end
  end

  defmodule SlowQueryExecutor do
    def handle_get_task(_task_id, _query, _ctx) do
      Process.sleep(50)

      {:ok,
       %A2A.Types.Task{
         id: "task-1",
         context_id: "ctx-1",
         status: %A2A.Types.TaskStatus{state: :submitted}
       }}
    end

    def handle_list_tasks(_request, _ctx) do
      Process.sleep(50)

      {:ok,
       %A2A.Types.ListTasksResponse{
         tasks: [
           %A2A.Types.Task{
             id: "task-1",
             context_id: "ctx-1",
             status: %A2A.Types.TaskStatus{state: :submitted}
           }
         ]
       }}
    end
  end

  @timeout_opts A2A.Server.JSONRPC.Plug.init(
                  executor: SlowExecutor,
                  capabilities: %{streaming: true},
                  stream_timeout: 10
                )
  @request_timeout_opts A2A.Server.JSONRPC.Plug.init(
                          executor: SlowRequestExecutor,
                          request_timeout: 10
                        )
  @request_timeout_query_opts A2A.Server.JSONRPC.Plug.init(
                                executor: SlowQueryExecutor,
                                request_timeout: 10
                              )
  @push_opts A2A.Server.JSONRPC.Plug.init(
               executor: A2A.TestExecutor,
               capabilities: %{push_notifications: true}
             )

  test "streams send message responses" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "message/stream",
      "params" => %{
        "message" => %{
          "messageId" => "msg-1",
          "role" => "user",
          "parts" => [%{"text" => "hello"}]
        }
      }
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(@opts)

    assert conn.status == 200
    assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")

    events = A2A.Transport.SSE.decode_events(conn.resp_body)
    decoded = Enum.map(events, &Jason.decode!/1)

    assert Enum.any?(decoded, fn event ->
             get_in(event, ["result", "task", "id"]) == "task-1"
           end)

    assert Enum.any?(decoded, fn event ->
             get_in(event, ["result", "statusUpdate", "taskId"]) == "task-1"
           end)
  end

  test "streams resubscribe responses" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tasks/resubscribe",
      "params" => %{"taskId" => "task-1", "resume" => %{"cursor" => "0"}}
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(@opts)

    assert conn.status == 200

    events = A2A.Transport.SSE.decode_events(conn.resp_body)
    decoded = Enum.map(events, &Jason.decode!/1)
    assert Enum.at(decoded, 0)["result"]["statusUpdate"]["taskId"] == "task-1"
  end

  test "returns invalid params error" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "tasks/get",
      "params" => %{}
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == -32602
  end

  test "returns error for oversized request body" do
    body = String.duplicate("a", 8_000_001)

    conn =
      conn("POST", "/", body)
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(@opts)

    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)
    assert response["error"]["code"] == -32600
    assert response["error"]["message"] == "Request too large"
  end

  test "echoes request id" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 9,
      "method" => "tasks/get",
      "params" => %{"taskId" => "task-1"}
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-request-id", "req-456")
      |> A2A.Server.JSONRPC.Plug.call(@opts)

    assert conn.status == 200
    assert get_resp_header(conn, "x-request-id") == ["req-456"]
  end

  test "rejects streaming without accept header" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 4,
      "method" => "message/stream",
      "params" => %{
        "message" => %{
          "messageId" => "msg-1",
          "role" => "user",
          "parts" => [%{"text" => "hello"}]
        }
      }
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == -32000
    assert body["error"]["data"]["type"] == "ContentTypeNotSupportedError"
  end

  test "returns request timeout for stream" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 5,
      "method" => "message/stream",
      "params" => %{
        "message" => %{
          "messageId" => "msg-1",
          "role" => "user",
          "parts" => [%{"text" => "hello"}]
        }
      }
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "text/event-stream")
      |> A2A.Server.JSONRPC.Plug.call(@timeout_opts)

    assert conn.status == 200
    events = A2A.Transport.SSE.decode_events(conn.resp_body)
    [event | _] = Enum.map(events, &Jason.decode!/1)
    assert event["error"]["code"] == -32000
    assert event["error"]["data"]["type"] == "StreamTimeoutError"
  end

  test "returns request timeout for non-streaming request" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 6,
      "method" => "message/send",
      "params" => %{
        "message" => %{
          "messageId" => "msg-1",
          "role" => "user",
          "parts" => [%{"text" => "hello"}]
        }
      }
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(@request_timeout_opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == -32000
    assert body["error"]["data"]["type"] == "RequestTimeoutError"
  end

  test "returns request timeout for get task" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tasks/get",
      "params" => %{"taskId" => "task-1"}
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(@request_timeout_query_opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == -32000
    assert body["error"]["data"]["type"] == "RequestTimeoutError"
  end

  test "returns request timeout for list tasks" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 8,
      "method" => "tasks/list",
      "params" => %{}
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(@request_timeout_query_opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == -32000
    assert body["error"]["data"]["type"] == "RequestTimeoutError"
  end

  test "push config set accepts js sdk pushNotificationConfig param" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 10,
      "method" => "tasks/pushNotificationConfig/set",
      "params" => %{
        "taskId" => "task-1",
        "pushNotificationConfig" => %{"id" => "cfg-1", "url" => "https://example.com/webhook"}
      }
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(@push_opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["result"]["id"] == "cfg-1"
  end

  test "push config get/list/delete accept js sdk id fields" do
    get_payload = %{
      "jsonrpc" => "2.0",
      "id" => 11,
      "method" => "tasks/pushNotificationConfig/get",
      "params" => %{"id" => "task-1", "pushNotificationConfigId" => "cfg-1"}
    }

    get_conn =
      conn("POST", "/", Jason.encode!(get_payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(@push_opts)

    assert get_conn.status == 200
    get_body = Jason.decode!(get_conn.resp_body)
    assert get_body["result"]["id"] == "cfg-1"

    list_payload = %{
      "jsonrpc" => "2.0",
      "id" => 12,
      "method" => "tasks/pushNotificationConfig/list",
      "params" => %{"id" => "task-1"}
    }

    list_conn =
      conn("POST", "/", Jason.encode!(list_payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(@push_opts)

    assert list_conn.status == 200
    list_body = Jason.decode!(list_conn.resp_body)
    assert is_list(get_in(list_body, ["result", "pushNotificationConfigs"]))

    delete_payload = %{
      "jsonrpc" => "2.0",
      "id" => 13,
      "method" => "tasks/pushNotificationConfig/delete",
      "params" => %{"id" => "task-1", "pushNotificationConfigId" => "cfg-1"}
    }

    delete_conn =
      conn("POST", "/", Jason.encode!(delete_payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(@push_opts)

    assert delete_conn.status == 200
    delete_body = Jason.decode!(delete_conn.resp_body)
    assert delete_body["result"] == %{}
  end

  test "tasks/get accepts id param" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 14,
      "method" => "tasks/get",
      "params" => %{"id" => "task-1"}
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert get_in(body, ["result", "id"]) == "task-1"
  end

  test "tasks/cancel accepts id param" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 15,
      "method" => "tasks/cancel",
      "params" => %{"id" => "task-1"}
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert get_in(body, ["result", "status", "state"]) == "canceled"
  end

  test "tasks/resubscribe accepts id param and emits SSE data" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 16,
      "method" => "tasks/resubscribe",
      "params" => %{"id" => "task-1"}
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "text/event-stream")
      |> A2A.Server.JSONRPC.Plug.call(@opts)

    assert conn.status == 200
    assert is_binary(conn.resp_body) and String.contains?(conn.resp_body, "data:")
  end

  test "tasks/subscribe accepts id param" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 17,
      "method" => "tasks/subscribe",
      "params" => %{"id" => "task-1"}
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "text/event-stream")
      |> A2A.Server.JSONRPC.Plug.call(@opts)

    assert conn.status == 200
  end
end
