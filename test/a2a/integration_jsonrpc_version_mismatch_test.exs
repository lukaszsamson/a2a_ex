defmodule A2A.IntegrationJSONRPCVersionMismatchTest do
  use ExUnit.Case, async: false

  setup_all do
    plug_opts = [executor: A2A.TestExecutor, version: :latest]
    server = A2A.TestHTTPServer.start(A2A.Server.JSONRPC.Plug, plug_opts: plug_opts)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)
    {:ok, base_url: server.base_url}
  end

  test "client receives version not supported", %{base_url: base_url} do
    {:error, error} =
      A2A.Client.send_message(
        base_url,
        [message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}],
        transport: A2A.Transport.JSONRPC,
        version: :latest,
        headers: [{"a2a-version", "9.9"}],
        req_options: [retry: false]
      )

    assert error.type == :version_not_supported
  end
end
