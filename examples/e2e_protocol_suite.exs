# A2A protocol E2E suite over real HTTP transports (REST + JSON-RPC)
#
# Run:
#   elixir examples/e2e_protocol_suite.exs
#
# Optional env overrides:
#   A2A_E2E_REST_PORT=4100
#   A2A_E2E_JSONRPC_PORT=4101
#   A2A_E2E_JSONRPC_EXT_PORT=4102
#   A2A_E2E_NOTIFY_PORT=4200

Mix.install([
  {:a2a_ex, path: "."},
  {:plug_cowboy, "~> 2.7"}
])

defmodule E2E.Suite do
  defmodule Store do
    use Agent

    def start_link(opts \\ []) do
      Agent.start_link(fn -> %{tasks: %{}, push_configs: %{}} end, opts)
    end

    def put_task(store, %A2A.Types.Task{id: task_id} = task) do
      Agent.update(store, fn state -> put_in(state, [:tasks, task_id], task) end)
      task
    end

    def get_task(store, task_id), do: Agent.get(store, &get_in(&1, [:tasks, task_id]))
    def list_tasks(store), do: Agent.get(store, &Map.values(&1.tasks))

    def put_push_config(store, task_id, %A2A.Types.PushNotificationConfig{} = config) do
      Agent.update(store, fn state -> put_in(state, [:push_configs, task_id], config) end)
      config
    end

    def get_push_config(store, task_id), do: Agent.get(store, &get_in(&1, [:push_configs, task_id]))
    def delete_push_config(store, task_id), do: Agent.update(store, &update_in(&1.push_configs, fn m -> Map.delete(m, task_id) end))
  end

  defmodule NotifyStore do
    use Agent

    def start_link(opts \\ []) do
      Agent.start_link(fn -> %{} end, opts)
    end

    def put(store, task_id, payload) do
      Agent.update(store, fn state ->
        Map.update(state, task_id, [payload], fn existing -> existing ++ [payload] end)
      end)
    end

    def get(store, task_id), do: Agent.get(store, &Map.get(&1, task_id, []))
  end

  defmodule NotifyPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      store = Keyword.fetch!(opts, :store)

      case {conn.method, conn.path_info} do
        {"POST", ["notifications"]} ->
          {:ok, body, conn} = read_body(conn)
          token = get_req_header(conn, "x-a2a-notification-token") |> List.first()
          payload = Jason.decode!(body)
          task_id = payload["id"] || get_in(payload, ["task", "id"]) || "unknown"
          NotifyStore.put(store, task_id, %{"token" => token, "payload" => payload})
          send_json(conn, 200, %{"status" => "ok"})

        {"GET", ["tasks", task_id, "notifications"]} ->
          send_json(conn, 200, %{"notifications" => NotifyStore.get(store, task_id)})

        {"GET", ["health"]} ->
          send_json(conn, 200, %{"ok" => true})

        _ ->
          send_resp(conn, 404, "")
      end
    end

    defp send_json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  defmodule Executor do
    def handle_send_message(opts, request, _ctx) do
      store = Map.fetch!(opts, :store)
      text = extract_text(request.message)

      task_id = request.message.task_id || "task-" <> Integer.to_string(System.unique_integer([:positive]))
      context_id = request.message.context_id || "ctx-" <> Integer.to_string(System.unique_integer([:positive]))

      maybe_store_request_push_config(store, task_id, request.configuration)

      state =
        case text do
          "pending" -> :submitted
          _ -> :completed
        end

      task = %A2A.Types.Task{
        id: task_id,
        context_id: context_id,
        kind: "task",
        status: %A2A.Types.TaskStatus{state: state, timestamp: DateTime.utc_now()}
      }

      Store.put_task(store, task)
      maybe_deliver_push(store, task)
      {:ok, task}
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
        append: false,
        last_chunk: true,
        artifact: %A2A.Types.Artifact{
          artifact_id: "art-" <> Integer.to_string(System.unique_integer([:positive])),
          name: "response",
          parts: [%A2A.Types.TextPart{text: "stream-chunk"}]
        }
      })

      task = %A2A.Types.Task{
        id: task_id,
        context_id: context_id,
        kind: "task",
        status: %A2A.Types.TaskStatus{state: :completed, timestamp: DateTime.utc_now()}
      }

      Store.put_task(store, task)
      emit.(%A2A.Types.TaskStatusUpdateEvent{
        task_id: task_id,
        context_id: context_id,
        status: task.status,
        final: true
      })

      maybe_deliver_push(store, task)
      {:ok, task}
    end

    def handle_get_task(opts, task_id, _query, _ctx) do
      store = Map.fetch!(opts, :store)

      case Store.get_task(store, task_id) do
        nil -> {:error, A2A.Error.new(:task_not_found, "Task #{task_id} not found")}
        task -> {:ok, task}
      end
    end

    def handle_list_tasks(opts, _request, _ctx) do
      store = Map.fetch!(opts, :store)
      tasks = Store.list_tasks(store)
      {:ok, %A2A.Types.ListTasksResponse{tasks: tasks, total_size: length(tasks)}}
    end

    def handle_cancel_task(opts, task_id, _ctx) do
      store = Map.fetch!(opts, :store)

      case Store.get_task(store, task_id) do
        nil ->
          {:error, A2A.Error.new(:task_not_found, "Task #{task_id} not found")}

        %A2A.Types.Task{status: %A2A.Types.TaskStatus{state: state}} = _task
        when state in [:completed, :canceled, :failed, :rejected] ->
          {:error, A2A.Error.new(:unsupported_operation, "Task is terminal")}

        %A2A.Types.Task{} = task ->
          updated = %{task | status: %A2A.Types.TaskStatus{state: :canceled, timestamp: DateTime.utc_now()}}
          Store.put_task(store, updated)
          {:ok, updated}
      end
    end

    def handle_push_notification_config_set(opts, task_id, config, _ctx) do
      store = Map.fetch!(opts, :store)
      {:ok, Store.put_push_config(store, task_id, config)}
    end

    def handle_push_notification_config_get(opts, task_id, _config_id, _ctx) do
      store = Map.fetch!(opts, :store)

      case Store.get_push_config(store, task_id) do
        nil -> {:error, A2A.Error.new(:task_not_found, "Push config not found")}
        config -> {:ok, config}
      end
    end

    def handle_push_notification_config_list(opts, task_id, _query, _ctx) do
      store = Map.fetch!(opts, :store)

      case Store.get_push_config(store, task_id) do
        nil -> {:ok, []}
        config -> {:ok, [config]}
      end
    end

    def handle_push_notification_config_delete(opts, task_id, _config_id, _ctx) do
      store = Map.fetch!(opts, :store)
      Store.delete_push_config(store, task_id)
      :ok
    end

    defp maybe_store_request_push_config(_store, _task_id, nil), do: :ok

    defp maybe_store_request_push_config(store, task_id, %A2A.Types.SendMessageConfiguration{} = config) do
      case config.push_notification_config do
        %A2A.Types.PushNotificationConfig{} = push_cfg -> Store.put_push_config(store, task_id, push_cfg)
        _ -> :ok
      end
    end

    defp maybe_deliver_push(store, %A2A.Types.Task{} = task) do
      case Store.get_push_config(store, task.id) do
        nil ->
          :ok

        %A2A.Types.PushNotificationConfig{} = config ->
          _ = A2A.Server.Push.deliver(config, task, allow_http: true)
          :ok
      end
    end

    defp extract_text(%A2A.Types.Message{parts: [%A2A.Types.TextPart{text: text} | _]}), do: text
    defp extract_text(%A2A.Types.Message{parts: [%{text: text} | _]}), do: text
    defp extract_text(_), do: ""
  end

  defmodule RestServerPlug do
    use Plug.Builder

    plug A2A.Server.AgentCardPlug, card_fun: &__MODULE__.agent_card/0

    plug A2A.Server.REST.Plug,
      executor: {E2E.Suite.Executor, %{store: E2E.RestStore}},
      capabilities: %{streaming: true, push_notifications: true}

    def agent_card do
      A2A.Types.AgentCard.from_map(%{
        "name" => "A2A E2E REST Agent",
        "description" => "REST transport E2E coverage",
        "version" => "1.0.0",
        "url" => "http://localhost:#{E2E.Suite.rest_port()}",
        "preferredTransport" => "HTTP+JSON",
        "capabilities" => %{"streaming" => true, "pushNotifications" => true},
        "defaultInputModes" => ["text"],
        "defaultOutputModes" => ["text"]
      })
    end
  end

  defmodule JsonRpcServerPlug do
    use Plug.Builder

    plug A2A.Server.AgentCardPlug, card_fun: &__MODULE__.agent_card/0

    plug A2A.Server.JSONRPC.Plug,
      executor: {E2E.Suite.Executor, %{store: E2E.JsonRpcStore}},
      capabilities: %{streaming: true, push_notifications: true}

    def agent_card do
      A2A.Types.AgentCard.from_map(%{
        "name" => "A2A E2E JSON-RPC Agent",
        "description" => "JSON-RPC transport E2E coverage",
        "version" => "1.0.0",
        "url" => "http://localhost:#{E2E.Suite.jsonrpc_port()}",
        "preferredTransport" => "JSONRPC",
        "capabilities" => %{"streaming" => true, "pushNotifications" => true},
        "defaultInputModes" => ["text"],
        "defaultOutputModes" => ["text"]
      })
    end
  end

  defmodule JsonRpcRequiredExtPlug do
    use Plug.Builder

    plug A2A.Server.JSONRPC.Plug,
      executor: {E2E.Suite.Executor, %{store: E2E.JsonRpcExtStore}},
      required_extensions: ["urn:required"],
      capabilities: %{streaming: false}
  end

  def run do
    ensure_started!()

    IO.puts("Running A2A E2E protocol checks...")

    check_discovery()
    check_rest_flow()
    check_jsonrpc_flow()
    check_push_lifecycle()
    check_required_extensions_jsonrpc()

    IO.puts("E2E suite passed.")
  after
    stop_servers()
  end

  def rest_port, do: env_int("A2A_E2E_REST_PORT", 4100)
  def jsonrpc_port, do: env_int("A2A_E2E_JSONRPC_PORT", 4101)
  def jsonrpc_ext_port, do: env_int("A2A_E2E_JSONRPC_EXT_PORT", 4102)
  def notify_port, do: env_int("A2A_E2E_NOTIFY_PORT", 4200)

  defp ensure_started! do
    {:ok, _} = Store.start_link(name: E2E.RestStore)
    {:ok, _} = Store.start_link(name: E2E.JsonRpcStore)
    {:ok, _} = Store.start_link(name: E2E.JsonRpcExtStore)
    {:ok, _} = NotifyStore.start_link(name: E2E.NotifyStore)

    start_server!(:notify, NotifyPlug, notify_port(), store: E2E.NotifyStore)
    start_server!(:rest, RestServerPlug, rest_port())
    start_server!(:jsonrpc, JsonRpcServerPlug, jsonrpc_port())
    start_server!(:jsonrpc_ext, JsonRpcRequiredExtPlug, jsonrpc_ext_port())
  end

  defp start_server!(key, plug, port, plug_opts \\ []) do
    ref = :"e2e_#{key}_#{port}"
    {:ok, _pid} = Plug.Cowboy.http(plug, plug_opts, port: port, ref: ref)
    Process.put({:server_ref, key}, ref)
  end

  defp stop_servers do
    [:jsonrpc_ext, :jsonrpc, :rest, :notify]
    |> Enum.each(fn key ->
      case Process.get({:server_ref, key}) do
        nil -> :ok
        ref -> Plug.Cowboy.shutdown(ref)
      end
    end)
  end

  defp check_discovery do
    rest_url = "http://localhost:#{rest_port()}"
    jsonrpc_url = "http://localhost:#{jsonrpc_port()}"

    {:ok, rest_card} =
      case A2A.Client.discover(rest_url) do
        {:ok, card} -> {:ok, card}
        other -> raise "REST discover failed: #{inspect(other)}"
      end

    assert(rest_card.capabilities.streaming == true, "REST card should advertise streaming")

    {:ok, rpc_card} =
      case A2A.Client.discover(jsonrpc_url, transport: A2A.Transport.JSONRPC) do
        {:ok, card} -> {:ok, card}
        other -> raise "JSON-RPC discover failed: #{inspect(other)}"
      end

    assert(rpc_card.preferred_transport in ["JSONRPC", nil], "JSON-RPC card transport mismatch")
  end

  defp check_rest_flow do
    base_url = "http://localhost:#{rest_port()}"

    msg = user_message("rest-sync")
    task_id =
      case A2A.Client.send_message(base_url, message: msg) do
        {:ok, %A2A.Types.Task{id: id}} -> id
        other -> raise "REST send_message failed: #{inspect(other)}"
      end

    case A2A.Client.get_task(base_url, task_id) do
      {:ok, %A2A.Types.Task{id: ^task_id}} -> :ok
      other -> raise "REST get_task failed: #{inspect(other)}"
    end

    tasks =
      case A2A.Client.list_tasks(base_url, %{}) do
        {:ok, %A2A.Types.ListTasksResponse{tasks: listed}} -> listed
        other -> raise "REST list_tasks failed: #{inspect(other)}"
      end

    assert(Enum.any?(tasks, &(&1.id == task_id)), "REST list_tasks should include created task")

    stream_msg = user_message("rest-stream")
    stream =
      case A2A.Client.stream_message(base_url, message: stream_msg) do
        {:ok, s} -> s
        other -> raise "REST stream_message failed: #{inspect(other)}"
      end

    events = Enum.take(stream, 10)
    assert(events != [], "REST stream should yield events")
    assert(Enum.any?(events, &match?(%{status_update: %A2A.Types.TaskStatusUpdateEvent{}}, &1)), "REST stream missing status update")

    pending_msg = user_message("pending")
    pending_task_id =
      case A2A.Client.send_message(base_url, message: pending_msg) do
        {:ok, %A2A.Types.Task{id: id}} -> id
        other -> raise "REST pending message failed: #{inspect(other)}"
      end

    case A2A.Client.cancel_task(base_url, pending_task_id) do
      {:ok, %A2A.Types.Task{id: ^pending_task_id, status: %A2A.Types.TaskStatus{state: :canceled}}} ->
        :ok

      other ->
        raise "REST cancel_task failed: #{inspect(other)}"
    end
  end

  defp check_jsonrpc_flow do
    base_url = "http://localhost:#{jsonrpc_port()}"

    msg = user_message("jsonrpc-sync")
    result =
      case A2A.Client.send_message(base_url, [message: msg], transport: A2A.Transport.JSONRPC) do
        {:ok, r} -> r
        other -> raise "JSON-RPC send_message failed: #{inspect(other)}"
      end

    task_id = result && result.id
    assert(is_binary(task_id), "JSON-RPC send_message should return task id")

    case A2A.Client.get_task(base_url, task_id, transport: A2A.Transport.JSONRPC) do
      {:ok, %A2A.Types.Task{id: ^task_id}} -> :ok
      other -> raise "JSON-RPC get_task failed: #{inspect(other)}"
    end

    case A2A.Client.list_tasks(base_url, %{}, transport: A2A.Transport.JSONRPC) do
      {:ok, %A2A.Types.ListTasksResponse{}} -> :ok
      other -> raise "JSON-RPC list_tasks failed: #{inspect(other)}"
    end

    stream_msg = user_message("jsonrpc-stream")
    stream =
      case A2A.Client.stream_message(base_url, [message: stream_msg], transport: A2A.Transport.JSONRPC) do
        {:ok, s} -> s
        other -> raise "JSON-RPC stream_message failed: #{inspect(other)}"
      end

    events = Enum.take(stream, 10)
    assert(events != [], "JSON-RPC stream should yield events")
  end

  defp check_push_lifecycle do
    base_url = "http://localhost:#{rest_port()}"
    notify_url = "http://localhost:#{notify_port()}/notifications"
    token = "token-" <> Integer.to_string(System.unique_integer([:positive]))
    config_id = "cfg-" <> Integer.to_string(System.unique_integer([:positive]))

    task_id =
      case A2A.Client.send_message(base_url, message: user_message("pending")) do
        {:ok, %A2A.Types.Task{id: id}} -> id
        other -> raise "REST push setup message failed: #{inspect(other)}"
      end

    config = %A2A.Types.PushNotificationConfig{id: config_id, url: notify_url, token: token}

    case A2A.Client.push_notification_config_set(base_url, task_id, config) do
      {:ok, %A2A.Types.PushNotificationConfig{id: ^config_id}} -> :ok
      other -> raise "push config set failed: #{inspect(other)}"
    end

    case A2A.Client.push_notification_config_get(base_url, task_id, config_id) do
      {:ok, %A2A.Types.PushNotificationConfig{id: ^config_id}} -> :ok
      other -> raise "push config get failed: #{inspect(other)}"
    end

    case A2A.Client.push_notification_config_list(base_url, task_id) do
      {:ok, [%A2A.Types.PushNotificationConfig{id: ^config_id}]} -> :ok
      other -> raise "push config list failed: #{inspect(other)}"
    end

    followup = %A2A.Types.Message{
      task_id: task_id,
      message_id: "complete-" <> Integer.to_string(System.unique_integer([:positive])),
      role: :user,
      parts: [%A2A.Types.TextPart{text: "complete-now"}]
    }

    case A2A.Client.send_message(base_url, message: followup) do
      {:ok, %A2A.Types.Task{id: ^task_id, status: %A2A.Types.TaskStatus{state: :completed}}} -> :ok
      other -> raise "REST follow-up send failed: #{inspect(other)}"
    end

    [notification] = wait_notifications(task_id, 1)
    assert(notification["token"] == token, "notification token mismatch")

    assert(:ok == A2A.Client.push_notification_config_delete(base_url, task_id, config_id), "push config delete failed")

    case A2A.Client.push_notification_config_list(base_url, task_id) do
      {:ok, []} -> :ok
      other -> raise "push list after delete should be empty: #{inspect(other)}"
    end
  end

  defp check_required_extensions_jsonrpc do
    base_url = "http://localhost:#{jsonrpc_ext_port()}"

    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "message/send",
      "params" => %{
        "message" => %{
          "messageId" => "ext-check",
          "role" => "user",
          "parts" => [%{"kind" => "text", "text" => "hello"}]
        }
      }
    }

    {:ok, without_ext} = Req.post(url: base_url, headers: [{"content-type", "application/json"}], body: Jason.encode!(payload))
    assert(without_ext.status == 200, "JSON-RPC required-extension path should respond with JSON-RPC envelope")
    body_without_ext = ensure_map_body(without_ext.body)
    assert(get_in(body_without_ext, ["error", "data", "type"]) == "ExtensionSupportRequiredError", "missing extension should be rejected")

    {:ok, with_ext} =
      Req.post(
        url: base_url,
        headers: [{"content-type", "application/json"}, {"a2a-extensions", "urn:required"}],
        body: Jason.encode!(payload)
      )

    body_with_ext = ensure_map_body(with_ext.body)
    assert(get_in(body_with_ext, ["result", "task", "id"]) != nil, "required extension should allow message/send")
  end

  defp wait_notifications(task_id, expected, timeout_ms \\ 3_000) do
    url = "http://localhost:#{notify_port()}/tasks/#{task_id}/notifications"
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_notifications(url, expected, deadline)
  end

  defp do_wait_notifications(url, expected, deadline) do
    {:ok, response} = Req.get(url: url)
    notifications = response.body["notifications"] || []

    cond do
      length(notifications) == expected ->
        notifications

      System.monotonic_time(:millisecond) >= deadline ->
        raise "Timed out waiting for notifications; got #{length(notifications)}, expected #{expected}"

      true ->
        Process.sleep(100)
        do_wait_notifications(url, expected, deadline)
    end
  end

  defp user_message(text) do
    %A2A.Types.Message{
      message_id: "msg-" <> Integer.to_string(System.unique_integer([:positive])),
      role: :user,
      parts: [%A2A.Types.TextPart{text: text}]
    }
  end

  defp ensure_map_body(body) when is_map(body), do: body
  defp ensure_map_body(body) when is_binary(body), do: Jason.decode!(body)

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      raw -> String.to_integer(raw)
    end
  end

  defp assert(true, _message), do: :ok
  defp assert(false, message), do: raise(message)

end

E2E.Suite.run()
