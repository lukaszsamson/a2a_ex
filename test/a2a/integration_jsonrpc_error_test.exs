defmodule A2A.IntegrationJSONRPCErrorTest do
  use ExUnit.Case, async: false

  setup_all do
    plug_opts = [executor: A2A.TestExecutor]
    server = A2A.TestHTTPServer.start(A2A.Server.JSONRPC.Plug, plug_opts: plug_opts)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)
    {:ok, base_url: server.base_url}
  end

  test "invalid params returns error" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tasks/get",
      "params" => %{}
    }

    conn = Plug.Test.conn("POST", "/", Jason.encode!(payload))
    conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")

    conn =
      A2A.Server.JSONRPC.Plug.call(conn, A2A.Server.JSONRPC.Plug.init(executor: A2A.TestExecutor))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == -32602
  end
end
