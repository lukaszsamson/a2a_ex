defmodule A2A.TransportRESTTest do
  use ExUnit.Case, async: false

  defmodule ProtoJSONCapturePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      parent = Keyword.fetch!(opts, :parent)
      {:ok, body, conn} = read_body(conn)
      payload = if body == "", do: %{}, else: Jason.decode!(body)
      send(parent, {:proto_request_payload, payload})

      response = %{
        "message" => %{
          "messageId" => "msg-2",
          "role" => "ROLE_AGENT",
          "content" => [%{"text" => "hello from proto"}]
        }
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    end
  end

  defmodule PushSetCapturePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      parent = Keyword.fetch!(opts, :parent)
      {:ok, body, conn} = read_body(conn)
      payload = if body == "", do: %{}, else: Jason.decode!(body)
      send(parent, {:push_set_payload, payload})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"id" => "cfg-1", "url" => "https://example.com/webhook"}))
    end
  end

  defmodule CardPathCapturePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      parent = Keyword.fetch!(opts, :parent)
      send(parent, {:card_request_path, conn.request_path})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"name" => "extended"}))
    end
  end

  setup_all do
    server = A2A.TestHTTPServer.start(A2A.TestRESTSuccessPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)
    {:ok, base_url: server.base_url}
  end

  test "send_message returns task", %{base_url: base_url} do
    config = A2A.Client.Config.new(base_url, transport: A2A.Transport.REST)

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    assert {:ok, %A2A.Types.Task{id: "task-1"}} = A2A.Transport.REST.send_message(config, request)
  end

  test "stream_message returns stream responses", %{base_url: base_url} do
    config = A2A.Client.Config.new(base_url, transport: A2A.Transport.REST)

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    {:ok, stream} = A2A.Transport.REST.stream_message(config, request)
    events = Enum.to_list(stream)

    assert [%A2A.Types.StreamResponse{task: %A2A.Types.Task{id: "task-1"}} | _] = events
  end

  test "subscribe uses GET without body" do
    server = A2A.TestHTTPServer.start(A2A.TestRESTSubscribeGetPlug, plug_opts: [parent: self()])
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.REST,
        subscribe_verb: :get
      )

    assert {:ok, stream} = A2A.Transport.REST.subscribe(config, "task-1")
    assert Enum.to_list(stream) == []

    assert_received {:subscribe_request, %{method: :get, body: body}}
    assert body == ""
  end

  test "resubscribe uses last-event-id header" do
    server = A2A.TestHTTPServer.start(A2A.TestRESTResubscribePlug, plug_opts: [parent: self()])
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.REST,
        subscribe_verb: :get
      )

    assert {:ok, stream} = A2A.Transport.REST.resubscribe(config, "task-1", %{cursor: "2"})
    assert Enum.to_list(stream) == []

    assert_received %{method: :get, body: body, last_event_id: "2"}
    assert body == ""
  end

  test "stream_message surfaces error events" do
    server = A2A.TestHTTPServer.start(A2A.TestRESTStreamErrorPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config = A2A.Client.Config.new(server.base_url, transport: A2A.Transport.REST)

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    {:ok, stream} = A2A.Transport.REST.stream_message(config, request)
    [event] = Enum.take(stream, 1)

    assert %A2A.Types.StreamError{error: %A2A.Error{type: :task_not_found}} = event
  end

  test "stream_message returns raw details on handshake error" do
    server = A2A.TestHTTPServer.start(A2A.TestRESTStreamHandshakeErrorPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config = A2A.Client.Config.new(server.base_url, transport: A2A.Transport.REST)

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    assert {:error, %A2A.Error{type: :http_error, raw: raw}} =
             A2A.Transport.REST.stream_message(config, request)

    assert raw.status == 400
  end

  test "list_tasks returns response", %{base_url: base_url} do
    config = A2A.Client.Config.new(base_url, transport: A2A.Transport.REST)
    request = %A2A.Types.ListTasksRequest{}

    assert {:ok, %A2A.Types.ListTasksResponse{tasks: []}} =
             A2A.Transport.REST.list_tasks(config, request)
  end

  test "send_message returns error on invalid JSON" do
    server = A2A.TestHTTPServer.start(A2A.TestRESTErrorPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.REST,
        req_options: [retry: false]
      )

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    assert {:error, %A2A.Error{type: :invalid_agent_response}} =
             A2A.Transport.REST.send_message(config, request)
  end

  test "send_message uses proto-json wire format when configured" do
    server = A2A.TestHTTPServer.start(ProtoJSONCapturePlug, plug_opts: [parent: self()])
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.REST,
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
             A2A.Transport.REST.send_message(config, request)

    assert_received {:proto_request_payload, payload}
    assert payload["message"]["role"] == "ROLE_USER"
    assert payload["message"]["content"] == [%{"text" => "hello"}]
    refute Map.has_key?(payload["message"], "parts")
  end

  test "list_tasks maps error response" do
    server = A2A.TestHTTPServer.start(A2A.TestRESTErrorPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.REST,
        req_options: [retry: false]
      )

    request = %A2A.Types.ListTasksRequest{}

    assert {:error, %A2A.Error{type: :task_not_found, raw: raw}} =
             A2A.Transport.REST.list_tasks(config, request)

    assert raw.status == 500
  end

  test "push config set sends wrapped config body for v0.3" do
    server = A2A.TestHTTPServer.start(PushSetCapturePlug, plug_opts: [parent: self()])
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config = A2A.Client.Config.new(server.base_url, transport: A2A.Transport.REST)

    request = %A2A.Types.PushNotificationConfig{id: "cfg-1", url: "https://example.com/webhook"}

    assert {:ok, %A2A.Types.PushNotificationConfig{id: "cfg-1"}} =
             A2A.Transport.REST.push_notification_config_set(config, "task-1", request)

    assert_received {:push_set_payload, payload}
    assert payload["config"]["id"] == "cfg-1"
    assert payload["config"]["url"] == "https://example.com/webhook"
  end

  test "uses /v1/card for v0.3 extended card and /extendedAgentCard for latest" do
    server = A2A.TestHTTPServer.start(CardPathCapturePlug, plug_opts: [parent: self()])
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    v03 = A2A.Client.Config.new(server.base_url, transport: A2A.Transport.REST, version: :v0_3)

    latest =
      A2A.Client.Config.new(server.base_url, transport: A2A.Transport.REST, version: :latest)

    assert {:ok, %A2A.Types.AgentCard{name: "extended"}} =
             A2A.Transport.REST.get_extended_agent_card(v03)

    assert_received {:card_request_path, "/v1/card"}

    assert {:ok, %A2A.Types.AgentCard{name: "extended"}} =
             A2A.Transport.REST.get_extended_agent_card(latest)

    assert_received {:card_request_path, "/extendedAgentCard"}
  end
end
