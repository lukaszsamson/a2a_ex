defmodule A2A.ServerRouterMatrixTest do
  use ExUnit.Case, async: true

  import Plug.Test

  defmodule MatrixRouter do
    use Plug.Router
    import A2A.Server.Router

    plug(:match)
    plug(:dispatch)

    rest("/api-v03", executor: A2A.TestExecutor, base_path: "/v1")
    rest("/api-v1", executor: A2A.TestExecutor, version: :v1_0)
    jsonrpc("/rpc-v03", executor: A2A.TestExecutor)
    jsonrpc("/rpc-v1", executor: A2A.TestExecutor, version: :v1_0)
  end

  test "mounted REST routers keep independent version/path behavior" do
    payload = %{
      "message" => %{"messageId" => "msg-1", "role" => "user", "parts" => [%{"text" => "hello"}]}
    }

    v03_conn =
      conn("POST", "/api-v03/v1/message:send", Jason.encode!(payload))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> MatrixRouter.call([])

    v1_payload = put_in(payload, ["message", "role"], "ROLE_USER")

    v1_conn =
      conn("POST", "/api-v1/message:send", Jason.encode!(v1_payload))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("a2a-version", "1.0")
      |> MatrixRouter.call([])

    assert v03_conn.status == 200
    assert v1_conn.status == 200
  end

  test "mounted JSON-RPC routers support separate v0.3 and v1.0 methods" do
    v03_payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "message/send",
      "params" => %{
        "message" => %{
          "messageId" => "msg-1",
          "role" => "user",
          "parts" => [%{"text" => "hello"}]
        }
      }
    }

    v1_payload = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "SendMessage",
      "params" => %{
        "message" => %{
          "messageId" => "msg-1",
          "role" => "ROLE_USER",
          "parts" => [%{"text" => "hello"}]
        }
      }
    }

    v03_conn =
      conn("POST", "/rpc-v03", Jason.encode!(v03_payload))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> MatrixRouter.call([])

    v1_conn =
      conn("POST", "/rpc-v1", Jason.encode!(v1_payload))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("a2a-version", "1.0")
      |> MatrixRouter.call([])

    assert v03_conn.status == 200
    assert v1_conn.status == 200
  end

  test "wrong mount path does not match" do
    payload = %{
      "message" => %{"messageId" => "msg-1", "role" => "user", "parts" => [%{"text" => "hello"}]}
    }

    conn =
      conn("POST", "/api-v03/message:send", Jason.encode!(payload))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> MatrixRouter.call([])

    assert conn.status == 404
  end
end
