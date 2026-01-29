defmodule A2A.Server.JSONRPC.Plug do
  @moduledoc """
  Plug implementation for the A2A JSON-RPC transport.
  """

  import Plug.Conn

  @spec init(keyword()) :: map()
  def init(opts) do
    executor = wrap_task_store(Keyword.fetch!(opts, :executor), Keyword.get(opts, :task_store))

    %{
      executor: executor,
      version: Keyword.get(opts, :version, :v0_3),
      capabilities: Keyword.get(opts, :capabilities, %{}),
      required_extensions: Keyword.get(opts, :required_extensions, []),
      stream_timeout: Keyword.get(opts, :stream_timeout, :infinity),
      request_timeout: Keyword.get(opts, :request_timeout, :infinity),
      stream_task_first: Keyword.get(opts, :stream_task_first, true)
    }
  end

  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, opts) do
    conn = A2A.Server.Headers.ensure_request_id(conn)
    extensions = A2A.Server.Headers.extensions(conn)

    with :ok <- A2A.Server.Headers.validate_version(conn, opts.version),
         :ok <- ensure_extensions(extensions, opts.required_extensions) do
      metadata = %{transport: :jsonrpc, method: conn.method, path: conn.request_path}

      A2A.Telemetry.span([:a2a, :server, :request], metadata, fn ->
        handle_jsonrpc(conn, opts, extensions)
      end)
    else
      {:error, error} ->
        send_json(conn, 200, jsonrpc_error(-32000, A2A.Error.to_map(error)), extensions)
    end
  end

  defp handle_jsonrpc(conn, opts, extensions) do
    with {:ok, body} <- read_json(conn) do
      case streaming_method(body, opts.version, conn) do
        {:error, error} ->
          id = Map.get(body, "id")
          send_json(conn, 200, jsonrpc_error(-32000, error, id), extensions)

        nil ->
          case handle_request(body, opts, conn, extensions) do
            {:ok, response} ->
              send_json(conn, 200, response, extensions)

            {:stream, stream} ->
              send_stream(conn, stream, extensions)

            {:error, error} when is_map(error) ->
              send_json(conn, 200, error, extensions)
          end

        method ->
          handle_streaming(conn, body, method, opts, extensions)
      end
    else
      {:error, %A2A.Error{} = error} ->
        send_json(conn, 200, jsonrpc_error(-32000, A2A.Error.to_map(error)), extensions)

      {:error, error} when is_map(error) ->
        send_json(conn, 200, error, extensions)
    end
  end

  defp handle_request(
         %{"jsonrpc" => "2.0", "id" => id, "method" => method} = payload,
         opts,
         conn,
         extensions
       ) do
    params = Map.get(payload, "params", %{})

    case dispatch(method, params, opts, conn, extensions) do
      {:ok, result} -> {:ok, %{"jsonrpc" => "2.0", "id" => id, "result" => result}}
      {:stream, payloads} -> {:stream, %{id: id, payloads: payloads}}
      {:invalid_params, message} -> {:error, jsonrpc_error(-32602, message, id)}
      {:rpc_error, code, message} -> {:error, jsonrpc_error(code, message, id)}
      {:error, %A2A.Error{} = error} -> {:error, jsonrpc_error(-32000, error, id)}
      {:error, error} -> {:error, jsonrpc_error(-32603, error, id)}
    end
  end

  defp handle_request(_payload, _opts, _conn, _extensions) do
    {:error, jsonrpc_error(-32600, "Invalid Request")}
  end

  defp streaming_method(%{"method" => method}, version, conn) do
    case method_key(method, version) do
      :stream_message -> streaming_or_error(:stream_message, conn)
      :resubscribe -> streaming_or_error(:resubscribe, conn)
      :subscribe -> streaming_or_error(:subscribe, conn)
      _ -> nil
    end
  end

  defp streaming_method(_, _version, _conn), do: nil

  defp streaming_or_error(method, conn) do
    if accepts_stream?(conn) do
      method
    else
      {:error,
       A2A.Error.new(:content_type_not_supported, "Accept must include text/event-stream")}
    end
  end

  defp accepts_stream?(conn) do
    case get_req_header(conn, "accept") do
      [] ->
        true

      values ->
        Enum.any?(values, fn value ->
          value = String.downcase(value)
          String.contains?(value, "text/event-stream") or String.contains?(value, "*/*")
        end)
    end
  end

  defp handle_streaming(conn, payload, method, opts, extensions) do
    params = Map.get(payload, "params", %{})
    id = Map.get(payload, "id")

    case method do
      :stream_message ->
        with :ok <- ensure_capability(opts.capabilities, :streaming),
             :ok <- ensure_handler(opts.executor, :handle_stream_message, 3),
             {:ok, _} <- require_param(params, "message", "Missing message") do
          stream_jsonrpc(conn, id, opts, extensions, opts.stream_task_first, fn emit ->
            request = A2A.Types.SendMessageRequest.from_map(params, version: opts.version)

            A2A.Server.ExecutorRunner.call(opts.executor, :handle_stream_message, [
              request,
              ctx(conn, extensions),
              emit
            ])
          end)
        else
          {:invalid_params, message} ->
            send_json(conn, 200, jsonrpc_error(-32602, message, id), extensions)

          {:error, %A2A.Error{} = error} ->
            send_json(conn, 200, jsonrpc_error(-32000, error, id), extensions)
        end

      :resubscribe ->
        with :ok <- ensure_capability(opts.capabilities, :streaming),
             :ok <- ensure_handler(opts.executor, :handle_resubscribe, 4),
             {:ok, task_id} <- require_task_id(params) do
          stream_jsonrpc(conn, id, opts, extensions, false, fn emit ->
            resume = params["resume"] || %{}

            A2A.Server.ExecutorRunner.call(opts.executor, :handle_resubscribe, [
              task_id,
              resume,
              ctx(conn, extensions),
              emit
            ])
          end)
        else
          {:invalid_params, message} ->
            send_json(conn, 200, jsonrpc_error(-32602, message, id), extensions)

          {:error, %A2A.Error{} = error} ->
            send_json(conn, 200, jsonrpc_error(-32000, error, id), extensions)
        end

      :subscribe ->
        with :ok <- ensure_capability(opts.capabilities, :streaming),
             :ok <- ensure_handler(opts.executor, :handle_subscribe, 3),
             {:ok, task_id} <- require_task_id(params) do
          stream_jsonrpc(conn, id, opts, extensions, false, fn emit ->
            A2A.Server.ExecutorRunner.call(opts.executor, :handle_subscribe, [
              task_id,
              ctx(conn, extensions),
              emit
            ])
          end)
        else
          {:invalid_params, message} ->
            send_json(conn, 200, jsonrpc_error(-32602, message, id), extensions)

          {:error, %A2A.Error{} = error} ->
            send_json(conn, 200, jsonrpc_error(-32000, error, id), extensions)
        end
    end
  end

  defp dispatch(method, params, opts, conn, extensions) do
    case method_key(method, opts.version) do
      :send_message ->
        with {:ok, _message} <- require_param(params, "message", "Missing message") do
          request = A2A.Types.SendMessageRequest.from_map(params, version: opts.version)

          with {:ok, response} <-
                 run_request(opts, fn ->
                   A2A.Server.ExecutorRunner.call(opts.executor, :handle_send_message, [
                     request,
                     ctx(conn, extensions)
                   ])
                 end) do
            {:ok,
             A2A.Types.SendMessageResponse.to_map(wrap_message_response(response),
               version: opts.version
             )}
          end
        end

      :get_task ->
        with {:ok, task_id} <- require_task_id(params),
             {:ok, task} <-
               run_request(opts, fn ->
                 A2A.Server.ExecutorRunner.call(opts.executor, :handle_get_task, [
                   task_id,
                   %{},
                   ctx(conn, extensions)
                 ])
               end) do
          {:ok, A2A.Types.Task.to_map(task, version: opts.version)}
        end

      :list_tasks ->
        request = A2A.Types.ListTasksRequest.from_map(params, version: opts.version)

        with {:ok, response} <-
               run_request(opts, fn ->
                 A2A.Server.ExecutorRunner.call(opts.executor, :handle_list_tasks, [
                   request,
                   ctx(conn, extensions)
                 ])
               end) do
          {:ok, A2A.Types.ListTasksResponse.to_map(response, version: opts.version)}
        end

      :cancel_task ->
        with {:ok, task_id} <- require_task_id(params),
             {:ok, response} <-
               run_request(opts, fn ->
                 A2A.Server.ExecutorRunner.call(opts.executor, :handle_cancel_task, [
                   task_id,
                   ctx(conn, extensions)
                 ])
               end) do
          {:ok, A2A.Types.Task.to_map(response, version: opts.version)}
        end

      :push_notification_config_set ->
        with :ok <- ensure_capability(opts.capabilities, :push_notifications),
             {:ok, task_id} <- require_param(params, "taskId", "Missing taskId"),
             config <- decode_push_config(params),
             {:ok, response} <-
               run_request(opts, fn ->
                 A2A.Server.ExecutorRunner.call(
                   opts.executor,
                   :handle_push_notification_config_set,
                   [task_id, config, ctx(conn, extensions)]
                 )
               end) do
          {:ok, encode_push_config(response)}
        end

      :push_notification_config_get ->
        with :ok <- ensure_capability(opts.capabilities, :push_notifications),
             {:ok, task_id} <- require_param(params, "taskId", "Missing taskId"),
             {:ok, config_id} <- require_param(params, "configId", "Missing configId"),
             {:ok, response} <-
               run_request(opts, fn ->
                 A2A.Server.ExecutorRunner.call(
                   opts.executor,
                   :handle_push_notification_config_get,
                   [task_id, config_id, ctx(conn, extensions)]
                 )
               end) do
          {:ok, encode_push_config(response)}
        end

      :push_notification_config_list ->
        with :ok <- ensure_capability(opts.capabilities, :push_notifications),
             {:ok, task_id} <- require_param(params, "taskId", "Missing taskId"),
             {:ok, response} <-
               run_request(opts, fn ->
                 A2A.Server.ExecutorRunner.call(
                   opts.executor,
                   :handle_push_notification_config_list,
                   [task_id, params, ctx(conn, extensions)]
                 )
               end) do
          {:ok, %{"pushNotificationConfigs" => Enum.map(response, &encode_push_config/1)}}
        end

      :push_notification_config_delete ->
        with :ok <- ensure_capability(opts.capabilities, :push_notifications),
             {:ok, task_id} <- require_param(params, "taskId", "Missing taskId"),
             {:ok, config_id} <- require_param(params, "configId", "Missing configId"),
             :ok <-
               run_request(opts, fn ->
                 A2A.Server.ExecutorRunner.call(
                   opts.executor,
                   :handle_push_notification_config_delete,
                   [task_id, config_id, ctx(conn, extensions)]
                 )
               end) do
          {:ok, %{}}
        end

      :get_extended_agent_card ->
        # Available in both v0.3.0 (agent/getAuthenticatedExtendedCard) and latest (GetExtendedAgentCard)
        with :ok <- ensure_capability(opts.capabilities, :extended_agent_card),
             {:ok, card} <-
               run_request(opts, fn ->
                 A2A.Server.ExecutorRunner.call(opts.executor, :handle_get_extended_agent_card, [
                   ctx(conn, extensions)
                 ])
               end) do
          {:ok, A2A.Types.AgentCard.to_map(card, version: opts.version)}
        end

      _ ->
        {:rpc_error, -32601, "Method not found"}
    end
  end

  defp method_key(method, :latest) do
    case method do
      "SendMessage" -> :send_message
      "SendStreamingMessage" -> :stream_message
      "GetTask" -> :get_task
      "ListTasks" -> :list_tasks
      "CancelTask" -> :cancel_task
      "SubscribeToTask" -> :subscribe
      "CreateTaskPushNotificationConfig" -> :push_notification_config_set
      "GetTaskPushNotificationConfig" -> :push_notification_config_get
      "ListTaskPushNotificationConfig" -> :push_notification_config_list
      "DeleteTaskPushNotificationConfig" -> :push_notification_config_delete
      "GetExtendedAgentCard" -> :get_extended_agent_card
      _ -> :unknown
    end
  end

  defp method_key(method, _version) do
    case method do
      "message/send" -> :send_message
      "message/stream" -> :stream_message
      "tasks/get" -> :get_task
      "tasks/list" -> :list_tasks
      "tasks/cancel" -> :cancel_task
      "tasks/resubscribe" -> :resubscribe
      "tasks/subscribe" -> :subscribe
      "tasks/pushNotificationConfig/set" -> :push_notification_config_set
      "tasks/pushNotificationConfig/get" -> :push_notification_config_get
      "tasks/pushNotificationConfig/list" -> :push_notification_config_list
      "tasks/pushNotificationConfig/delete" -> :push_notification_config_delete
      "agent/getExtendedCard" -> :get_extended_agent_card
      "agent/getAuthenticatedExtendedCard" -> :get_extended_agent_card
      _ -> :unknown
    end
  end

  defp extract_task_id(%{"name" => "tasks/" <> id}), do: id
  defp extract_task_id(%{"taskId" => id}), do: id
  defp extract_task_id(_), do: nil

  defp require_task_id(params) do
    case extract_task_id(params) do
      nil -> {:invalid_params, "Missing task id"}
      task_id -> {:ok, task_id}
    end
  end

  defp require_param(params, key, message) do
    case Map.get(params, key) do
      nil -> {:invalid_params, message}
      value -> {:ok, value}
    end
  end

  defp wrap_message_response(%A2A.Types.Task{} = task),
    do: %A2A.Types.SendMessageResponse{task: task}

  defp wrap_message_response(%A2A.Types.Message{} = message),
    do: %A2A.Types.SendMessageResponse{message: message}

  defp read_json(conn) do
    with :ok <- ensure_content_type(conn) do
      case read_body(conn) do
        {:ok, body, _conn} ->
          case Jason.decode(body) do
            {:ok, map} -> {:ok, map}
            {:error, _} -> {:error, jsonrpc_error(-32700, "Parse error")}
          end

        {:more, _body, _conn} ->
          {:error, jsonrpc_error(-32600, "Request too large")}
      end
    end
  end

  defp ensure_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value | _] ->
        if valid_content_type?(value) do
          :ok
        else
          {:error, A2A.Error.new(:content_type_not_supported, "Unsupported Content-Type")}
        end

      [] ->
        {:error, A2A.Error.new(:content_type_not_supported, "Missing Content-Type")}
    end
  end

  defp valid_content_type?(value) do
    value = String.downcase(value)

    String.starts_with?(value, "application/json") or
      String.starts_with?(value, "application/a2a+json")
  end

  defp send_json(conn, status, map, extensions) do
    conn
    |> A2A.Server.Headers.put_extensions(extensions)
    |> maybe_put_www_authenticate(map)
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(map))
  end

  defp send_stream(conn, %{id: id, payloads: payloads}, extensions) do
    conn = start_stream(conn, extensions)

    Enum.reduce(payloads, conn, fn payload, conn ->
      chunk_jsonrpc(conn, id, payload)
    end)
  end

  defp jsonrpc_stream_event(id, payload) do
    A2A.Server.SSE.encode_event(%{"jsonrpc" => "2.0", "id" => id, "result" => payload})
  end

  defp stream_jsonrpc(conn, id, opts, extensions, task_first, fun) do
    conn = start_stream(conn, extensions)
    stream = stream_state(conn, task_first)
    emit = fn event -> stream_emit(stream, id, stream_payload(event, opts)) end

    try do
      case run_stream(opts, fn -> fun.(emit) end) do
        {:ok, response} ->
          response_payload =
            if response == :subscribed, do: nil, else: stream_payload(response, opts)

          stream_finish(stream, id, response_payload, nil)

        {:error, error} ->
          stream_finish(stream, id, nil, error)
      end
    after
      stream_cleanup(stream)
    end
  end

  defp start_stream(conn, extensions) do
    conn
    |> A2A.Server.Headers.put_extensions(extensions)
    |> put_resp_content_type("text/event-stream")
    |> send_chunked(200)
  end

  defp stream_state(conn, task_first) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{conn: conn, buffer: [], task_first: task_first, task_sent: false}
      end)

    agent
  end

  defp stream_emit(stream, id, payload) do
    Agent.get_and_update(stream, fn state ->
      cond do
        state.task_first && !state.task_sent && task_payload?(payload) ->
          conn = chunk_jsonrpc(state.conn, id, payload)
          conn = flush_payloads(conn, id, state.buffer)
          {:ok, %{state | conn: conn, buffer: [], task_sent: true}}

        state.task_first && !state.task_sent ->
          {:ok, %{state | buffer: [payload | state.buffer]}}

        true ->
          conn = chunk_jsonrpc(state.conn, id, payload)
          {:ok, %{state | conn: conn, task_sent: state.task_sent || task_payload?(payload)}}
      end
    end)

    :telemetry.execute([:a2a, :stream, :event], %{count: 1}, stream_metadata(payload, :jsonrpc))
    :ok
  end

  defp stream_finish(stream, id, response_payload, error) do
    state = Agent.get(stream, & &1)
    conn = state.conn

    {conn, _task_sent} =
      cond do
        response_payload == nil ->
          {conn, state.task_sent}

        state.task_first && state.task_sent && task_payload?(response_payload) ->
          {conn, state.task_sent}

        true ->
          {chunk_jsonrpc(conn, id, response_payload),
           state.task_sent || task_payload?(response_payload)}
      end

    conn = flush_payloads(conn, id, state.buffer)
    conn = if error, do: chunk_jsonrpc_error(conn, id, error), else: conn
    stream_cleanup(stream)
    conn
  end

  defp stream_cleanup(stream) do
    try do
      Agent.stop(stream)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp task_payload?(payload) when is_map(payload) do
    Map.get(payload, "task") != nil
  end

  defp task_payload?(_), do: false

  defp flush_payloads(conn, id, payloads) do
    payloads
    |> Enum.reverse()
    |> Enum.reduce(conn, fn payload, conn -> chunk_jsonrpc(conn, id, payload) end)
  end

  defp run_request(opts, fun) do
    timeout = Map.get(opts, :request_timeout, :infinity)

    if timeout in [nil, :infinity] do
      fun.()
    else
      task = Task.async(fun)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, A2A.Error.new(:request_timeout, "Request timed out")}
      end
    end
  end

  defp run_stream(opts, fun) do
    timeout = Map.get(opts, :stream_timeout, :infinity)

    if timeout in [nil, :infinity] do
      fun.()
    else
      task = Task.async(fun)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, A2A.Error.new(:stream_timeout, "Stream timed out")}
      end
    end
  end

  defp chunk_jsonrpc(conn, id, payload) do
    event = jsonrpc_stream_event(id, payload)

    case chunk(conn, event) do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp chunk_jsonrpc_error(conn, id, %A2A.Error{} = error) do
    event = A2A.Server.SSE.encode_event(jsonrpc_error(-32000, error, id))

    case chunk(conn, event) do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp jsonrpc_error(code, %{"type" => _} = data) do
    %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => code, "message" => "Error", "data" => data}
    }
  end

  defp jsonrpc_error(code, message) do
    %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => code, "message" => message}}
  end

  defp jsonrpc_error(code, %A2A.Error{} = error, id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => error.message, "data" => A2A.Error.to_map(error)}
    }
  end

  defp jsonrpc_error(code, %{"type" => _} = data, id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => "Error", "data" => data}
    }
  end

  defp jsonrpc_error(code, error, id) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => inspect(error)}}
  end

  defp maybe_put_www_authenticate(conn, %{"error" => %{"data" => data}}) when is_map(data) do
    type = Map.get(data, "type") || Map.get(data, :type)
    nested = Map.get(data, "data") || Map.get(data, :data)

    if type == "UnauthorizedError" or type == :unauthorized do
      header =
        Map.get(data, "www_authenticate") ||
          Map.get(data, :www_authenticate) ||
          (is_map(nested) &&
             (Map.get(nested, "www_authenticate") || Map.get(nested, :www_authenticate))) ||
          "Bearer"

      Plug.Conn.put_resp_header(conn, "www-authenticate", header)
    else
      conn
    end
  end

  defp maybe_put_www_authenticate(conn, _map), do: conn

  defp ctx(conn, extensions) do
    %{
      identity: conn.assigns[:identity],
      request_id: A2A.Server.Headers.request_id(conn),
      extensions: extensions
    }
  end

  defp stream_payload(%A2A.Types.StreamResponse{} = response, opts) do
    A2A.Types.StreamResponse.to_map(response, version: opts.version)
  end

  defp stream_payload(%A2A.Types.Task{} = task, opts) do
    A2A.Types.StreamResponse.to_map(%A2A.Types.StreamResponse{task: task}, version: opts.version)
  end

  defp stream_payload(%A2A.Types.Message{} = message, opts) do
    A2A.Types.StreamResponse.to_map(%A2A.Types.StreamResponse{message: message},
      version: opts.version
    )
  end

  defp stream_payload(%A2A.Types.TaskStatusUpdateEvent{} = event, opts) do
    A2A.Types.StreamResponse.to_map(%A2A.Types.StreamResponse{status_update: event},
      version: opts.version
    )
  end

  defp stream_payload(%A2A.Types.TaskArtifactUpdateEvent{} = event, opts) do
    A2A.Types.StreamResponse.to_map(%A2A.Types.StreamResponse{artifact_update: event},
      version: opts.version
    )
  end

  defp stream_payload(payload, _opts) when is_map(payload), do: payload

  defp stream_metadata(event, transport) do
    base = %{transport: transport}

    case event do
      %{task_id: task_id, context_id: context_id} ->
        Map.merge(base, %{task_id: task_id, context_id: context_id})

      %{task_id: task_id} ->
        Map.merge(base, %{task_id: task_id})

      _ ->
        base
    end
  end

  defp decode_push_config(%{"config" => config}) when is_map(config) do
    A2A.Types.PushNotificationConfig.from_map(config)
  end

  defp decode_push_config(config) when is_map(config) do
    A2A.Types.PushNotificationConfig.from_map(config)
  end

  defp encode_push_config(%A2A.Types.PushNotificationConfig{} = config) do
    A2A.Types.PushNotificationConfig.to_map(config)
  end

  defp encode_push_config(config) when is_map(config), do: config

  defp ensure_capability(capabilities, :push_notifications) do
    if Map.get(capabilities, :push_notifications, false) do
      :ok
    else
      {:error,
       A2A.Error.new(:push_notification_not_supported, "Push notifications not supported")}
    end
  end

  defp ensure_capability(capabilities, :extended_agent_card) do
    if Map.get(capabilities, :extended_agent_card, false) do
      :ok
    else
      {:error, A2A.Error.new(:unsupported_operation, "Extended agent card not supported")}
    end
  end

  defp ensure_capability(capabilities, :streaming) do
    if Map.get(capabilities, :streaming, false) do
      :ok
    else
      {:error, A2A.Error.new(:unsupported_operation, "Streaming not supported")}
    end
  end

  defp ensure_handler(executor, fun, arity) do
    if A2A.Server.ExecutorRunner.exported?(executor, fun, arity) do
      :ok
    else
      {:error, A2A.Error.new(:unsupported_operation, "Handler #{fun} not available")}
    end
  end

  defp ensure_extensions(extensions, required) do
    missing = A2A.Extension.missing_required(extensions, required)

    if missing == [] do
      :ok
    else
      {:error,
       A2A.Error.new(
         :extension_support_required,
         "Missing required extensions: #{Enum.join(missing, ", ")}"
       )}
    end
  end

  defp wrap_task_store(executor, nil), do: executor
  defp wrap_task_store({A2A.Server.TaskStoreExecutor, _} = executor, _task_store), do: executor
  defp wrap_task_store(A2A.Server.TaskStoreExecutor = executor, _task_store), do: executor

  defp wrap_task_store(executor, task_store) do
    {A2A.Server.TaskStoreExecutor, %{executor: executor, task_store: task_store}}
  end
end
