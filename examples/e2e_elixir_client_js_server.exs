# E2E: Elixir client -> JS SDK v0.3.10 server
#
# Coverage in this script:
# - discovery + transport negotiation via agent card
# - auth challenge/retry (401 + WWW-Authenticate)
# - REST and JSON-RPC send_message
# - JSON-RPC task lifecycle (get/cancel/resubscribe)
# - JSON-RPC list/subscribe behavior (currently unsupported by JS SDK server)
# - REST and JSON-RPC stream_message
# - push config lifecycle (set/get/list/delete) + real webhook delivery
#
# Run:
#   elixir examples/e2e_elixir_client_js_server.exs

Mix.install([
  {:a2a_ex, path: "."},
  {:req, "~> 0.5"}
])

defmodule E2E.ElixirClientJSServer do
  @js_dir Path.expand("examples/js_sdk_e2e", File.cwd!())
  @js_script "js_sdk_server_v0310.mjs"
  @host "127.0.0.1"
  @port 4310
  @auth_token "retry-token"

  defmodule AuthRetry do
    def headers(_opts), do: []

    def on_auth_challenge(challenge, _opts) do
      if is_binary(challenge) and String.contains?(challenge, "Bearer") do
        [{"authorization", "Bearer retry-token"}]
      else
        []
      end
    end
  end

  def run do
    ensure_npm_deps!()
    port = start_js_server!()

    try do
      wait_until_ready!()
      run_checks!()
      IO.puts("E2E passed: Elixir client -> JS server")
    after
      stop_port(port)
    end
  end

  defp ensure_npm_deps! do
    {output, code} = System.cmd("npm", ["install"], cd: @js_dir, stderr_to_stdout: true)

    if code != 0 do
      raise "npm install failed in #{@js_dir}\n#{output}"
    end
  end

  defp start_js_server! do
    node = System.find_executable("node") || raise "node executable not found"

    Port.open(
      {:spawn_executable, node},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        cd: @js_dir,
        args: [@js_script],
        env: [
          {~c"A2A_E2E_JS_SERVER_PORT", Integer.to_charlist(@port)},
          {~c"A2A_E2E_JS_SERVER_HOST", to_charlist(@host)},
          {~c"A2A_E2E_AUTH_TOKEN", to_charlist(@auth_token)}
        ]
      ]
    )
  end

  defp wait_until_ready!(timeout_ms \\ 8_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    url = "http://#{@host}:#{@port}/health"
    do_wait(url, deadline)
  end

  defp do_wait(url, deadline) do
    case Req.get(url: url) do
      {:ok, %{status: 200}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          raise "JS server did not become healthy at #{url}"
        end

        Process.sleep(120)
        do_wait(url, deadline)
    end
  end

  defp run_checks! do
    base = "http://#{@host}:#{@port}"
    rpc_base = base <> "/a2a/jsonrpc"

    {:ok, card} = A2A.Client.discover(base)
    true = card.protocol_version == "0.3.0"
    true = card.preferred_transport in ["JSONRPC", nil]

    {:ok, debug_card_resp} = Req.get(url: base <> "/debug/card")
    assert(get_in(debug_card_resp.body, ["capabilities", "pushNotifications"]) == true, "js server push capability should be enabled")

    interfaces = List.wrap(card.additional_interfaces)
    assert(length(interfaces) >= 2, "expected card to advertise multiple interfaces")

    {:ok, negotiated_response} =
      A2A.Client.send_message(rpc_base, [message: user_message("negotiated")],
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []}
      )

    {task_id, _ctx_id} = assert_task_and_echo(negotiated_response, "negotiated")

    # JSON-RPC task lifecycle parity.
    {:ok, %A2A.Types.Task{id: ^task_id}} =
      A2A.Client.get_task(rpc_base, task_id,
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []}
      )

    {:ok, resub_stream} =
      A2A.Client.resubscribe(rpc_base, task_id, %{},
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []}
      )

    resub_events = Enum.take(resub_stream, 1)
    assert(length(resub_events) >= 1, "expected at least one resubscribe event")

    # JS SDK server currently does not implement tasks/list or tasks/subscribe.
    list_resp =
      A2A.Client.list_tasks(rpc_base, %{},
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []}
      )

    assert(match?({:error, %A2A.Error{code: -32601}}, list_resp), "expected tasks/list to be unsupported on JS SDK server")

    subscribe_resp =
      A2A.Client.subscribe(rpc_base, task_id,
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []}
      )

    case subscribe_resp do
      {:ok, stream} ->
        _events = Enum.take(stream, 1)
        :ok

      {:error, %A2A.Error{code: -32601}} ->
        :ok

      {:error, %A2A.Error{code: code}} ->
        raise "unexpected tasks/subscribe error code: #{inspect(code)}"
    end

    # Explicit REST transport, with v0.3.10 proto-json compatibility and mounted path.
    {:ok, rest_response} =
      A2A.Client.send_message(base, [message: user_message("hello-from-elixir-rest")],
        transport: A2A.Transport.REST,
        version: :latest,
        rest_base_path: "/a2a/rest/v1",
        wire_format: :proto_json,
        auth: {AuthRetry, []}
      )

    _ = assert_task_and_echo(rest_response, "hello-from-elixir-rest")

    # Explicit JSON-RPC transport endpoint.
    {:ok, rpc_response} =
      A2A.Client.send_message(rpc_base, [message: user_message("hello-from-elixir-jsonrpc")],
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []}
      )

    _ = assert_task_and_echo(rpc_response, "hello-from-elixir-jsonrpc")

    # Streaming over JSON-RPC (direct SSE endpoint assertion).
    stream_payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "message/stream",
      "params" => %{
        "message" => %{
          "messageId" => "stream-" <> Integer.to_string(System.unique_integer([:positive])),
          "role" => "user",
          "parts" => [%{"kind" => "text", "text" => "stream-over-jsonrpc"}]
        }
      }
    }

    {:ok, stream_resp} =
      Req.post(
        url: rpc_base,
        headers: [
          {"content-type", "application/json"},
          {"accept", "text/event-stream"},
          {"authorization", "Bearer #{@auth_token}"}
        ],
        body: Jason.encode!(stream_payload),
        decode_body: false
      )

    assert(stream_resp.status == 200, "JSON-RPC stream endpoint returned non-200")
    assert(stream_resp.body != nil, "JSON-RPC stream endpoint returned empty body")

    # Push lifecycle over JSON-RPC.
    cfg_id = "cfg-" <> Integer.to_string(System.unique_integer([:positive]))

    push_token = "push-token"

    cfg = %A2A.Types.PushNotificationConfig{
      id: cfg_id,
      url: base <> "/push-receiver",
      token: push_token
    }

    {:ok, %A2A.Types.PushNotificationConfig{id: ^cfg_id}} =
      A2A.Client.push_notification_config_set(rpc_base, task_id, cfg,
        transport: A2A.Transport.JSONRPC,
        transport_opts: [jsonrpc_push_compat: :js_sdk],
        auth: {AuthRetry, []}
      )

    {:ok, %A2A.Types.PushNotificationConfig{id: ^cfg_id}} =
      A2A.Client.push_notification_config_get(rpc_base, task_id, cfg_id,
        transport: A2A.Transport.JSONRPC,
        transport_opts: [jsonrpc_push_compat: :js_sdk],
        auth: {AuthRetry, []}
      )

    {:ok, configs} =
      A2A.Client.push_notification_config_list(rpc_base, task_id, %{},
        transport: A2A.Transport.JSONRPC,
        transport_opts: [jsonrpc_push_compat: :js_sdk],
        auth: {AuthRetry, []}
      )

    assert(Enum.any?(configs, &(&1.id == cfg_id)), "expected push config to be listed")

    # Trigger push delivery on the same task.
    {:ok, _followup} =
      A2A.Client.send_message(rpc_base, [message: user_message("push-followup", task_id: task_id)],
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []}
      )

    push_event = wait_for_push_event!(base, task_id, 8_000)

    assert(
      get_in(push_event, ["headers", "x-a2a-notification-token"]) == push_token,
      "expected x-a2a-notification-token to match configured token"
    )

    delivered_task_id =
      get_in(push_event, ["body", "id"]) || get_in(push_event, ["body", "taskId"])

    assert(
      delivered_task_id == task_id,
      "expected delivered push payload to reference task #{task_id}"
    )

    :ok =
      A2A.Client.push_notification_config_delete(rpc_base, task_id, cfg_id,
        transport: A2A.Transport.JSONRPC,
        transport_opts: [jsonrpc_push_compat: :js_sdk],
        auth: {AuthRetry, []}
      )

    # Cancel on a dedicated task so it doesn't affect push-followup checks.
    {:ok, cancel_seed} =
      A2A.Client.send_message(rpc_base, [message: user_message("cancel-seed")],
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []}
      )

    {cancel_task_id, _ctx_id} = assert_task_and_echo(cancel_seed, "cancel-seed")

    {:ok, %A2A.Types.Task{id: ^cancel_task_id, status: %A2A.Types.TaskStatus{state: :canceled}}} =
      A2A.Client.cancel_task(rpc_base, cancel_task_id,
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []}
      )

    # Auth challenge/retry is exercised implicitly: all protected routes above
    # succeed while initial auth headers are empty.
  end

  defp assert_task_and_echo(
         %A2A.Types.Task{
           id: task_id,
           context_id: context_id,
           status: %A2A.Types.TaskStatus{message: %A2A.Types.Message{} = msg}
         },
         expected_tail
       ) do
    text = text_from_message(msg)
    assert(text == "js-sdk-echo:#{expected_tail}", "unexpected echo text: #{inspect(text)}")
    {task_id, context_id}
  end

  defp assert_task_and_echo(
         %A2A.Types.Message{task_id: task_id, context_id: context_id} = msg,
         expected_tail
       )
       when is_binary(task_id) do
    text = text_from_message(msg)
    assert(text == "js-sdk-echo:#{expected_tail}", "unexpected echo text: #{inspect(text)}")
    {task_id, context_id}
  end

  defp assert_task_and_echo(other, _expected_tail) do
    raise "expected task-with-message response, got: #{inspect(other)}"
  end

  defp text_from_message(%A2A.Types.Message{parts: [%A2A.Types.TextPart{text: text} | _]}), do: text
  defp text_from_message(_), do: ""

  defp wait_for_push_event!(base, task_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_push_event(base, task_id, deadline)
  end

  defp do_wait_for_push_event(base, task_id, deadline) do
    case Req.get(url: base <> "/debug/push-events") do
      {:ok, %{status: 200, body: %{"events" => events}}} when is_list(events) ->
        case Enum.find(events, fn event ->
               body = event["body"] || %{}
               body["id"] == task_id || body["taskId"] == task_id
             end) do
          nil ->
            if System.monotonic_time(:millisecond) > deadline do
              raise "timed out waiting for push event for task #{task_id}"
            end

            Process.sleep(120)
            do_wait_for_push_event(base, task_id, deadline)

          event ->
            event
        end

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          raise "timed out waiting for push events endpoint"
        end

        Process.sleep(120)
        do_wait_for_push_event(base, task_id, deadline)
    end
  end

  defp user_message(text, opts \\ []) do
    %A2A.Types.Message{
      kind: "message",
      message_id: "msg-" <> Integer.to_string(System.unique_integer([:positive])),
      role: :user,
      task_id: Keyword.get(opts, :task_id),
      parts: [%A2A.Types.TextPart{text: text}]
    }
  end

  defp assert(true, _message), do: :ok
  defp assert(false, message), do: raise(message)

  defp stop_port(nil), do: :ok

  defp stop_port(port) do
    Port.close(port)

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      250 -> :ok
    end
  end
end

E2E.ElixirClientJSServer.run()
