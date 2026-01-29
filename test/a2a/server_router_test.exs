defmodule A2A.Server.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  defmodule TestRouter do
    use Plug.Router
    import A2A.Server.Router

    plug(:match)
    plug(:dispatch)

    forward("/passthrough", to: Plug.Logger)

    rest("/v1", executor: A2A.TestExecutor)
    jsonrpc("/rpc", executor: A2A.TestExecutor)
  end

  defmodule BasePathRouter do
    use Plug.Router
    import A2A.Server.Router

    plug(:match)
    plug(:dispatch)

    rest("/api", executor: A2A.TestExecutor, base_path: "/v1")
  end

  defmodule LatestRouter do
    use Plug.Router
    import A2A.Server.Router

    plug(:match)
    plug(:dispatch)

    jsonrpc("/rpc-latest", executor: A2A.TestExecutor, version: :latest)
  end

  defmodule RequiredExtRouter do
    use Plug.Router
    import A2A.Server.Router

    plug(:match)
    plug(:dispatch)

    rest("/v1", executor: A2A.TestExecutor, required_extensions: ["urn:required"])
  end

  defmodule RequiredExtJsonRpcRouter do
    use Plug.Router
    import A2A.Server.Router

    plug(:match)
    plug(:dispatch)

    jsonrpc("/rpc-required", executor: A2A.TestExecutor, required_extensions: ["urn:required"])
  end

  defp message_payload(role) do
    %{
      "messageId" => "msg-1",
      "role" => role,
      "parts" => [%{"text" => "hello"}]
    }
  end

  defp rest_payload do
    %{"message" => message_payload("user")}
  end

  defp jsonrpc_payload(id, method, role) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => %{
        "message" => message_payload(role)
      }
    }
  end

  defp request_conn(path, payload, router, headers \\ []) do
    conn =
      conn("POST", path, Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")

    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)

    router.call(conn, [])
  end

  defp decode_body(conn) do
    Jason.decode!(conn.resp_body)
  end

  test "rest helper forwards without base_path" do
    payload = rest_payload()

    conn = request_conn("/v1/message:send", payload, TestRouter)

    assert conn.status == 200
    body = decode_body(conn)
    assert body["task"]["id"] == "task-1"
  end

  test "jsonrpc helper forwards to plug" do
    payload = jsonrpc_payload(1, "message/send", "user")

    conn = request_conn("/rpc", payload, TestRouter)

    assert conn.status == 200
    body = decode_body(conn)
    assert body["result"]["task"]["id"] == "task-1"
  end

  test "router macros coexist with other forwards" do
    conn = conn("GET", "/passthrough") |> TestRouter.call([])
    assert conn.status in [404, 500] or is_nil(conn.status)
  end

  test "rest helper forwards with custom base_path" do
    payload = rest_payload()

    conn = request_conn("/api/v1/message:send", payload, BasePathRouter)

    assert conn.status == 200
    body = decode_body(conn)
    assert body["task"]["id"] == "task-1"
  end

  test "rest helper forwards extensions header" do
    payload = rest_payload()

    conn =
      request_conn("/v1/message:send", payload, TestRouter, [
        {"a2a-extensions", "urn:test:ext"}
      ])

    assert conn.status == 200
    assert get_resp_header(conn, "a2a-extensions") == ["urn:test:ext"]
  end

  test "rest helper supports legacy extensions header" do
    payload = rest_payload()

    conn =
      request_conn("/v1/message:send", payload, TestRouter, [
        {"x-a2a-extensions", "urn:test:legacy"}
      ])

    assert conn.status == 200
    assert get_resp_header(conn, "a2a-extensions") == ["urn:test:legacy"]
  end

  test "jsonrpc helper forwards init_opts" do
    payload = jsonrpc_payload(2, "SendMessage", "ROLE_USER")

    conn = request_conn("/rpc-latest", payload, LatestRouter)

    assert conn.status == 200
    body = decode_body(conn)
    assert body["result"]["task"]["id"] == "task-1"
  end

  test "jsonrpc helper forwards extensions header" do
    payload = jsonrpc_payload(3, "message/send", "user")

    conn = request_conn("/rpc", payload, TestRouter, [{"a2a-extensions", "urn:test:ext"}])

    assert conn.status == 200
    assert get_resp_header(conn, "a2a-extensions") == ["urn:test:ext"]
  end

  test "jsonrpc helper supports legacy extensions header" do
    payload = jsonrpc_payload(4, "message/send", "user")

    conn = request_conn("/rpc", payload, TestRouter, [{"x-a2a-extensions", "urn:test:legacy"}])

    assert conn.status == 200
    assert get_resp_header(conn, "a2a-extensions") == ["urn:test:legacy"]
  end

  test "rest helper rejects missing required extension" do
    conn =
      conn("GET", "/v1/tasks/task-123")
      |> RequiredExtRouter.call([])

    assert conn.status == 400
    body = decode_body(conn)
    assert body["error"]["type"] == "ExtensionSupportRequiredError"
  end

  test "jsonrpc helper rejects missing required extension" do
    payload = jsonrpc_payload(5, "message/send", "user")

    conn = request_conn("/rpc-required", payload, RequiredExtJsonRpcRouter)

    assert conn.status == 200
    body = decode_body(conn)
    assert body["error"]["data"]["type"] == "ExtensionSupportRequiredError"
  end

  test "jsonrpc helper rejects mismatched required extension" do
    payload = jsonrpc_payload(6, "message/send", "user")

    conn =
      request_conn("/rpc-required", payload, RequiredExtJsonRpcRouter, [
        {"a2a-extensions", "urn:other"}
      ])

    assert conn.status == 200
    body = decode_body(conn)
    assert body["error"]["data"]["type"] == "ExtensionSupportRequiredError"
  end

  test "jsonrpc helper rejects legacy header mismatch" do
    payload = jsonrpc_payload(7, "message/send", "user")

    conn =
      request_conn("/rpc-required", payload, RequiredExtJsonRpcRouter, [
        {"x-a2a-extensions", "urn:other"}
      ])

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["data"]["type"] == "ExtensionSupportRequiredError"
  end

  test "jsonrpc helper accepts required extension via legacy header" do
    payload = jsonrpc_payload(8, "message/send", "user")

    conn =
      request_conn("/rpc-required", payload, RequiredExtJsonRpcRouter, [
        {"x-a2a-extensions", "urn:required"}
      ])

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["result"]["task"]["id"] == "task-1"
  end
end
