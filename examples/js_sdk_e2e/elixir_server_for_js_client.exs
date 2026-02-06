Mix.install([
  {:a2a_ex, path: "."},
  {:plug_cowboy, "~> 2.7"}
])

defmodule JSClientE2EStore do
  use Agent

  def start_link(opts \\ []),
    do:
      Agent.start_link(
        fn -> %{tasks: %{}, push: %{}, auth: %{authorized: 0, unauthorized: 0}, push_events: []} end,
        opts
      )

  def put_task(store, %A2A.Types.Task{id: id} = task) do
    Agent.update(store, fn state -> put_in(state, [:tasks, id], task) end)
    task
  end

  def get_task(store, id), do: Agent.get(store, &get_in(&1, [:tasks, id]))
  def list_tasks(store), do: Agent.get(store, &Map.values(&1.tasks))

  def put_push(store, task_id, config), do: Agent.update(store, &put_in(&1, [:push, task_id], config))
  def get_push(store, task_id), do: Agent.get(store, &get_in(&1, [:push, task_id]))
  def del_push(store, task_id), do: Agent.update(store, &update_in(&1.push, fn m -> Map.delete(m, task_id) end))

  def inc_auth(store, key) when key in [:authorized, :unauthorized] do
    Agent.update(store, fn state -> update_in(state, [:auth, key], &(&1 + 1)) end)
  end

  def get_auth(store), do: Agent.get(store, & &1.auth)

  def add_push_event(store, event),
    do: Agent.update(store, &update_in(&1.push_events, fn events -> [event | events] end))

  def list_push_events(store), do: Agent.get(store, &Enum.reverse(&1.push_events))
end

defmodule JSClientE2EExecutor do
  @behaviour A2A.Server.Executor

  def handle_send_message(opts, request, _ctx) do
    store = Map.fetch!(opts, :store)
    text = text_from_parts(request.message.parts)
    task_id = request.message.task_id || "task-" <> Integer.to_string(System.unique_integer([:positive]))
    context_id = request.message.context_id || "ctx-" <> Integer.to_string(System.unique_integer([:positive]))

    message = %A2A.Types.Message{
      kind: "message",
      message_id: "msg-" <> Integer.to_string(System.unique_integer([:positive])),
      role: :agent,
      task_id: task_id,
      context_id: context_id,
      parts: [%A2A.Types.TextPart{text: "elixir-echo:#{text}"}]
    }

    task = %A2A.Types.Task{
      id: task_id,
      context_id: context_id,
      kind: "task",
      history: [request.message],
      status: %A2A.Types.TaskStatus{state: :completed, message: message, timestamp: DateTime.utc_now()}
    }

    JSClientE2EStore.put_task(store, task)
    maybe_deliver_push_notification(store, task_id, task)
    {:ok, message}
  end

  def handle_stream_message(opts, request, _ctx, emit) do
    store = Map.fetch!(opts, :store)
    task_id = request.message.task_id || "task-" <> Integer.to_string(System.unique_integer([:positive]))
    context_id = request.message.context_id || "ctx-" <> Integer.to_string(System.unique_integer([:positive]))

    emit.(%A2A.Types.TaskStatusUpdateEvent{
      task_id: task_id,
      context_id: context_id,
      status: %A2A.Types.TaskStatus{state: :working, timestamp: DateTime.utc_now()},
      final: false
    })

    emit.(%A2A.Types.TaskArtifactUpdateEvent{
      task_id: task_id,
      context_id: context_id,
      artifact: %A2A.Types.Artifact{
        artifact_id: "art-" <> Integer.to_string(System.unique_integer([:positive])),
        name: "stream",
        parts: [%A2A.Types.TextPart{text: "elixir-stream-chunk"}]
      },
      append: false,
      last_chunk: true
    })

    final_task = %A2A.Types.Task{
      id: task_id,
      context_id: context_id,
      kind: "task",
      status: %A2A.Types.TaskStatus{state: :completed, timestamp: DateTime.utc_now()}
    }

    JSClientE2EStore.put_task(store, final_task)

    emit.(%A2A.Types.TaskStatusUpdateEvent{
      task_id: task_id,
      context_id: context_id,
      status: final_task.status,
      final: true
    })

    {:ok, final_task}
  end

  def handle_get_task(opts, task_id, _query, _ctx) do
    store = Map.fetch!(opts, :store)

    case JSClientE2EStore.get_task(store, task_id) do
      nil -> {:error, A2A.Error.new(:task_not_found, "task #{task_id} not found")}
      task -> {:ok, task}
    end
  end

  def handle_list_tasks(opts, _request, _ctx) do
    store = Map.fetch!(opts, :store)
    tasks = JSClientE2EStore.list_tasks(store)
    {:ok, %A2A.Types.ListTasksResponse{tasks: tasks, total_size: length(tasks)}}
  end

  def handle_cancel_task(opts, task_id, _ctx) do
    store = Map.fetch!(opts, :store)

    case JSClientE2EStore.get_task(store, task_id) do
      nil ->
        {:error, A2A.Error.new(:task_not_found, "task #{task_id} not found")}

      %A2A.Types.Task{} = task ->
        canceled = %{task | status: %A2A.Types.TaskStatus{state: :canceled, timestamp: DateTime.utc_now()}}
        JSClientE2EStore.put_task(store, canceled)
        {:ok, canceled}
    end
  end

  def handle_push_notification_config_set(opts, task_id, config, _ctx) do
    store = Map.fetch!(opts, :store)

    case JSClientE2EStore.get_task(store, task_id) do
      nil -> {:error, A2A.Error.new(:task_not_found, "task #{task_id} not found")}
      _task ->
        JSClientE2EStore.put_push(store, task_id, config)
        {:ok, config}
    end
  end

  def handle_push_notification_config_get(opts, task_id, _config_id, _ctx) do
    store = Map.fetch!(opts, :store)

    case JSClientE2EStore.get_push(store, task_id) do
      nil -> {:error, A2A.Error.new(:task_not_found, "push config not found")}
      cfg -> {:ok, cfg}
    end
  end

  def handle_push_notification_config_list(opts, task_id, _query, _ctx) do
    store = Map.fetch!(opts, :store)

    case JSClientE2EStore.get_push(store, task_id) do
      nil -> {:ok, []}
      cfg -> {:ok, [cfg]}
    end
  end

  def handle_push_notification_config_delete(opts, task_id, _config_id, _ctx) do
    store = Map.fetch!(opts, :store)
    JSClientE2EStore.del_push(store, task_id)
    :ok
  end

  defp maybe_deliver_push_notification(store, task_id, %A2A.Types.Task{} = task) do
    case JSClientE2EStore.get_push(store, task_id) do
      %A2A.Types.PushNotificationConfig{url: url} = cfg when is_binary(url) and url != "" ->
        headers =
          [{"content-type", "application/json"}] ++
            if is_binary(cfg.token) and cfg.token != "",
              do: [{"x-a2a-notification-token", cfg.token}],
              else: []

        payload = A2A.Types.Task.to_map(task, version: :v0_3)

        _ = Req.post(url: url, headers: headers, body: Jason.encode!(payload))
        :ok

      _ ->
        :ok
    end
  end

  defp text_from_parts([%A2A.Types.TextPart{text: text} | _]), do: text
  defp text_from_parts([%{text: text} | _]), do: text
  defp text_from_parts(_), do: ""
end

defmodule JSClientE2ERootPlug do
  use Plug.Builder
  import Plug.Conn

  @host System.get_env("A2A_E2E_ELIXIR_SERVER_HOST", "127.0.0.1")
  @port String.to_integer(System.get_env("A2A_E2E_ELIXIR_SERVER_PORT", "4311"))
  @auth_token System.get_env("A2A_E2E_AUTH_TOKEN", "retry-token")

  @rest_opts A2A.Server.REST.Plug.init(
               executor: {JSClientE2EExecutor, %{store: JSClientE2EStore}},
               version: :v0_3,
               wire_format: :proto_json,
               capabilities: %{streaming: true, push_notifications: true}
             )
  @rpc_opts A2A.Server.JSONRPC.Plug.init(
              executor: {JSClientE2EExecutor, %{store: JSClientE2EStore}},
              version: :v0_3,
              capabilities: %{streaming: true, push_notifications: true}
            )

  plug :route_aux_endpoints
  plug :auth_guard
  plug :dispatch_transport

  def route_aux_endpoints(conn, _opts) do
    case {conn.method, conn.path_info} do
      {"GET", ["health"]} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{ok: true}))
        |> halt()

      {"GET", ["auth-attempts"]} ->
        attempts = JSClientE2EStore.get_auth(JSClientE2EStore)
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(attempts))
        |> halt()

      {"POST", ["push-receiver"]} ->
        {:ok, body, conn} = read_body(conn)

        decoded_body =
          case Jason.decode(body) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        JSClientE2EStore.add_push_event(JSClientE2EStore, %{
          "headers" => %{
            "x-a2a-notification-token" => get_req_header(conn, "x-a2a-notification-token") |> List.first()
          },
          "body" => decoded_body,
          "receivedAt" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

        conn
        |> send_resp(204, "")
        |> halt()

      {"GET", ["push-events"]} ->
        events = JSClientE2EStore.list_push_events(JSClientE2EStore)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"events" => events}))
        |> halt()

      {"GET", [".well-known", "agent-card.json"]} ->
        card =
          A2A.Types.AgentCard.from_map(%{
            "name" => "A2A_EX Elixir Server",
            "description" => "E2E server fixture for JS client",
            "protocolVersion" => "0.3.0",
            "version" => "0.1.0",
            "url" => "http://#{@host}:#{@port}/",
            "preferredTransport" => "JSONRPC",
            "skills" => [
              %{"id" => "chat", "name" => "Chat", "description" => "Echo + stream"}
            ],
            "capabilities" => %{
              "streaming" => true,
              "pushNotifications" => true
            },
            "defaultInputModes" => ["text"],
            "defaultOutputModes" => ["text"],
            "additionalInterfaces" => [
              %{"url" => "http://#{@host}:#{@port}/", "transport" => "JSONRPC"},
              %{"url" => "http://#{@host}:#{@port}", "transport" => "HTTP+JSON"}
            ]
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(A2A.Types.AgentCard.to_map(card, version: :v0_3)))
        |> halt()

      _ ->
        conn
    end
  end

  def auth_guard(%Plug.Conn{halted: true} = conn, _opts), do: conn

  def auth_guard(conn, _opts) do
    auth = get_req_header(conn, "authorization") |> List.first()

    if auth == "Bearer #{@auth_token}" do
      JSClientE2EStore.inc_auth(JSClientE2EStore, :authorized)
      conn
    else
      JSClientE2EStore.inc_auth(JSClientE2EStore, :unauthorized)

      conn
      |> put_resp_header("www-authenticate", ~s(Bearer realm="a2a", error="invalid_token"))
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{"error" => "Unauthorized"}))
      |> halt()
    end
  end

  def dispatch_transport(%Plug.Conn{halted: true} = conn, _opts), do: conn

  def dispatch_transport(conn, _opts) do
    if conn.request_path == "/" do
      A2A.Server.JSONRPC.Plug.call(conn, @rpc_opts)
    else
      A2A.Server.REST.Plug.call(conn, @rest_opts)
    end
  end
end

{:ok, _} = JSClientE2EStore.start_link(name: JSClientE2EStore)
host = System.get_env("A2A_E2E_ELIXIR_SERVER_HOST", "127.0.0.1")
port = String.to_integer(System.get_env("A2A_E2E_ELIXIR_SERVER_PORT", "4311"))

{:ok, _pid} = Plug.Cowboy.http(JSClientE2ERootPlug, [], ip: {127, 0, 0, 1}, port: port)
IO.puts("E2E_ELIXIR_SERVER_READY http://#{host}:#{port}")
Process.sleep(:infinity)
