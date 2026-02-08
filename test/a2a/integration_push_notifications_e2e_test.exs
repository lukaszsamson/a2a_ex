defmodule A2A.IntegrationPushNotificationsE2ETest do
  use ExUnit.Case, async: false

  defmodule NotificationStore do
    def start_link do
      Agent.start_link(fn -> %{} end)
    end

    def put(agent, task_id, notification) do
      Agent.update(agent, fn state ->
        Map.update(state, task_id, [notification], fn notifications ->
          notifications ++ [notification]
        end)
      end)
    end

    def get(agent, task_id) do
      Agent.get(agent, fn state -> Map.get(state, task_id, []) end)
    end
  end

  defmodule NotificationReceiverPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      store = Keyword.fetch!(opts, :store)

      case {conn.method, conn.path_info} do
        {"GET", ["health"]} ->
          send_json(conn, %{"status" => "ok"})

        {"POST", ["notifications"]} ->
          {:ok, body, conn} = read_body(conn)
          token = get_req_header(conn, "x-a2a-notification-token") |> List.first()
          payload = Jason.decode!(body)
          task_id = payload["id"] || get_in(payload, ["task", "id"])

          NotificationStore.put(store, task_id, %{"token" => token, "task" => payload})

          send_json(conn, %{"status" => "received"})

        {"GET", ["tasks", task_id, "notifications"]} ->
          notifications = NotificationStore.get(store, task_id)
          send_json(conn, %{"notifications" => notifications})

        _ ->
          send_resp(conn, 404, "")
      end
    end

    defp send_json(conn, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end

  defmodule PushE2EExecutor do
    @behaviour A2A.Server.Executor

    def start_link do
      Agent.start_link(fn -> %{} end)
    end

    def handle_send_message(request, ctx), do: handle_send_message(%{}, request, ctx)

    def handle_send_message(opts, request, _ctx) do
      task_id =
        request.message.task_id ||
          "task-" <> Integer.to_string(System.unique_integer([:positive]))

      context_id =
        request.message.context_id ||
          "ctx-" <> Integer.to_string(System.unique_integer([:positive]))

      text = extract_text(request.message)

      maybe_store_request_config(opts, task_id, request.configuration)
      config = get_config(opts, task_id)

      status_state =
        case text do
          "How are you?" -> :input_required
          _ -> :completed
        end

      task = %A2A.Types.Task{
        id: task_id,
        context_id: context_id,
        status: %A2A.Types.TaskStatus{state: status_state}
      }

      maybe_push(config, task)
      {:ok, task}
    end

    def handle_get_task(task_id, query, ctx), do: handle_get_task(%{}, task_id, query, ctx)

    def handle_get_task(_opts, _task_id, _query, _ctx),
      do: {:error, A2A.Error.new(:task_not_found, "missing")}

    def handle_list_tasks(request, ctx), do: handle_list_tasks(%{}, request, ctx)

    def handle_list_tasks(_opts, _request, _ctx),
      do: {:ok, %A2A.Types.ListTasksResponse{tasks: []}}

    def handle_cancel_task(task_id, ctx), do: handle_cancel_task(%{}, task_id, ctx)

    def handle_cancel_task(_opts, task_id, _ctx) do
      {:ok,
       %A2A.Types.Task{
         id: task_id,
         context_id: "ctx-1",
         status: %A2A.Types.TaskStatus{state: :canceled}
       }}
    end

    def handle_push_notification_config_set(opts, task_id, config, _ctx) do
      put_config(opts, task_id, config)
      {:ok, config}
    end

    def handle_push_notification_config_get(opts, task_id, _config_id, _ctx) do
      case get_config(opts, task_id) do
        nil -> {:error, A2A.Error.new(:task_not_found, "config not found")}
        config -> {:ok, config}
      end
    end

    def handle_push_notification_config_list(opts, task_id, _query, _ctx) do
      case get_config(opts, task_id) do
        nil -> {:ok, []}
        config -> {:ok, [config]}
      end
    end

    def handle_push_notification_config_delete(opts, task_id, _config_id, _ctx) do
      delete_config(opts, task_id)
      :ok
    end

    defp maybe_store_request_config(_opts, _task_id, nil), do: :ok

    defp maybe_store_request_config(
           opts,
           task_id,
           %A2A.Types.SendMessageConfiguration{} = configuration
         ) do
      case configuration.push_notification_config do
        %A2A.Types.PushNotificationConfig{} = config -> put_config(opts, task_id, config)
        _ -> :ok
      end
    end

    defp maybe_push(nil, _task), do: :ok

    defp maybe_push(%A2A.Types.PushNotificationConfig{} = config, task) do
      _ = A2A.Server.Push.deliver(config, task, allow_http: true)
      :ok
    end

    defp extract_text(%A2A.Types.Message{parts: [%A2A.Types.TextPart{text: text} | _]}), do: text
    defp extract_text(_), do: ""

    defp put_config(opts, task_id, %A2A.Types.PushNotificationConfig{} = config) do
      store = Map.fetch!(opts, :push_config_store)
      Agent.update(store, &Map.put(&1, task_id, config))
    end

    defp get_config(opts, task_id) do
      store = Map.fetch!(opts, :push_config_store)
      Agent.get(store, &Map.get(&1, task_id))
    end

    defp delete_config(opts, task_id) do
      store = Map.fetch!(opts, :push_config_store)
      Agent.update(store, &Map.delete(&1, task_id))
    end
  end

  setup do
    {:ok, notification_store} = NotificationStore.start_link()

    notification_server =
      A2A.TestHTTPServer.start(NotificationReceiverPlug, plug_opts: [store: notification_store])

    on_exit(fn -> A2A.TestHTTPServer.stop(notification_server.ref) end)

    {:ok, push_config_store} = PushE2EExecutor.start_link()
    {:ok, task_store} = A2A.TaskStore.ETS.init(name: unique_store_name("push_e2e_task_store"))

    wrapped_executor =
      {A2A.Server.TaskStoreExecutor,
       %{
         executor: {PushE2EExecutor, %{push_config_store: push_config_store}},
         task_store: {A2A.TaskStore.ETS, task_store},
         allow_http: true
       }}

    agent_server =
      A2A.TestHTTPServer.start(
        A2A.Server.REST.Plug,
        plug_opts: [executor: wrapped_executor, capabilities: %{push_notifications: true}]
      )

    on_exit(fn -> A2A.TestHTTPServer.stop(agent_server.ref) end)

    {:ok, notification_server: notification_server, agent_server: agent_server}
  end

  test "triggers push notification when config is provided in send message request", %{
    notification_server: notification_server,
    agent_server: agent_server
  } do
    token = "token-" <> Integer.to_string(System.unique_integer([:positive]))

    config = %A2A.Types.PushNotificationConfig{
      id: "in-message-config",
      url: notification_server.base_url <> "/notifications",
      token: token
    }

    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{
        message_id: "hello-agent",
        role: :user,
        parts: [%A2A.Types.TextPart{text: "Hello Agent!"}]
      },
      configuration: %A2A.Types.SendMessageConfiguration{push_notification_config: config}
    }

    assert {:ok, %A2A.Types.Task{id: task_id, status: %A2A.Types.TaskStatus{state: :completed}}} =
             A2A.Client.send_message(agent_server.base_url, request)

    [notification] = wait_for_notifications(notification_server.base_url, task_id, 1)
    assert notification["token"] == token
    assert notification["task"]["id"] == task_id
    assert get_in(notification, ["task", "status", "state"]) == "completed"
  end

  test "triggers push notification after config is set in separate call", %{
    notification_server: notification_server,
    agent_server: agent_server
  } do
    assert {:ok,
            %A2A.Types.Task{id: task_id, status: %A2A.Types.TaskStatus{state: :input_required}}} =
             A2A.Client.send_message(agent_server.base_url,
               message: %A2A.Types.Message{
                 message_id: "how-are-you",
                 role: :user,
                 parts: [%A2A.Types.TextPart{text: "How are you?"}]
               }
             )

    assert [] == wait_for_notifications(notification_server.base_url, task_id, 0)

    token = "token-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, %A2A.Types.PushNotificationConfig{}} =
             A2A.Client.push_notification_config_set(
               agent_server.base_url,
               task_id,
               %A2A.Types.PushNotificationConfig{
                 id: "after-config-change",
                 url: notification_server.base_url <> "/notifications",
                 token: token
               }
             )

    assert {:ok, %A2A.Types.Task{id: ^task_id, status: %A2A.Types.TaskStatus{state: :completed}}} =
             A2A.Client.send_message(agent_server.base_url,
               message: %A2A.Types.Message{
                 task_id: task_id,
                 message_id: "good",
                 role: :user,
                 parts: [%A2A.Types.TextPart{text: "Good"}]
               }
             )

    [notification] = wait_for_notifications(notification_server.base_url, task_id, 1)
    assert notification["token"] == token
    assert notification["task"]["id"] == task_id
    assert get_in(notification, ["task", "status", "state"]) == "completed"
  end

  test "supports push config lifecycle get/list/delete and delete stops new pushes", %{
    notification_server: notification_server,
    agent_server: agent_server
  } do
    assert {:ok,
            %A2A.Types.Task{id: task_id, status: %A2A.Types.TaskStatus{state: :input_required}}} =
             A2A.Client.send_message(agent_server.base_url,
               message: %A2A.Types.Message{
                 message_id: "lifecycle-initial",
                 role: :user,
                 parts: [%A2A.Types.TextPart{text: "How are you?"}]
               }
             )

    token = "token-" <> Integer.to_string(System.unique_integer([:positive]))
    config_id = "cfg-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, %A2A.Types.PushNotificationConfig{id: ^config_id, token: ^token}} =
             A2A.Client.push_notification_config_set(
               agent_server.base_url,
               task_id,
               %A2A.Types.PushNotificationConfig{
                 id: config_id,
                 url: notification_server.base_url <> "/notifications",
                 token: token
               }
             )

    assert {:ok, %A2A.Types.PushNotificationConfig{id: ^config_id, token: ^token}} =
             A2A.Client.push_notification_config_get(agent_server.base_url, task_id, config_id)

    assert {:ok, [%A2A.Types.PushNotificationConfig{id: ^config_id, token: ^token}]} =
             A2A.Client.push_notification_config_list(agent_server.base_url, task_id)

    assert :ok ==
             A2A.Client.push_notification_config_delete(agent_server.base_url, task_id, config_id)

    assert {:error, %A2A.Error{type: :task_not_found}} =
             A2A.Client.push_notification_config_get(agent_server.base_url, task_id, config_id)

    assert {:ok, []} = A2A.Client.push_notification_config_list(agent_server.base_url, task_id)

    assert {:ok, %A2A.Types.Task{id: ^task_id, status: %A2A.Types.TaskStatus{state: :completed}}} =
             A2A.Client.send_message(agent_server.base_url,
               message: %A2A.Types.Message{
                 task_id: task_id,
                 message_id: "lifecycle-followup-final",
                 role: :user,
                 parts: [%A2A.Types.TextPart{text: "Good"}]
               }
             )

    assert [] == wait_for_notifications(notification_server.base_url, task_id, 0)
  end

  defp wait_for_notifications(base_url, task_id, expected_count, timeout_ms \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    url = "#{base_url}/tasks/#{task_id}/notifications"

    do_wait_for_notifications(url, expected_count, deadline)
  end

  defp do_wait_for_notifications(url, expected_count, deadline) do
    {:ok, response} = Req.get(url: url)
    notifications = get_in(response.body, ["notifications"]) || []

    cond do
      length(notifications) == expected_count ->
        notifications

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "Notification retrieval timed out: got #{length(notifications)}, expected #{expected_count}"
        )

      true ->
        Process.sleep(100)
        do_wait_for_notifications(url, expected_count, deadline)
    end
  end

  defp unique_store_name(prefix) do
    String.to_atom(prefix <> "_" <> Integer.to_string(System.unique_integer([:positive])))
  end
end
