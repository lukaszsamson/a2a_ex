defmodule A2A.IntegrationJSONRPCBatchTest do
  use ExUnit.Case, async: false

  setup_all do
    plug_opts = [executor: A2A.TestExecutor]
    server = A2A.TestHTTPServer.start(A2A.Server.JSONRPC.Plug, plug_opts: plug_opts)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)
    {:ok, base_url: server.base_url}
  end

  test "batch request returns invalid request", %{base_url: base_url} do
    batch = [
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "message/send",
        "params" => %{"message" => %{"messageId" => "msg-1", "role" => "user", "parts" => []}}
      }
    ]

    {:ok, response} =
      Req.request(
        method: :post,
        url: base_url,
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(batch)
      )

    body = if is_map(response.body), do: response.body, else: Jason.decode!(response.body)
    assert body["error"]["code"] == -32600
  end

  test "empty batch returns invalid request", %{base_url: base_url} do
    {:ok, response} =
      Req.request(
        method: :post,
        url: base_url,
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!([])
      )

    body = if is_map(response.body), do: response.body, else: Jason.decode!(response.body)
    assert body["error"]["code"] == -32600
  end

  test "mixed batch returns invalid request", %{base_url: base_url} do
    batch = [
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "message/send",
        "params" => %{"message" => %{"messageId" => "msg-1", "role" => "user", "parts" => []}}
      },
      %{"jsonrpc" => "2.0", "id" => 2, "method" => "unknown"}
    ]

    {:ok, response} =
      Req.request(
        method: :post,
        url: base_url,
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(batch)
      )

    body = if is_map(response.body), do: response.body, else: Jason.decode!(response.body)
    assert body["error"]["code"] == -32600
  end
end
