defmodule A2A.WWWAuthenticateTest do
  use ExUnit.Case, async: true
  import Plug.Test

  defmodule AuthExecutor do
    @behaviour A2A.Server.Executor

    def handle_send_message(_request, _ctx) do
      {:error,
       A2A.Error.new(:unauthorized, "missing token",
         data: %{www_authenticate: "Bearer realm=\"a2a\""}
       )}
    end

    def handle_get_task(_task_id, _query, _ctx),
      do: {:error, A2A.Error.new(:unauthorized, "missing token")}

    def handle_list_tasks(_request, _ctx),
      do: {:error, A2A.Error.new(:unauthorized, "missing token")}

    def handle_cancel_task(_task_id, _ctx),
      do: {:error, A2A.Error.new(:unauthorized, "missing token")}
  end

  test "adds www-authenticate header" do
    opts = A2A.Server.REST.Plug.init(executor: AuthExecutor)

    conn =
      conn("POST", "/v1/message:send", Jason.encode!(%{"message" => %{"messageId" => "msg"}}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> A2A.Server.REST.Plug.call(opts)

    assert conn.status == 401
    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == ["Bearer realm=\"a2a\""]
  end

  test "adds www-authenticate header for jsonrpc" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "message/send",
      "params" => %{"message" => %{"messageId" => "msg", "role" => "user", "parts" => []}}
    }

    conn =
      conn("POST", "/", Jason.encode!(payload))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> A2A.Server.JSONRPC.Plug.call(A2A.Server.JSONRPC.Plug.init(executor: AuthExecutor))

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == ["Bearer realm=\"a2a\""]
  end
end
