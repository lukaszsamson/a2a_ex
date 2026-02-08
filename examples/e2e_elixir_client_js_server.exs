# E2E: Elixir client -> JS SDK v0.3.10 server
#
# Coverage in this script:
# - discovery + transport negotiation via agent card
# - agent card edge behavior (extended card unsupported path on JS SDK server)
# - auth challenge/retry (401 + WWW-Authenticate)
# - extension negotiation (missing extension fails, required extension succeeds)
# - error contract interoperability (invalid params/method not found/task not found)
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
  @required_extension "https://example.com/extensions/e2e"

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
    extension = [@required_extension]

    {:ok, card} = A2A.Client.discover(base)
    true = card.protocol_version == "0.3.0"
    true = card.preferred_transport in ["JSONRPC", nil]

    {:ok, debug_card_resp} = Req.get(url: base <> "/debug/card")
    assert(get_in(debug_card_resp.body, ["capabilities", "pushNotifications"]) == true, "js server push capability should be enabled")

    interfaces = List.wrap(card.additional_interfaces)
    assert(length(interfaces) >= 2, "expected card to advertise multiple interfaces")

    run_extension_negotiation_checks!(base, rpc_base)
    run_agent_card_edge_checks!(base, rpc_base)
    run_error_contract_checks!(base, rpc_base)

    {:ok, negotiated_response} =
      A2A.Client.send_message(rpc_base, [message: user_message("negotiated")],
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []},
        extensions: extension
      )

    {task_id, _ctx_id} = assert_task_and_echo(negotiated_response, "negotiated")

    # JSON-RPC task lifecycle parity.
    {:ok, %A2A.Types.Task{id: ^task_id}} =
      A2A.Client.get_task(rpc_base, task_id,
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []},
        extensions: extension
      )

    {:ok, resub_stream} =
      A2A.Client.resubscribe(rpc_base, task_id, %{},
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []},
        extensions: extension
      )

    resub_events = Enum.take(resub_stream, 3)
    assert(length(resub_events) >= 1, "expected at least one resubscribe event")
    assert_stream_references_task(resub_events, task_id, "resubscribe should reference original task")

    # JS SDK server currently does not implement tasks/list or tasks/subscribe.
    list_resp =
      A2A.Client.list_tasks(rpc_base, %{},
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []},
        extensions: extension
      )

    assert(match?({:error, %A2A.Error{code: -32601}}, list_resp), "expected tasks/list to be unsupported on JS SDK server")

    subscribe_resp =
      A2A.Client.subscribe(rpc_base, task_id,
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []},
        extensions: extension
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
        auth: {AuthRetry, []},
        extensions: extension
      )

    _ = assert_task_and_echo(rest_response, "hello-from-elixir-rest")

    # Explicit JSON-RPC transport endpoint.
    {:ok, rpc_response} =
      A2A.Client.send_message(rpc_base, [message: user_message("hello-from-elixir-jsonrpc")],
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []},
        extensions: extension
      )

    _ = assert_task_and_echo(rpc_response, "hello-from-elixir-jsonrpc")

    # Streaming semantics over JSON-RPC.
    {:ok, rpc_stream} =
      A2A.Client.stream_message(rpc_base, [message: user_message("stream-over-jsonrpc")],
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []},
        extensions: extension
      )

    rpc_stream_events = Enum.take(rpc_stream, 8)
    assert_stream_semantics(rpc_stream_events, "JSON-RPC stream semantics invalid")

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
        auth: {AuthRetry, []},
        extensions: extension
      )

    {:ok, %A2A.Types.PushNotificationConfig{id: ^cfg_id}} =
      A2A.Client.push_notification_config_get(rpc_base, task_id, cfg_id,
        transport: A2A.Transport.JSONRPC,
        transport_opts: [jsonrpc_push_compat: :js_sdk],
        auth: {AuthRetry, []},
        extensions: extension
      )

    {:ok, configs} =
      A2A.Client.push_notification_config_list(rpc_base, task_id, %{},
        transport: A2A.Transport.JSONRPC,
        transport_opts: [jsonrpc_push_compat: :js_sdk],
        auth: {AuthRetry, []},
        extensions: extension
      )

    assert(Enum.any?(configs, &(&1.id == cfg_id)), "expected push config to be listed")

    # Trigger push delivery on the same task.
    {:ok, _followup} =
      A2A.Client.send_message(rpc_base, [message: user_message("push-followup", task_id: task_id)],
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []},
        extensions: extension
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
        auth: {AuthRetry, []},
        extensions: extension
      )

    # Cancel on a dedicated task so it doesn't affect push-followup checks.
    {:ok, cancel_seed} =
      A2A.Client.send_message(rpc_base, [message: user_message("cancel-seed")],
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []},
        extensions: extension
      )

    {cancel_task_id, _ctx_id} = assert_task_and_echo(cancel_seed, "cancel-seed")

    {:ok, %A2A.Types.Task{id: ^cancel_task_id, status: %A2A.Types.TaskStatus{state: :canceled}}} =
      A2A.Client.cancel_task(rpc_base, cancel_task_id,
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []},
        extensions: extension
      )

    # Auth challenge/retry is exercised implicitly: all protected routes above
    # succeed while initial auth headers are empty.
  end

  defp run_agent_card_edge_checks!(base, rpc_base) do
    {:ok, card_resp} = Req.get(url: base <> "/.well-known/agent-card.json")
    assert(card_resp.status == 200, "expected public card endpoint to be available")

    card = card_resp.body
    assert(is_map(card), "expected card response body map")
    assert(Map.get(card, "supportsAuthenticatedExtendedCard") != true, "JS fixture should not advertise authenticated extended card support")

    interfaces = List.wrap(Map.get(card, "additionalInterfaces"))
    has_jsonrpc = Enum.any?(interfaces, &(&1["transport"] == "JSONRPC"))
    has_rest = Enum.any?(interfaces, &(&1["transport"] == "HTTP+JSON"))

    assert(has_jsonrpc and has_rest, "expected JSONRPC and HTTP+JSON interfaces in card")

    # JS SDK v0.3.10 fixture does not expose extended card methods through this server setup.
    ext_result =
      A2A.Client.get_extended_agent_card(rpc_base,
        transport: A2A.Transport.JSONRPC,
        auth: {AuthRetry, []},
        extensions: [@required_extension]
      )

    assert(match?({:error, %A2A.Error{}}, ext_result), "expected get_extended_agent_card to fail on JS fixture")
  end

  defp run_extension_negotiation_checks!(base, rpc_base) do
    # JSON-RPC without required extension should fail.
    {:ok, missing_extension_rpc} =
      Req.post(
        url: rpc_base,
        headers: [
          {"content-type", "application/json"},
          {"authorization", "Bearer #{@auth_token}"}
        ],
        body:
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 190,
            "method" => "message/send",
            "params" => %{
              "message" => %{
                "messageId" => "msg-missing-ext",
                "role" => "user",
                "parts" => [%{"kind" => "text", "text" => "missing extension"}]
              }
            }
          })
      )

    assert(get_in(missing_extension_rpc.body, ["error", "code"]) == -32000, "expected missing-extension JSON-RPC error")

    # JSON-RPC with required extension should succeed.
    {:ok, with_extension_rpc} =
      Req.post(
        url: rpc_base,
        headers: [
          {"content-type", "application/json"},
          {"authorization", "Bearer #{@auth_token}"},
          {"a2a-extensions", @required_extension}
        ],
        body:
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 191,
            "method" => "message/send",
            "params" => %{
              "message" => %{
                "messageId" => "msg-with-ext",
                "role" => "user",
                "parts" => [%{"kind" => "text", "text" => "with extension"}]
              }
            }
          })
      )

    assert(with_extension_rpc.status == 200, "expected success when extension is provided")
    assert(
      get_in(with_extension_rpc.headers, ["a2a-extensions"]) |> List.first() == @required_extension,
      "expected negotiated extension header in response"
    )

    # REST without required extension should fail.
    {:ok, missing_extension_rest} =
      Req.post(
        url: base <> "/a2a/rest/v1/message:send",
        headers: [
          {"content-type", "application/json"},
          {"authorization", "Bearer #{@auth_token}"}
        ],
        body:
          Jason.encode!(%{
            "message" => %{
              "messageId" => "msg-rest-missing-ext",
              "role" => "user",
              "parts" => [%{"kind" => "text", "text" => "rest missing extension"}]
            }
          })
      )

    assert(missing_extension_rest.status >= 400, "expected REST missing-extension failure")
  end

  defp run_error_contract_checks!(base, rpc_base) do
    # JSON-RPC: method not found
    {:ok, unknown_method_resp} =
      Req.post(
        url: rpc_base,
        headers: [
          {"content-type", "application/json"},
          {"authorization", "Bearer #{@auth_token}"},
          {"a2a-extensions", @required_extension}
        ],
        body:
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 201,
            "method" => "tasks/notARealMethod",
            "params" => %{}
          })
      )

    assert(unknown_method_resp.status == 200, "JSON-RPC method-not-found should return HTTP 200")
    assert(get_in(unknown_method_resp.body, ["error", "code"]) == -32601, "expected JSON-RPC -32601 for method-not-found")

    # JSON-RPC: invalid params
    {:ok, invalid_params_resp} =
      Req.post(
        url: rpc_base,
        headers: [
          {"content-type", "application/json"},
          {"authorization", "Bearer #{@auth_token}"},
          {"a2a-extensions", @required_extension}
        ],
        body:
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 202,
            "method" => "tasks/get",
            "params" => []
          })
      )

    assert(invalid_params_resp.status == 200, "JSON-RPC invalid-params should return HTTP 200")
    assert(get_in(invalid_params_resp.body, ["error", "code"]) == -32602, "expected JSON-RPC -32602 for invalid params")

    # JSON-RPC: task not found
    {:ok, task_not_found_resp} =
      Req.post(
        url: rpc_base,
        headers: [
          {"content-type", "application/json"},
          {"authorization", "Bearer #{@auth_token}"},
          {"a2a-extensions", @required_extension}
        ],
        body:
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 203,
            "method" => "tasks/get",
            "params" => %{"id" => "task-does-not-exist"}
          })
      )

    assert(task_not_found_resp.status == 200, "JSON-RPC task-not-found should return HTTP 200")
    assert(get_in(task_not_found_resp.body, ["error", "code"]) == -32001, "expected JSON-RPC task-not-found code -32001")

    # REST: invalid params
    {:ok, rest_invalid_resp} =
      Req.post(
        url: base <> "/a2a/rest/v1/message:send",
        headers: [
          {"content-type", "application/json"},
          {"authorization", "Bearer #{@auth_token}"},
          {"a2a-extensions", @required_extension}
        ],
        body: Jason.encode!(%{})
      )

    assert(rest_invalid_resp.status >= 400, "REST invalid-params should return non-2xx status")

    # REST: task not found
    {:ok, rest_not_found_resp} =
      Req.get(
        url: base <> "/a2a/rest/v1/tasks/task-does-not-exist",
        headers: [
          {"authorization", "Bearer #{@auth_token}"},
          {"a2a-extensions", @required_extension}
        ]
      )

    assert(rest_not_found_resp.status in [400, 404], "REST task-not-found should map to 4xx")
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

  defp assert_stream_semantics(events, error_message) do
    assert(length(events) >= 3, error_message <> ": expected multiple stream events")

    kinds = Enum.map(events, &stream_event_kind/1)

    task_index = Enum.find_index(kinds, &(&1 == :task))
    status_indices = indices_for(kinds, :status_update)
    artifact_index = Enum.find_index(kinds, &(&1 == :artifact_update))

    assert(task_index != nil, error_message <> ": missing task event")
    assert(length(status_indices) >= 1, error_message <> ": missing status update events")
    assert(artifact_index != nil, error_message <> ": missing artifact update event")

    first_status = Enum.min(status_indices)
    last_status = Enum.max(status_indices)

    assert(task_index < first_status, error_message <> ": task should appear before status updates")
    assert(first_status < artifact_index, error_message <> ": working status should appear before artifact")
    assert(artifact_index <= last_status, error_message <> ": artifact should appear before final status")

    final_status =
      events
      |> Enum.filter(&(stream_event_kind(&1) == :status_update))
      |> Enum.reverse()
      |> Enum.find(fn event ->
        case stream_status_update(event) do
          %A2A.Types.TaskStatusUpdateEvent{final: true} -> true
          _ -> false
        end
      end)

    assert(final_status != nil, error_message <> ": missing terminal status update with final=true")
  end

  defp assert_stream_references_task(events, task_id, error_message) do
    assert(
      Enum.any?(events, fn event -> stream_event_task_id(event) == task_id end),
      error_message
    )
  end

  defp indices_for(list, value) do
    list
    |> Enum.with_index()
    |> Enum.filter(fn {item, _idx} -> item == value end)
    |> Enum.map(fn {_item, idx} -> idx end)
  end

  defp stream_event_kind(%A2A.Types.StreamResponse{task: %A2A.Types.Task{}}), do: :task

  defp stream_event_kind(%A2A.Types.StreamResponse{status_update: %A2A.Types.TaskStatusUpdateEvent{}}),
    do: :status_update

  defp stream_event_kind(%A2A.Types.StreamResponse{artifact_update: %A2A.Types.TaskArtifactUpdateEvent{}}),
    do: :artifact_update

  defp stream_event_kind(%A2A.Types.StreamResponse{message: %A2A.Types.Message{}}), do: :message
  defp stream_event_kind(_), do: :unknown

  defp stream_event_task_id(%A2A.Types.StreamResponse{task: %A2A.Types.Task{id: id}}), do: id

  defp stream_event_task_id(%A2A.Types.StreamResponse{
         status_update: %A2A.Types.TaskStatusUpdateEvent{task_id: id}
       }),
       do: id

  defp stream_event_task_id(%A2A.Types.StreamResponse{
         artifact_update: %A2A.Types.TaskArtifactUpdateEvent{task_id: id}
       }),
       do: id

  defp stream_event_task_id(%A2A.Types.StreamResponse{message: %A2A.Types.Message{task_id: id}}), do: id
  defp stream_event_task_id(_), do: nil

  defp stream_status_update(%A2A.Types.StreamResponse{
         status_update: %A2A.Types.TaskStatusUpdateEvent{} = status_update
       }),
       do: status_update

  defp stream_status_update(_), do: nil

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
