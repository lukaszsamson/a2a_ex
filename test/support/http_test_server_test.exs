defmodule A2A.TestHTTPServer do
  @moduledoc false

  def start(plug, opts \\ []) do
    ref = Keyword.get(opts, :ref, unique_ref())
    plug_opts = Keyword.get(opts, :plug_opts, [])
    {:ok, _pid} = Plug.Cowboy.http(plug, plug_opts, port: 0, ref: ref)
    port = :ranch.get_port(ref)
    %{base_url: "http://localhost:#{port}", ref: ref}
  end

  def stop(ref) do
    Plug.Cowboy.shutdown(ref)
  end

  defp unique_ref do
    ("a2a_test_" <> Integer.to_string(System.unique_integer([:positive]))) |> String.to_atom()
  end
end

defmodule A2A.TestServerHelpers do
  @moduledoc false

  def send_json(conn, body, status \\ 200) do
    Plug.Conn.send_resp(conn, status, Jason.encode!(body))
  end

  def sse_event(payload) do
    "data: " <> Jason.encode!(payload) <> "\n\n"
  end
end

defmodule A2A.TestRESTSuccessPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    import A2A.TestServerHelpers

    case {conn.method, conn.request_path} do
      {"POST", "/v1/message:send"} ->
        send_json(conn, %{
          "task" => %{
            "id" => "task-1",
            "contextId" => "ctx-1",
            "status" => %{"state" => "submitted"}
          }
        })

      {"POST", "/v1/message:stream"} ->
        body =
          [
            %{
              "task" => %{
                "id" => "task-1",
                "contextId" => "ctx-1",
                "status" => %{"state" => "submitted"}
              }
            },
            %{
              "statusUpdate" => %{
                "taskId" => "task-1",
                "contextId" => "ctx-1",
                "status" => %{"state" => "working"},
                "final" => false
              }
            }
          ]
          |> Enum.map(&sse_event/1)
          |> Enum.join()

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)

      {"GET", "/v1/tasks"} ->
        send_json(conn, %{"tasks" => [], "nextPageToken" => nil})

      {"GET", path} ->
        handle_task_read(conn, path)

      {"POST", path} ->
        handle_task_write(conn, path)

      _ ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp handle_task_read(conn, path) do
    if String.starts_with?(path, "/v1/tasks/") do
      id = String.replace_prefix(path, "/v1/tasks/", "")

      A2A.TestServerHelpers.send_json(conn, %{
        "id" => id,
        "contextId" => "ctx-1",
        "status" => %{"state" => "completed"}
      })
    else
      Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp handle_task_write(conn, path) do
    if String.starts_with?(path, "/v1/tasks/") do
      id = String.replace_prefix(path, "/v1/tasks/", "")
      task_id = String.trim_trailing(id, ":cancel")

      A2A.TestServerHelpers.send_json(conn, %{
        "id" => task_id,
        "contextId" => "ctx-1",
        "status" => %{"state" => "canceled"}
      })
    else
      Plug.Conn.send_resp(conn, 404, "")
    end
  end
end

defmodule A2A.TestRESTErrorPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    import A2A.TestServerHelpers

    case {conn.method, conn.request_path} do
      {"POST", "/v1/message:send"} ->
        Plug.Conn.send_resp(conn, 200, "not-json")

      {"GET", "/v1/tasks"} ->
        send_json(
          conn,
          %{"error" => %{"type" => "TaskNotFoundError", "message" => "missing"}},
          500
        )

      _ ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end
end

defmodule A2A.TestRESTReconnectPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    import A2A.TestServerHelpers

    case {conn.method, conn.request_path} do
      {"POST", "/v1/message:stream"} ->
        last_event_id = List.first(Plug.Conn.get_req_header(conn, "last-event-id"))

        payloads =
          case last_event_id do
            nil ->
              [
                %{"id" => "1", "task" => %{"id" => "task-1", "contextId" => "ctx-1"}},
                %{
                  "id" => "2",
                  "statusUpdate" => %{
                    "taskId" => "task-1",
                    "contextId" => "ctx-1",
                    "status" => %{"state" => "working"}
                  }
                }
              ]

            "2" ->
              [
                %{
                  "id" => "3",
                  "statusUpdate" => %{
                    "taskId" => "task-1",
                    "contextId" => "ctx-1",
                    "status" => %{"state" => "completed"}
                  }
                }
              ]

            _ ->
              []
          end

        body =
          payloads
          |> Enum.map(fn payload ->
            event_id = Map.get(payload, "id")
            "id: #{event_id}\n" <> sse_event(Map.delete(payload, "id"))
          end)
          |> Enum.join()

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)

      _ ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end
end

defmodule A2A.TestRESTStreamErrorPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    import A2A.TestServerHelpers

    case {conn.method, conn.request_path} do
      {"POST", "/v1/message:stream"} ->
        body = sse_event(%{"error" => %{"type" => "TaskNotFoundError", "message" => "missing"}})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)

      _ ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end
end

defmodule A2A.TestJSONRPCSuccessPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    import A2A.TestServerHelpers
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    payload = Jason.decode!(body)
    method = payload["method"]
    id = payload["id"]

    case method do
      "message/send" ->
        send_json(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "task" => %{
              "id" => "task-1",
              "contextId" => "ctx-1",
              "status" => %{"state" => "submitted"}
            }
          }
        })

      "message/stream" ->
        event = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "task" => %{
              "id" => "task-1",
              "contextId" => "ctx-1",
              "status" => %{"state" => "submitted"}
            }
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "data: " <> Jason.encode!(event) <> "\n\n")

      "tasks/list" ->
        send_json(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"tasks" => []}
        })

      _ ->
        send_json(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32601, "message" => "Method not found"}
        })
    end
  end
end

defmodule A2A.TestJSONRPCErrorPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    import A2A.TestServerHelpers
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    payload = Jason.decode!(body)
    method = payload["method"]
    id = payload["id"]

    case method do
      "message/send" ->
        send_json(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"type" => "TaskNotFoundError", "message" => "missing"}
        })

      "tasks/list" ->
        Plug.Conn.send_resp(conn, 200, "not-json")

      _ ->
        send_json(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32601, "message" => "Method not found"}
        })
    end
  end
end

defmodule A2A.TestJSONRPCReconnectPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    import A2A.TestServerHelpers
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    payload = Jason.decode!(body)
    method = payload["method"]
    id = payload["id"]

    case method do
      "message/stream" ->
        send_stream(conn, id)

      _ ->
        send_json(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32601, "message" => "Method not found"}
        })
    end
  end

  defp send_stream(conn, id) do
    last_event_id = List.first(Plug.Conn.get_req_header(conn, "last-event-id"))

    payloads =
      case last_event_id do
        nil ->
          [
            %{"id" => "1", "result" => %{"task" => %{"id" => "task-1"}}},
            %{"id" => "2", "result" => %{"statusUpdate" => %{"taskId" => "task-1"}}}
          ]

        "2" ->
          [
            %{"id" => "3", "result" => %{"statusUpdate" => %{"taskId" => "task-1"}}}
          ]

        _ ->
          []
      end

    body =
      payloads
      |> Enum.map(fn payload ->
        event_id = Map.get(payload, "id")
        payload = payload |> Map.put("jsonrpc", "2.0") |> Map.put("id", id)
        "id: #{event_id}\n" <> A2A.TestServerHelpers.sse_event(payload)
      end)
      |> Enum.join()

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, body)
  end
end

defmodule A2A.TestJSONRPCStreamErrorPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    import A2A.TestServerHelpers
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    payload = Jason.decode!(body)
    method = payload["method"]
    id = payload["id"]

    case method do
      "message/stream" ->
        event = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32601, "message" => "Method not found"}
        }

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_event(event))

      _ ->
        send_json(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32601, "message" => "Method not found"}
        })
    end
  end
end

defmodule A2A.TestAgentCardPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    import A2A.TestServerHelpers

    case conn.request_path do
      "/.well-known/agent-card.json" ->
        send_json(conn, %{
          "name" => "demo",
          "url" => "https://agent.example.com",
          "capabilities" => %{"streaming" => true}
        })

      _ ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end
end

defmodule A2A.TestInvalidAgentCardPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    import A2A.TestServerHelpers

    case conn.request_path do
      "/.well-known/agent-card.json" ->
        send_json(conn, %{
          "url" => "https://agent.example.com",
          "capabilities" => %{}
        })

      _ ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end
end

defmodule A2A.TestLatestAgentCardPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    import A2A.TestServerHelpers

    case conn.request_path do
      "/.well-known/agent-card.json" ->
        send_json(conn, %{
          "name" => "latest-demo",
          "capabilities" => %{"streaming" => true},
          "supportedInterfaces" => [
            %{
              "protocolBinding" => "JSONRPC",
              "url" => "https://rpc.example.com"
            }
          ]
        })

      _ ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end
end

defmodule A2A.TestInvalidLatestAgentCardPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    import A2A.TestServerHelpers

    case conn.request_path do
      "/.well-known/agent-card.json" ->
        send_json(conn, %{
          "name" => "latest-demo",
          "capabilities" => %{"streaming" => true},
          "supportedInterfaces" => [%{"protocolBinding" => "JSONRPC"}]
        })

      _ ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end
end

defmodule A2A.TestRESTStreamHandshakeErrorPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    case {conn.method, conn.request_path} do
      {"POST", "/v1/message:stream"} ->
        Plug.Conn.send_resp(conn, 400, "bad")

      _ ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end
end

defmodule A2A.TestJSONRPCStreamHandshakeErrorPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, _body, conn} = Plug.Conn.read_body(conn)
    Plug.Conn.send_resp(conn, 400, "bad")
  end
end

defmodule A2A.TestRESTSubscribeGetPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, opts) do
    case {conn.method, conn.request_path} do
      {"GET", "/v1/tasks/task-1:subscribe"} ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        parent = Keyword.get(opts, :parent, self())
        send(parent, {:subscribe_request, %{method: :get, body: body}})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "")

      _ ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => "not_found"}))
    end
  end
end

defmodule A2A.TestRESTResubscribePlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, opts) do
    case {conn.method, conn.request_path} do
      {"GET", "/v1/tasks/task-1:subscribe"} ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        last_event_id = List.first(Plug.Conn.get_req_header(conn, "last-event-id"))
        parent = Keyword.get(opts, :parent, self())

        send(parent, %{
          method: :get,
          body: body,
          last_event_id: last_event_id
        })

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "")

      {"POST", "/v1/tasks/task-1:subscribe"} ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        last_event_id = List.first(Plug.Conn.get_req_header(conn, "last-event-id"))
        parent = Keyword.get(opts, :parent, self())

        send(parent, %{
          method: :post,
          body: body,
          last_event_id: last_event_id
        })

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "")

      _ ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => "not_found"}))
    end
  end
end
