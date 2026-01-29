defmodule A2A.TransportRESTTest do
  use ExUnit.Case, async: false

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
end
