defmodule A2A.IntegrationRESTErrorTest do
  use ExUnit.Case, async: false

  setup_all do
    plug_opts = [executor: A2A.TestExecutor, required_extensions: ["urn:required"]]
    server = A2A.TestHTTPServer.start(A2A.Server.REST.Plug, plug_opts: plug_opts)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)
    {:ok, base_url: server.base_url}
  end

  test "missing content type returns error" do
    opts = A2A.Server.REST.Plug.init(executor: A2A.TestExecutor)

    conn =
      Plug.Test.conn(
        "POST",
        "/v1/message:send",
        Jason.encode!(%{"message" => %{"messageId" => "msg"}})
      )

    conn = A2A.Server.REST.Plug.call(conn, opts)

    assert conn.status == 415
  end

  test "missing required extensions returns error", %{base_url: base_url} do
    {:error, error} =
      A2A.Client.send_message(
        base_url,
        [message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}],
        transport: A2A.Transport.REST
      )

    assert error.type == :extension_support_required
  end
end
