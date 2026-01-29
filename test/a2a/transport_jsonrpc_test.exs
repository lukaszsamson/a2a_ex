defmodule A2A.TransportJSONRPCTest do
  use ExUnit.Case, async: false

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
end
