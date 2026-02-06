defmodule A2A.ServerRouterMatrixTest do
  use ExUnit.Case, async: true

  import Plug.Test

  defmodule MatrixRouter do
    use Plug.Router
    import A2A.Server.Router

    plug(:match)
    plug(:dispatch)

    rest("/api-v03", executor: A2A.TestExecutor, base_path: "/v1")
    rest("/api-latest", executor: A2A.TestExecutor, version: :latest)
    jsonrpc("/rpc-v03", executor: A2A.TestExecutor)
    jsonrpc("/rpc-latest", executor: A2A.TestExecutor, version: :latest)
  end

  test "mounted REST routers keep independent version/path behavior" do
    payload = %{
      "message" => %{"messageId" => "msg-1", "role" => "user", "parts" => [%{"text" => "hello"}]}
    }

    v03_conn =
      conn("POST", "/api-v03/v1/message:send", Jason.encode!(payload))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> MatrixRouter.call([])

    latest_conn =
      conn("POST", "/api-latest/message:send", Jason.encode!(payload))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> MatrixRouter.call([])

    assert v03_conn.status == 200
    assert latest_conn.status == 200
  end

  test "mounted JSON-RPC routers support both v0.3 and latest methods" do
    v03_payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "message/send",
      "params" => %{
        "message" => %{"messageId" => "msg-1", "role" => "user", "parts" => [%{"text" => "hello"}]}
      }
    }

    latest_payload = %{
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

    latest_conn =
      conn("POST", "/rpc-latest", Jason.encode!(latest_payload))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> MatrixRouter.call([])

    assert v03_conn.status == 200
    assert latest_conn.status == 200
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
