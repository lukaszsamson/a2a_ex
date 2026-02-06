defmodule A2A.IntegrationClientServerParityTest do
  use ExUnit.Case, async: false

  defmodule SignedAgentCardPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case conn.request_path do
        "/.well-known/agent-card.json" ->
          body = %{
            "name" => "signed-demo",
            "url" => "https://agent.example.com",
            "capabilities" => %{"streaming" => true},
            "signatures" => [
              %{"protected" => "invalid-protected", "signature" => "invalid-signature"},
              %{"protected" => "valid-protected", "signature" => "valid-signature"}
            ]
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(body))

        _ ->
          send_resp(conn, 404, "")
      end
    end
  end

  defmodule SignedAgentCardFailurePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case conn.request_path do
        "/.well-known/agent-card.json" ->
          body = %{
            "name" => "signed-demo",
            "url" => "https://agent.example.com",
            "capabilities" => %{"streaming" => true},
            "signatures" => [
              %{"protected" => "p1", "signature" => "s1"}
            ]
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(body))

        _ ->
          send_resp(conn, 404, "")
      end
    end
  end

  setup_all do
    rest_server =
      A2A.TestHTTPServer.start(A2A.Server.REST.Plug,
        plug_opts: [
          executor: A2A.TestExecutor,
          capabilities: %{streaming: true, push_notifications: true, extended_agent_card: true}
        ]
      )

    jsonrpc_server =
      A2A.TestHTTPServer.start(A2A.Server.JSONRPC.Plug,
        plug_opts: [
          executor: A2A.TestExecutor,
          capabilities: %{streaming: true, push_notifications: true, extended_agent_card: true}
        ]
      )

    on_exit(fn ->
      A2A.TestHTTPServer.stop(rest_server.ref)
      A2A.TestHTTPServer.stop(jsonrpc_server.ref)
    end)

    {:ok,
     rest_base_url: rest_server.base_url,
     jsonrpc_base_url: jsonrpc_server.base_url}
  end

  test "REST and JSON-RPC parity: get_task and cancel_task", %{
    rest_base_url: rest_base_url,
    jsonrpc_base_url: jsonrpc_base_url
  } do
    transports = [
      {A2A.Transport.REST, rest_base_url},
      {A2A.Transport.JSONRPC, jsonrpc_base_url}
    ]

    Enum.each(transports, fn {transport, base_url} ->
      assert {:ok, %A2A.Types.Task{id: "task-1", status: %A2A.Types.TaskStatus{state: :completed}}} =
               A2A.Client.get_task(base_url, "task-1", transport: transport)

      assert {:ok, %A2A.Types.Task{id: "task-1", status: %A2A.Types.TaskStatus{state: :canceled}}} =
               A2A.Client.cancel_task(base_url, "task-1", transport: transport)
    end)
  end

  test "REST and JSON-RPC parity: push callback set/get/list/delete", %{
    rest_base_url: rest_base_url,
    jsonrpc_base_url: jsonrpc_base_url
  } do
    transports = [
      {A2A.Transport.REST, rest_base_url},
      {A2A.Transport.JSONRPC, jsonrpc_base_url}
    ]

    Enum.each(transports, fn {transport, base_url} ->
      assert {:ok, %A2A.Types.PushNotificationConfig{id: "cfg-1", url: "https://callback.example.com"}} =
               A2A.Client.push_notification_config_set(
                 base_url,
                 "task-1",
                 %A2A.Types.PushNotificationConfig{
                   id: "cfg-1",
                   url: "https://callback.example.com",
                   token: "token-1"
                 },
                 transport: transport
               )

      assert {:ok, %A2A.Types.PushNotificationConfig{id: "cfg-1", url: "https://example.com/webhook"}} =
               A2A.Client.push_notification_config_get(base_url, "task-1", "cfg-1",
                 transport: transport
               )

      assert {:ok, [%A2A.Types.PushNotificationConfig{id: "cfg-1"}]} =
               A2A.Client.push_notification_config_list(base_url, "task-1", %{},
                 transport: transport
               )

      assert :ok ==
               A2A.Client.push_notification_config_delete(base_url, "task-1", "cfg-1",
                 transport: transport
               )
    end)
  end

  test "discover verifies signed agent card with verifier" do
    server = A2A.TestHTTPServer.start(SignedAgentCardPlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    parent = self()

    verifier = fn _card, signature ->
      send(parent, {:signature_checked, signature.protected})

      if signature.protected == "valid-protected" do
        :ok
      else
        {:error, :invalid}
      end
    end

    assert {:ok, %A2A.Types.AgentCard{name: "signed-demo"}} =
             A2A.Client.discover(server.base_url,
               verify_signatures: true,
               signature_verifier: verifier
             )

    assert_receive {:signature_checked, "invalid-protected"}
    assert_receive {:signature_checked, "valid-protected"}
  end

  test "discover fails when signature verification fails for all signatures" do
    server = A2A.TestHTTPServer.start(SignedAgentCardFailurePlug)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    verifier = fn _card, _signature -> {:error, :invalid} end

    assert {:error, %A2A.Error{type: :invalid_agent_response, message: message}} =
             A2A.Client.discover(server.base_url,
               verify_signatures: true,
               signature_verifier: verifier
             )

    assert message =~ "signature verification failed"
  end
end
