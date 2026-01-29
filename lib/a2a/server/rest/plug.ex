defmodule A2A.Server.REST.Plug do
  @moduledoc """
  Plug implementation for the A2A REST transport.
  """

  import Plug.Conn

  @spec init(keyword()) :: map()
  def init(opts) do
    executor = wrap_task_store(Keyword.fetch!(opts, :executor), Keyword.get(opts, :task_store))

    %{executor: executor, version: Keyword.get(opts, :version, :v0_3)}
    |> Map.put(:base_path, Keyword.get(opts, :base_path, default_base_path(opts)))
    |> Map.put(:capabilities, Keyword.get(opts, :capabilities, %{}))
    |> Map.put(:required_extensions, Keyword.get(opts, :required_extensions, []))
    |> Map.put(:subscribe_verb, Keyword.get(opts, :subscribe_verb, :post))
    |> Map.put(:stream_timeout, Keyword.get(opts, :stream_timeout, :infinity))
    |> Map.put(:request_timeout, Keyword.get(opts, :request_timeout, :infinity))
    |> Map.put(:stream_task_first, Keyword.get(opts, :stream_task_first, true))
  end

  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, opts) do
    conn = fetch_query_params(conn)
    conn = A2A.Server.Headers.ensure_request_id(conn)
    extensions = A2A.Server.Headers.extensions(conn)

    with :ok <- A2A.Server.Headers.validate_version(conn, opts.version),
         :ok <- ensure_extensions(extensions, opts.required_extensions) do
      metadata = %{transport: :rest, method: conn.method, path: conn.request_path}

      A2A.Telemetry.span([:a2a, :server, :request], metadata, fn ->
        dispatch(conn, opts, extensions)
      end)
    else
      {:error, error} -> send_error(conn, error, extensions)
    end
  end

  defp dispatch(conn, opts, extensions) do
    base_segments = base_segments(opts.base_path)

    case strip_base(conn.path_info, base_segments) do
      {:ok, path} ->
        case {conn.method, path} do
          {"POST", ["message:send"]} ->
            handle_send_message(conn, opts, extensions)

          {"POST", ["message:stream"]} ->
            handle_stream_message(conn, opts, extensions)

          {"GET", ["tasks"]} ->
            handle_list_tasks(conn, opts, extensions)

          {"GET", ["tasks", segment]} ->
            if String.contains?(segment, ":") do
              handle_task_action(conn, opts, segment, extensions, :get)
            else
              handle_get_task(conn, opts, segment, extensions)
            end

          {"POST", ["tasks", segment]} ->
            handle_task_action(conn, opts, segment, extensions, :post)

          {"POST", ["tasks", task_id, "pushNotificationConfigs"]} ->
            handle_push_config_set(conn, opts, task_id, extensions)

          {"GET", ["tasks", task_id, "pushNotificationConfigs"]} ->
            handle_push_config_list(conn, opts, task_id, extensions)

          {"GET", ["tasks", task_id, "pushNotificationConfigs", config_id]} ->
            handle_push_config_get(conn, opts, task_id, config_id, extensions)

          {"DELETE", ["tasks", task_id, "pushNotificationConfigs", config_id]} ->
            handle_push_config_delete(conn, opts, task_id, config_id, extensions)

          {"GET", ["extendedAgentCard"]} ->
            handle_extended_agent_card(conn, opts, extensions)

          _ ->
            send_resp(conn, 404, "")
        end

      :error ->
        send_resp(conn, 404, "")
    end
  end

  defp handle_send_message(conn, opts, extensions) do
    with {:ok, body} <- read_json(conn),
         request <- A2A.Types.SendMessageRequest.from_map(body, version: opts.version),
         {:ok, response} <-
           run_request(opts, fn ->
             A2A.Server.ExecutorRunner.call(opts.executor, :handle_send_message, [
               request,
               ctx(conn, extensions)
             ])
           end) do
      send_json(conn, 200, wrap_message_response(response, opts), extensions)
    else
      {:error, error} -> send_error(conn, error, extensions)
      _ -> send_error(conn, A2A.Error.new(:invalid_agent_response, "Invalid request"), extensions)
    end
  end

  defp handle_stream_message(conn, opts, extensions) do
    with :ok <- ensure_capability(opts.capabilities, :streaming),
         :ok <- ensure_handler(opts.executor, :handle_stream_message, 3),
         {:ok, body} <- read_json(conn),
         request <- A2A.Types.SendMessageRequest.from_map(body, version: opts.version) do
      conn = start_stream(conn, extensions)
      stream = stream_state(conn, opts.stream_task_first)
      emit = fn event -> stream_emit(stream, event, opts) end

      try do
        case run_stream(opts, fn ->
               A2A.Server.ExecutorRunner.call(opts.executor, :handle_stream_message, [
                 request,
                 ctx(conn, extensions),
                 emit
               ])
             end) do
          {:ok, response} ->
            stream_finish(stream, opts, response, nil)

          {:error, error} ->
            stream_finish(stream, opts, nil, error)
        end
      after
        stream_cleanup(stream)
      end
    else
      {:error, error} -> send_error(conn, error, extensions)
    end
  end

  defp handle_get_task(conn, opts, task_id, extensions) do
    with {:ok, response} <-
           run_request(opts, fn ->
             A2A.Server.ExecutorRunner.call(opts.executor, :handle_get_task, [
               task_id,
               query_opts(conn),
               ctx(conn, extensions)
             ])
           end) do
      send_json(conn, 200, A2A.Types.Task.to_map(response, version: opts.version), extensions)
    else
      {:error, error} -> send_error(conn, error, extensions)
    end
  end

  defp handle_list_tasks(conn, opts, extensions) do
    request = A2A.Types.ListTasksRequest.from_map(conn.query_params, version: opts.version)

    with {:ok, response} <-
           run_request(opts, fn ->
             A2A.Server.ExecutorRunner.call(opts.executor, :handle_list_tasks, [
               request,
               ctx(conn, extensions)
             ])
           end) do
      send_json(
        conn,
        200,
        A2A.Types.ListTasksResponse.to_map(response, version: opts.version),
        extensions
      )
    else
      {:error, error} -> send_error(conn, error, extensions)
    end
  end

  defp handle_task_action(conn, opts, segment, extensions, method) do
    case String.split(segment, ":") do
      [task_id, "cancel"] ->
        if method == :post do
          with {:ok, response} <-
                 run_request(opts, fn ->
                   A2A.Server.ExecutorRunner.call(opts.executor, :handle_cancel_task, [
                     task_id,
                     ctx(conn, extensions)
                   ])
                 end) do
            send_json(
              conn,
              200,
              A2A.Types.Task.to_map(response, version: opts.version),
              extensions
            )
          else
            {:error, error} -> send_error(conn, error, extensions)
          end
        else
          send_resp(conn, 404, "")
        end

      [task_id, "subscribe"] ->
        if subscribe_allowed?(opts.subscribe_verb, method) do
          with :ok <- ensure_capability(opts.capabilities, :streaming),
               :ok <- ensure_handler(opts.executor, :handle_subscribe, 3) do
            conn = start_stream(conn, extensions)
            stream = stream_state(conn, false)
            emit = fn event -> stream_emit(stream, event, opts) end

            try do
              case run_stream(opts, fn ->
                     A2A.Server.ExecutorRunner.call(opts.executor, :handle_subscribe, [
                       task_id,
                       ctx(conn, extensions),
                       emit
                     ])
                   end) do
                {:ok, :subscribed} ->
                  stream_finish(stream, opts, nil, nil)

                {:error, error} ->
                  stream_finish(stream, opts, nil, error)
              end
            after
              stream_cleanup(stream)
            end
          else
            {:error, error} -> send_error(conn, error, extensions)
          end
        else
          send_resp(conn, 404, "")
        end

      _ ->
        send_resp(conn, 404, "")
    end
  end

  defp handle_push_config_set(conn, opts, task_id, extensions) do
    with :ok <- ensure_capability(opts.capabilities, :push_notifications),
         {:ok, body} <- read_json(conn),
         config <- A2A.Types.PushNotificationConfig.from_map(body),
         {:ok, response} <-
           run_request(opts, fn ->
             A2A.Server.ExecutorRunner.call(opts.executor, :handle_push_notification_config_set, [
               task_id,
               config,
               ctx(conn, extensions)
             ])
           end) do
      send_json(conn, 200, encode_push_config(response), extensions)
    else
      {:error, error} -> send_error(conn, error, extensions)
    end
  end

  defp handle_push_config_get(conn, opts, task_id, config_id, extensions) do
    with :ok <- ensure_capability(opts.capabilities, :push_notifications),
         {:ok, response} <-
           run_request(opts, fn ->
             A2A.Server.ExecutorRunner.call(opts.executor, :handle_push_notification_config_get, [
               task_id,
               config_id,
               ctx(conn, extensions)
             ])
           end) do
      send_json(conn, 200, encode_push_config(response), extensions)
    else
      {:error, error} -> send_error(conn, error, extensions)
    end
  end

  defp handle_push_config_list(conn, opts, task_id, extensions) do
    with :ok <- ensure_capability(opts.capabilities, :push_notifications),
         {:ok, response} <-
           run_request(opts, fn ->
             A2A.Server.ExecutorRunner.call(
               opts.executor,
               :handle_push_notification_config_list,
               [
                 task_id,
                 conn.query_params,
                 ctx(conn, extensions)
               ]
             )
           end) do
      send_json(
        conn,
        200,
        %{"pushNotificationConfigs" => Enum.map(response, &encode_push_config/1)},
        extensions
      )
    else
      {:error, error} -> send_error(conn, error, extensions)
    end
  end

  defp handle_push_config_delete(conn, opts, task_id, config_id, extensions) do
    with :ok <- ensure_capability(opts.capabilities, :push_notifications),
         :ok <-
           run_request(opts, fn ->
             A2A.Server.ExecutorRunner.call(
               opts.executor,
               :handle_push_notification_config_delete,
               [task_id, config_id, ctx(conn, extensions)]
             )
           end) do
      conn
      |> A2A.Server.Headers.put_extensions(extensions)
      |> send_resp(204, "")
    else
      {:error, error} -> send_error(conn, error, extensions)
    end
  end

  defp handle_extended_agent_card(conn, opts, extensions) do
    with :ok <- ensure_latest(opts.version),
         :ok <- ensure_capability(opts.capabilities, :extended_agent_card),
         {:ok, card} <-
           run_request(opts, fn ->
             A2A.Server.ExecutorRunner.call(opts.executor, :handle_get_extended_agent_card, [
               ctx(conn, extensions)
             ])
           end) do
      send_json(conn, 200, A2A.Types.AgentCard.to_map(card, version: opts.version), extensions)
    else
      {:error, error} -> send_error(conn, error, extensions)
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

  defp stream_emit(stream, event, opts) do
    Agent.get_and_update(stream, fn state ->
      cond do
        state.task_first && !state.task_sent && task_event?(event) ->
          conn = chunk_struct(state.conn, event, opts)
          conn = flush_buffer(conn, state.buffer, opts)
          {:ok, %{state | conn: conn, buffer: [], task_sent: true}}

        state.task_first && !state.task_sent ->
          {:ok, %{state | buffer: [event | state.buffer]}}

        true ->
          conn = chunk_struct(state.conn, event, opts)
          {:ok, %{state | conn: conn, task_sent: state.task_sent || task_event?(event)}}
      end
    end)

    :telemetry.execute([:a2a, :stream, :event], %{count: 1}, stream_metadata(event, :rest))
    :ok
  end

  defp stream_finish(stream, opts, response, error) do
    state = Agent.get(stream, & &1)
    conn = state.conn

    {conn, _task_sent} =
      cond do
        response == nil ->
          {conn, state.task_sent}

        state.task_first && state.task_sent && task_event?(response) ->
          {conn, state.task_sent}

        true ->
          conn = maybe_chunk_response(conn, response, opts)
          {conn, state.task_sent || task_event?(response)}
      end

    conn = flush_buffer(conn, state.buffer, opts)
    conn = if error, do: chunk_error(conn, error), else: conn

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

  defp maybe_chunk_response(conn, nil, _opts), do: conn
  defp maybe_chunk_response(conn, response, opts), do: chunk_struct(conn, response, opts)

  defp chunk_struct(conn, struct, opts) do
    payload = A2A.Server.SSE.encode_struct(wrap_stream(struct), version: opts.version)

    case chunk(conn, payload) do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp chunk_error(conn, %A2A.Error{} = error) do
    payload = A2A.Server.SSE.encode_event(%{"error" => A2A.Error.to_map(error)})

    case chunk(conn, payload) do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp wrap_stream(%A2A.Types.StreamResponse{} = response), do: response
  defp wrap_stream(%A2A.Types.Task{} = task), do: %A2A.Types.StreamResponse{task: task}

  defp wrap_stream(%A2A.Types.Message{} = message),
    do: %A2A.Types.StreamResponse{message: message}

  defp wrap_stream(%A2A.Types.TaskStatusUpdateEvent{} = event) do
    %A2A.Types.StreamResponse{status_update: event}
  end

  defp wrap_stream(%A2A.Types.TaskArtifactUpdateEvent{} = event) do
    %A2A.Types.StreamResponse{artifact_update: event}
  end

  defp wrap_stream(map) when is_map(map), do: map

  defp task_event?(%A2A.Types.Task{}), do: true
  defp task_event?(%A2A.Types.StreamResponse{task: %A2A.Types.Task{}}), do: true
  defp task_event?(_), do: false

  defp flush_buffer(conn, buffer, opts) do
    buffer
    |> Enum.reverse()
    |> Enum.reduce(conn, fn event, conn -> chunk_struct(conn, event, opts) end)
  end

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

  defp wrap_message_response(%A2A.Types.Task{} = task, opts) do
    A2A.Types.SendMessageResponse.to_map(%A2A.Types.SendMessageResponse{task: task},
      version: opts.version
    )
  end

  defp wrap_message_response(%A2A.Types.Message{} = message, opts) do
    A2A.Types.SendMessageResponse.to_map(%A2A.Types.SendMessageResponse{message: message},
      version: opts.version
    )
  end

  defp read_json(conn) do
    with :ok <- ensure_content_type(conn) do
      case read_body(conn) do
        {:ok, body, _conn} ->
          case Jason.decode(body) do
            {:ok, map} -> {:ok, map}
            {:error, _} -> {:error, A2A.Error.new(:invalid_agent_response, "Invalid JSON")}
          end

        {:more, _body, _conn} ->
          {:error, A2A.Error.new(:invalid_agent_response, "Request too large")}
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
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(map))
  end

  defp send_error(conn, %A2A.Error{} = error, extensions) do
    conn = maybe_put_www_authenticate(conn, error)

    send_json(
      conn,
      A2A.Error.http_status(error),
      %{"error" => A2A.Error.to_map(error)},
      extensions
    )
  end

  defp maybe_put_www_authenticate(conn, %A2A.Error{type: :unauthorized, data: data}) do
    header =
      case data do
        %{"www_authenticate" => value} -> value
        %{www_authenticate: value} -> value
        _ -> "Bearer"
      end

    Plug.Conn.put_resp_header(conn, "www-authenticate", header)
  end

  defp maybe_put_www_authenticate(conn, _error), do: conn

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

  defp subscribe_allowed?(:both, _method), do: true
  defp subscribe_allowed?(:post, :post), do: true
  defp subscribe_allowed?(:get, :get), do: true
  defp subscribe_allowed?(_, _), do: false

  defp ensure_latest(:latest), do: :ok

  defp ensure_latest(_),
    do: {:error, A2A.Error.new(:unsupported_operation, "Extended agent card not supported")}

  defp encode_push_config(%A2A.Types.PushNotificationConfig{} = config) do
    A2A.Types.PushNotificationConfig.to_map(config)
  end

  defp encode_push_config(config) when is_map(config), do: config

  defp ctx(conn, extensions) do
    %{
      identity: conn.assigns[:identity],
      request_id: A2A.Server.Headers.request_id(conn),
      extensions: extensions
    }
  end

  defp query_opts(conn) do
    conn.query_params
  end

  defp default_base_path(opts) do
    case Keyword.get(opts, :version, :v0_3) do
      :latest -> ""
      _ -> "/v1"
    end
  end

  defp base_segments(""), do: []
  defp base_segments("/"), do: []
  defp base_segments(base_path), do: String.split(String.trim(base_path, "/"), "/")

  defp strip_base(path_info, []), do: {:ok, path_info}

  defp strip_base(path_info, base_segments) do
    {prefix, rest} = Enum.split(path_info, length(base_segments))

    if prefix == base_segments do
      {:ok, rest}
    else
      :error
    end
  end

  defp wrap_task_store(executor, nil), do: executor
  defp wrap_task_store({A2A.Server.TaskStoreExecutor, _} = executor, _task_store), do: executor
  defp wrap_task_store(A2A.Server.TaskStoreExecutor = executor, _task_store), do: executor

  defp wrap_task_store(executor, task_store) do
    {A2A.Server.TaskStoreExecutor, %{executor: executor, task_store: task_store}}
  end
end
