defmodule A2A.ServerRESTPlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @opts A2A.Server.REST.Plug.init(executor: A2A.TestExecutor)

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

  defmodule ProtoMessageExecutor do
    def handle_send_message(_request, _ctx) do
      {:ok,
       %A2A.Types.Message{
         message_id: "msg-2",
         role: :agent,
         parts: [%A2A.Types.TextPart{text: "hello"}]
       }}
    end
  end

  @timeout_opts A2A.Server.REST.Plug.init(
                  executor: SlowExecutor,
                  capabilities: %{streaming: true},
                  stream_timeout: 10
                )
  @request_timeout_opts A2A.Server.REST.Plug.init(
                          executor: SlowRequestExecutor,
                          request_timeout: 10
                        )
  @latest_opts A2A.Server.REST.Plug.init(executor: A2A.TestExecutor, version: :latest)
  @proto_opts A2A.Server.REST.Plug.init(executor: A2A.TestExecutor, wire_format: :proto_json)
  @proto_message_opts A2A.Server.REST.Plug.init(
                        executor: ProtoMessageExecutor,
                        wire_format: :proto_json
                      )
  @push_opts A2A.Server.REST.Plug.init(
               executor: A2A.TestExecutor,
               capabilities: %{push_notifications: true}
             )
  @push_latest_opts A2A.Server.REST.Plug.init(
                      executor: A2A.TestExecutor,
                      version: :latest,
                      capabilities: %{push_notifications: true}
                    )
  @extended_opts A2A.Server.REST.Plug.init(
                   executor: A2A.TestExecutor,
                   version: :latest,
                   capabilities: %{extended_agent_card: true}
                 )
  @subscribe_get_opts A2A.Server.REST.Plug.init(
                        executor: A2A.TestExecutor,
                        capabilities: %{streaming: true},
                        subscribe_verb: :get
                      )

  @extension_opts A2A.Server.REST.Plug.init(
                    executor: A2A.TestExecutor,
                    required_extensions: ["urn:required"]
                  )

  test "handles send message" do
    payload = %{
      "message" => %{
        "messageId" => "msg-1",
        "role" => "user",
        "parts" => [%{"text" => "hello"}]
      }
    }

    conn =
      conn("POST", "/v1/message:send", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.REST.Plug.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["task"]["id"] == "task-1"
    assert body["task"]["contextId"] == "ctx-1"
  end

  test "handles proto-json send message payload in compatibility mode" do
    payload = %{
      "message" => %{
        "messageId" => "msg-1",
        "role" => "ROLE_USER",
        "content" => [%{"text" => "hello"}]
      }
    }

    conn =
      conn("POST", "/v1/message:send", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.REST.Plug.call(@proto_opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["task"]["id"] == "task-1"
  end

  test "encodes proto-json message response in compatibility mode" do
    payload = %{
      "message" => %{
        "messageId" => "msg-1",
        "role" => "ROLE_USER",
        "content" => [%{"text" => "hello"}]
      }
    }

    conn =
      conn("POST", "/v1/message:send", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.REST.Plug.call(@proto_message_opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["message"]["role"] == "ROLE_AGENT"
    assert body["message"]["content"] == [%{"text" => "hello"}]
    refute Map.has_key?(body["message"], "parts")
  end

  test "echoes request id" do
    payload = %{
      "message" => %{
        "messageId" => "msg-1",
        "role" => "user",
        "parts" => [%{"text" => "hello"}]
      }
    }

    conn =
      conn("POST", "/v1/message:send", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-request-id", "req-123")
      |> A2A.Server.REST.Plug.call(@opts)

    assert conn.status == 200
    assert get_resp_header(conn, "x-request-id") == ["req-123"]
  end

  test "rejects missing content type" do
    payload = %{
      "message" => %{
        "messageId" => "msg-1",
        "role" => "user",
        "parts" => [%{"text" => "hello"}]
      }
    }

    conn =
      conn("POST", "/v1/message:send", Jason.encode!(payload)) |> A2A.Server.REST.Plug.call(@opts)

    assert conn.status == 415
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "ContentTypeNotSupportedError"
  end

  test "rejects oversized request body" do
    body = String.duplicate("a", 8_000_001)

    conn =
      conn("POST", "/v1/message:send", body)
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.REST.Plug.call(@opts)

    assert conn.status == 502
    response = Jason.decode!(conn.resp_body)
    assert response["error"]["type"] == "InvalidAgentResponseError"
    assert response["error"]["message"] == "Request too large"
  end

  test "handles get task" do
    conn = conn("GET", "/v1/tasks/task-123") |> A2A.Server.REST.Plug.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["id"] == "task-123"
    assert body["status"]["state"] == "completed"
  end

  test "echoes extensions header" do
    payload = %{
      "message" => %{
        "messageId" => "msg-1",
        "role" => "user",
        "parts" => [%{"text" => "hello"}]
      }
    }

    conn =
      conn("POST", "/v1/message:send", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("a2a-extensions", "urn:example:ext")
      |> A2A.Server.REST.Plug.call(@opts)

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "a2a-extensions") == ["urn:example:ext"]
  end

  test "rejects mismatched version header" do
    conn =
      conn("GET", "/tasks/task-123")
      |> put_req_header("a2a-version", "9.9")
      |> A2A.Server.REST.Plug.call(@latest_opts)

    assert conn.status == 426
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "VersionNotSupportedError"
  end

  test "handles push notification config list" do
    conn =
      conn("GET", "/v1/tasks/task-1/pushNotificationConfigs")
      |> A2A.Server.REST.Plug.call(@push_opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert [%{"id" => "cfg-1"}] = body
  end

  test "handles latest push notification config list with configs wrapper" do
    conn =
      conn("GET", "/tasks/task-1/pushNotificationConfigs")
      |> A2A.Server.REST.Plug.call(@push_latest_opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert [%{"id" => "cfg-1"}] = body["configs"]
  end

  test "handles extended agent card" do
    conn = conn("GET", "/extendedAgentCard") |> A2A.Server.REST.Plug.call(@extended_opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["name"] == "extended"
  end

  test "handles v0.3 card endpoint" do
    v0_card_opts =
      A2A.Server.REST.Plug.init(
        executor: A2A.TestExecutor,
        version: :v0_3,
        capabilities: %{extended_agent_card: true}
      )

    conn = conn("GET", "/v1/card") |> A2A.Server.REST.Plug.call(v0_card_opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["name"] == "extended"
  end

  test "supports GET subscribe when configured" do
    conn =
      conn("GET", "/v1/tasks/task-1:subscribe") |> A2A.Server.REST.Plug.call(@subscribe_get_opts)

    assert conn.status == 200
    assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")
  end

  test "rejects missing required extensions" do
    conn = conn("GET", "/v1/tasks/task-123") |> A2A.Server.REST.Plug.call(@extension_opts)

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "ExtensionSupportRequiredError"
  end

  test "returns request timeout for stream" do
    payload = %{
      "message" => %{
        "messageId" => "msg-1",
        "role" => "user",
        "parts" => [%{"text" => "hello"}]
      }
    }

    conn =
      conn("POST", "/v1/message:stream", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.REST.Plug.call(@timeout_opts)

    assert conn.status == 200
    events = A2A.Transport.SSE.decode_events(conn.resp_body)
    [event | _] = Enum.map(events, &Jason.decode!/1)
    assert event["error"]["type"] == "StreamTimeoutError"
  end

  test "returns request timeout for non-streaming request" do
    payload = %{
      "message" => %{
        "messageId" => "msg-1",
        "role" => "user",
        "parts" => [%{"text" => "hello"}]
      }
    }

    conn =
      conn("POST", "/v1/message:send", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> A2A.Server.REST.Plug.call(@request_timeout_opts)

    assert conn.status == 504
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "RequestTimeoutError"
  end
end
