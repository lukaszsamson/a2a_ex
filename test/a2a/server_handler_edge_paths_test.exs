defmodule A2A.ServerHandlerEdgePathsTest do
  use ExUnit.Case, async: true

  import Plug.Test

  defmodule NoStreamExecutor do
    @behaviour A2A.Server.Executor

    def handle_send_message(_request, _ctx) do
      {:ok,
       %A2A.Types.Task{
         id: "task-1",
         context_id: "ctx-1",
         status: %A2A.Types.TaskStatus{state: :submitted}
       }}
    end

    def handle_get_task(_task_id, _query, _ctx),
      do: {:error, A2A.Error.new(:task_not_found, "missing")}

    def handle_list_tasks(_request, _ctx), do: {:ok, %A2A.Types.ListTasksResponse{tasks: []}}

    def handle_cancel_task(_task_id, _ctx),
      do: {:error, A2A.Error.new(:task_not_found, "missing")}
  end

  defmodule NoPushHandlerExecutor do
    @behaviour A2A.Server.Executor

    def handle_send_message(_request, _ctx) do
      {:ok,
       %A2A.Types.Task{
         id: "task-1",
         context_id: "ctx-1",
         status: %A2A.Types.TaskStatus{state: :submitted}
       }}
    end

    def handle_get_task(_task_id, _query, _ctx),
      do: {:error, A2A.Error.new(:task_not_found, "missing")}

    def handle_list_tasks(_request, _ctx), do: {:ok, %A2A.Types.ListTasksResponse{tasks: []}}

    def handle_cancel_task(_task_id, _ctx),
      do: {:error, A2A.Error.new(:task_not_found, "missing")}
  end

  test "REST stream endpoint returns unsupported operation when stream handler is missing" do
    opts =
      A2A.Server.REST.Plug.init(
        executor: NoStreamExecutor,
        capabilities: %{streaming: true}
      )

    payload = %{
      "message" => %{"messageId" => "msg-1", "role" => "user", "parts" => [%{"text" => "hi"}]}
    }

    conn =
      conn("POST", "/v1/message:stream", Jason.encode!(payload))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> A2A.Server.REST.Plug.call(opts)

    assert conn.status == 501
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "UnsupportedOperationError"
  end

  test "JSON-RPC stream method returns unsupported operation when stream handler is missing" do
    opts =
      A2A.Server.JSONRPC.Plug.init(
        executor: NoStreamExecutor,
        capabilities: %{streaming: true}
      )

    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "message/stream",
      "params" => %{
        "message" => %{"messageId" => "msg-1", "role" => "user", "parts" => [%{"text" => "hi"}]}
      }
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == -32000
    assert body["error"]["data"]["type"] == "UnsupportedOperationError"
  end

  test "REST push config set returns unsupported operation when push handler is missing" do
    opts =
      A2A.Server.REST.Plug.init(
        executor: NoPushHandlerExecutor,
        capabilities: %{push_notifications: true}
      )

    payload = %{"config" => %{"id" => "cfg-1", "url" => "https://example.com/webhook"}}

    conn =
      conn("POST", "/v1/tasks/task-1/pushNotificationConfigs", Jason.encode!(payload))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> A2A.Server.REST.Plug.call(opts)

    assert conn.status == 501
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["type"] == "UnsupportedOperationError"
  end
end
