defmodule A2A.TransportAuthRetryTest do
  use ExUnit.Case, async: false

  defmodule ChallengeAuth do
    def headers(_opts), do: []

    def on_auth_challenge(challenge, _opts) do
      if challenge == "Bearer realm=\"a2a\", error=\"invalid_token\"" do
        [{"authorization", "Bearer retry-token"}]
      else
        []
      end
    end
  end

  defmodule RESTChallengePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      parent = Keyword.fetch!(opts, :parent)
      auth = get_req_header(conn, "authorization") |> List.first()
      send(parent, {:rest_auth_attempt, auth})

      if auth == "Bearer retry-token" do
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "task" => %{
              "id" => "task-1",
              "contextId" => "ctx-1",
              "status" => %{"state" => "submitted"}
            }
          })
        )
      else
        conn
        |> put_resp_header("www-authenticate", "Bearer realm=\"a2a\", error=\"invalid_token\"")
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => %{"type" => "UnauthorizedError"}}))
      end
    end
  end

  defmodule JSONRPCChallengePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      parent = Keyword.fetch!(opts, :parent)
      auth = get_req_header(conn, "authorization") |> List.first()
      send(parent, {:jsonrpc_auth_attempt, auth})

      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)

      if auth == "Bearer retry-token" do
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "task" => %{
                "id" => "task-1",
                "contextId" => "ctx-1",
                "status" => %{"state" => "submitted"}
              }
            }
          })
        )
      else
        conn
        |> put_resp_header("www-authenticate", "Bearer realm=\"a2a\", error=\"invalid_token\"")
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "error" => %{"code" => -32001, "message" => "Unauthorized"}
          })
        )
      end
    end
  end

  defmodule JSONRPCStreamChallengePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      parent = Keyword.fetch!(opts, :parent)
      auth = get_req_header(conn, "authorization") |> List.first()
      send(parent, {:jsonrpc_stream_auth_attempt, auth})

      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)

      if auth == "Bearer retry-token" do
        event = %{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "result" => %{
            "task" => %{
              "id" => "task-1",
              "contextId" => "ctx-1",
              "status" => %{"state" => "submitted"}
            }
          }
        }

        conn
        |> put_resp_content_type("text/event-stream")
        |> send_resp(200, "data: " <> Jason.encode!(event) <> "\n\n")
      else
        conn
        |> put_resp_header("www-authenticate", "Bearer realm=\"a2a\", error=\"invalid_token\"")
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
      end
    end
  end

  test "REST retries once after 401 challenge when auth handler provides headers" do
    server = A2A.TestHTTPServer.start(RESTChallengePlug, plug_opts: [parent: self()])
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.REST,
        auth: {ChallengeAuth, []}
      )

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    assert {:ok, %A2A.Types.Task{id: "task-1"}} = A2A.Transport.REST.send_message(config, request)

    assert_receive {:rest_auth_attempt, nil}
    assert_receive {:rest_auth_attempt, "Bearer retry-token"}
  end

  test "JSON-RPC retries once after 401 challenge when auth handler provides headers" do
    server = A2A.TestHTTPServer.start(JSONRPCChallengePlug, plug_opts: [parent: self()])
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.JSONRPC,
        auth: {ChallengeAuth, []}
      )

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    assert {:ok, %A2A.Types.Task{id: "task-1"}} =
             A2A.Transport.JSONRPC.send_message(config, request)

    assert_receive {:jsonrpc_auth_attempt, nil}
    assert_receive {:jsonrpc_auth_attempt, "Bearer retry-token"}
  end

  test "JSON-RPC stream retries once after 401 challenge when auth handler provides headers" do
    server = A2A.TestHTTPServer.start(JSONRPCStreamChallengePlug, plug_opts: [parent: self()])
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)

    config =
      A2A.Client.Config.new(server.base_url,
        transport: A2A.Transport.JSONRPC,
        auth: {ChallengeAuth, []}
      )

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    assert {:ok, stream} = A2A.Transport.JSONRPC.stream_message(config, request)
    assert [%A2A.Types.StreamResponse{task: %A2A.Types.Task{id: "task-1"}}] = Enum.take(stream, 1)

    assert_receive {:jsonrpc_stream_auth_attempt, nil}
    assert_receive {:jsonrpc_stream_auth_attempt, "Bearer retry-token"}
  end
end
