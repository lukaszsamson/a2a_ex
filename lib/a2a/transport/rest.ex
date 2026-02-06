defmodule A2A.Transport.REST do
  @moduledoc """
  Client-side REST transport implementation.
  """

  @behaviour A2A.Transport

  @spec discover(A2A.Client.Config.t()) ::
          {:ok, A2A.Types.AgentCard.t()} | {:error, A2A.Error.t()}
  def discover(%A2A.Client.Config{} = config) do
    url = build_url(config.base_url, config.agent_card_path)

    with {:ok, resp} <- request(:get, url, config, nil),
         {:ok, body} <- decode_json_response(resp) do
      {:ok, A2A.Types.AgentCard.from_map(body)}
    else
      {:error, error} -> {:error, error}
    end
  end

  @spec send_message(A2A.Client.Config.t(), A2A.Types.SendMessageRequest.t()) ::
          {:ok, A2A.Types.Task.t() | A2A.Types.Message.t()} | {:error, A2A.Error.t()}
  def send_message(%A2A.Client.Config{} = config, %A2A.Types.SendMessageRequest{} = request) do
    url = build_url(config.base_url, base_path(config) <> "/message:send")

    body =
      A2A.Types.SendMessageRequest.to_map(request,
        version: config.version,
        wire_format: config.wire_format
      )

    with {:ok, resp} <- request(:post, url, config, body),
         {:ok, body} <- decode_json_response(resp),
         response <-
           A2A.Types.SendMessageResponse.from_map(body,
             version: config.version,
             wire_format: config.wire_format
           ) do
      {:ok, response.task || response.message}
    else
      {:error, error} -> {:error, error}
    end
  end

  @spec stream_message(A2A.Client.Config.t(), A2A.Types.SendMessageRequest.t()) ::
          {:ok, A2A.Client.Stream.t()} | {:error, A2A.Error.t()}
  def stream_message(%A2A.Client.Config{} = config, %A2A.Types.SendMessageRequest{} = request) do
    url = build_url(config.base_url, base_path(config) <> "/message:stream")

    body =
      A2A.Types.SendMessageRequest.to_map(request,
        version: config.version,
        wire_format: config.wire_format
      )

    stream_request(config, :post, url, body)
  end

  @spec get_task(A2A.Client.Config.t(), String.t(), keyword() | map()) ::
          {:ok, A2A.Types.Task.t()} | {:error, A2A.Error.t()}
  def get_task(%A2A.Client.Config{} = config, task_id, opts) do
    query = build_query(opts)
    url = build_url(config.base_url, base_path(config) <> "/tasks/#{task_id}" <> query)

    with {:ok, resp} <- request(:get, url, config, nil),
         {:ok, body} <- decode_json_response(resp) do
      {:ok,
       A2A.Types.Task.from_map(body, version: config.version, wire_format: config.wire_format)}
    else
      {:error, error} -> {:error, error}
    end
  end

  @spec list_tasks(A2A.Client.Config.t(), A2A.Types.ListTasksRequest.t()) ::
          {:ok, A2A.Types.ListTasksResponse.t()} | {:error, A2A.Error.t()}
  def list_tasks(%A2A.Client.Config{} = config, %A2A.Types.ListTasksRequest{} = request) do
    query = A2A.Types.ListTasksRequest.to_map(request, version: config.version)
    url = build_url(config.base_url, base_path(config) <> "/tasks" <> encode_query(query))

    with {:ok, resp} <- request(:get, url, config, nil),
         {:ok, body} <- decode_json_response(resp) do
      {:ok,
       A2A.Types.ListTasksResponse.from_map(body,
         version: config.version,
         wire_format: config.wire_format
       )}
    else
      {:error, error} -> {:error, error}
    end
  end

  @spec cancel_task(A2A.Client.Config.t(), String.t()) ::
          {:ok, A2A.Types.Task.t()} | {:error, A2A.Error.t()}
  def cancel_task(%A2A.Client.Config{} = config, task_id) do
    url = build_url(config.base_url, base_path(config) <> "/tasks/#{task_id}:cancel")

    with {:ok, resp} <- request(:post, url, config, %{}),
         {:ok, body} <- decode_json_response(resp) do
      {:ok,
       A2A.Types.Task.from_map(body, version: config.version, wire_format: config.wire_format)}
    else
      {:error, error} -> {:error, error}
    end
  end

  @spec resubscribe(A2A.Client.Config.t(), String.t(), map()) ::
          {:ok, A2A.Client.Stream.t()} | {:error, A2A.Error.t()}
  def resubscribe(%A2A.Client.Config{} = config, task_id, resume) do
    url = build_url(config.base_url, base_path(config) <> "/tasks/#{task_id}:subscribe")
    body = if subscribe_method(config) == :get, do: nil, else: %{resume: resume}

    headers = resume_headers(resume)
    stream_request(config, subscribe_method(config), url, body, headers)
  end

  @spec subscribe(A2A.Client.Config.t(), String.t()) ::
          {:ok, A2A.Client.Stream.t()} | {:error, A2A.Error.t()}
  def subscribe(%A2A.Client.Config{} = config, task_id) do
    url = build_url(config.base_url, base_path(config) <> "/tasks/#{task_id}:subscribe")

    body = if subscribe_method(config) == :get, do: nil, else: %{}

    stream_request(config, subscribe_method(config), url, body)
  end

  @spec push_notification_config_set(
          A2A.Client.Config.t(),
          String.t(),
          A2A.Types.PushNotificationConfig.t() | map()
        ) :: {:ok, A2A.Types.PushNotificationConfig.t()} | {:error, A2A.Error.t()}
  def push_notification_config_set(%A2A.Client.Config{} = config, task_id, request) do
    url =
      build_url(config.base_url, base_path(config) <> "/tasks/#{task_id}/pushNotificationConfigs")

    body = A2A.Types.PushNotificationConfig.to_map(request)

    with {:ok, resp} <- request(:post, url, config, body),
         {:ok, body} <- decode_json_response(resp) do
      {:ok, A2A.Types.PushNotificationConfig.from_map(body)}
    else
      {:error, error} -> {:error, error}
    end
  end

  @spec push_notification_config_get(A2A.Client.Config.t(), String.t(), String.t()) ::
          {:ok, A2A.Types.PushNotificationConfig.t()} | {:error, A2A.Error.t()}
  def push_notification_config_get(%A2A.Client.Config{} = config, task_id, config_id) do
    url =
      build_url(
        config.base_url,
        base_path(config) <> "/tasks/#{task_id}/pushNotificationConfigs/#{config_id}"
      )

    with {:ok, resp} <- request(:get, url, config, nil),
         {:ok, body} <- decode_json_response(resp) do
      {:ok, A2A.Types.PushNotificationConfig.from_map(body)}
    else
      {:error, error} -> {:error, error}
    end
  end

  @spec push_notification_config_list(A2A.Client.Config.t(), String.t(), map() | keyword()) ::
          {:ok, list(A2A.Types.PushNotificationConfig.t())} | {:error, A2A.Error.t()}
  def push_notification_config_list(%A2A.Client.Config{} = config, task_id, query) do
    url =
      build_url(
        config.base_url,
        base_path(config) <> "/tasks/#{task_id}/pushNotificationConfigs" <> encode_query(query)
      )

    with {:ok, resp} <- request(:get, url, config, nil),
         {:ok, body} <- decode_json_response(resp) do
      {:ok, decode_push_config_list(body)}
    else
      {:error, error} -> {:error, error}
    end
  end

  @spec push_notification_config_delete(A2A.Client.Config.t(), String.t(), String.t()) ::
          :ok | {:error, A2A.Error.t()}
  def push_notification_config_delete(%A2A.Client.Config{} = config, task_id, config_id) do
    url =
      build_url(
        config.base_url,
        base_path(config) <> "/tasks/#{task_id}/pushNotificationConfigs/#{config_id}"
      )

    case request(:delete, url, config, nil) do
      {:ok, _resp} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @spec get_extended_agent_card(A2A.Client.Config.t()) ::
          {:ok, A2A.Types.AgentCard.t()} | {:error, A2A.Error.t()}
  def get_extended_agent_card(%A2A.Client.Config{} = config) do
    if config.version == :latest do
      url = build_url(config.base_url, base_path(config) <> "/extendedAgentCard")

      with {:ok, resp} <- request(:get, url, config, nil),
           {:ok, body} <- decode_json_response(resp) do
        {:ok, A2A.Types.AgentCard.from_map(body)}
      else
        {:error, error} -> {:error, error}
      end
    else
      {:error, A2A.Error.new(:unsupported_operation, "Extended agent card not supported")}
    end
  end

  defp request(method, url, %A2A.Client.Config{} = config, body) do
    payload = if body == nil, do: nil, else: Jason.encode!(body)
    headers = A2A.Client.Config.request_headers(config) |> ensure_content_type(payload)
    metadata = %{transport: :rest, method: method, url: url, wire_format: config.wire_format}

    A2A.Telemetry.span([:a2a, :client, :request], metadata, fn ->
      req_opts =
        config.req_options
        |> Keyword.put_new(:receive_timeout, 30_000)
        |> Keyword.merge(method: method, url: url, headers: headers, body: payload)

      resp = Req.request(req_opts)

      case resp do
        {:ok, %{status: status} = response} when status in 200..299 ->
          {:ok, response}

        {:ok, %{status: status} = response} ->
          error = error_from_response(status, response.body)
          {:error, attach_raw(error, raw_from_response(response))}

        {:error, reason} ->
          {:error, A2A.Error.new(:transport_error, inspect(reason))}
      end
    end)
  end

  defp ensure_content_type(headers, nil), do: headers

  defp ensure_content_type(headers, _payload) do
    if Enum.any?(headers, fn {key, _} -> String.downcase(key) == "content-type" end) do
      headers
    else
      headers ++ [{"content-type", "application/json"}]
    end
  end

  defp decode_json(body) when is_map(body), do: {:ok, body}

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, A2A.Error.new(:invalid_agent_response, "Invalid JSON response")}
    end
  end

  defp decode_json(_body), do: {:error, A2A.Error.new(:invalid_agent_response, "Invalid JSON")}

  defp decode_json_response(%{body: body} = response) do
    case decode_json(body) do
      {:ok, map} -> {:ok, map}
      {:error, error} -> {:error, attach_raw(error, raw_from_response(response))}
    end
  end

  defp stream_request(%A2A.Client.Config{} = config, method, url, body, extra_headers \\ []) do
    payload = if body == nil, do: nil, else: Jason.encode!(body)
    headers = A2A.Client.Config.request_headers(config) |> ensure_content_type(payload)
    headers = headers ++ extra_headers
    headers = ensure_accept(headers)
    metadata = %{transport: :rest, method: method, url: url, wire_format: config.wire_format}

    A2A.Telemetry.span([:a2a, :client, :request], metadata, fn ->
      req_opts =
        config.req_options
        |> Keyword.put_new(:receive_timeout, 30_000)
        |> Keyword.merge(
          method: method,
          url: url,
          headers: headers,
          body: payload,
          into: :self,
          decode_body: false
        )

      case Req.request(req_opts) do
        {:ok, %{status: status, body: %Req.Response.Async{} = async}} when status in 200..299 ->
          stream =
            async
            |> A2A.Transport.SSE.stream_events()
            |> Stream.map(&decode_stream_event(&1, config))

          {:ok, A2A.Client.Stream.new(stream, fn -> cancel_async(async) end)}

        {:ok, %{status: status, body: %Req.Response.Async{} = async} = response} ->
          cancel_async(async)
          error = A2A.Error.new(:http_error, "HTTP #{status}")
          {:error, attach_raw(error, raw_from_response(response))}

        {:ok, %{status: status} = response} ->
          error = A2A.Error.new(:http_error, "HTTP #{status}")
          {:error, attach_raw(error, raw_from_response(response))}

        {:error, reason} ->
          {:error, A2A.Error.new(:transport_error, inspect(reason))}
      end
    end)
  end

  defp ensure_accept(headers) do
    if Enum.any?(headers, fn {key, _} -> String.downcase(key) == "accept" end) do
      headers
    else
      headers ++ [{"accept", "text/event-stream"}]
    end
  end

  defp cancel_async(%Req.Response.Async{cancel_fun: cancel_fun, ref: ref})
       when is_function(cancel_fun, 1) do
    cancel_fun.(ref)
  end

  defp cancel_async(_), do: :ok

  defp resume_headers(resume) do
    case resume_cursor(resume) do
      nil -> []
      cursor -> [{"last-event-id", to_string(cursor)}]
    end
  end

  defp resume_cursor(%{} = resume) do
    Map.get(resume, "cursor") ||
      Map.get(resume, :cursor) ||
      Map.get(resume, "lastEventId") ||
      Map.get(resume, :last_event_id) ||
      Map.get(resume, "last_event_id")
  end

  defp resume_cursor(_), do: nil

  defp decode_push_config_list(%{"pushNotificationConfigs" => configs}) when is_list(configs) do
    Enum.map(configs, &A2A.Types.PushNotificationConfig.from_map/1)
  end

  defp decode_push_config_list(%{"configs" => configs}) when is_list(configs) do
    Enum.map(configs, &A2A.Types.PushNotificationConfig.from_map/1)
  end

  defp decode_push_config_list(configs) when is_list(configs) do
    Enum.map(configs, &A2A.Types.PushNotificationConfig.from_map/1)
  end

  defp decode_push_config_list(_), do: []

  defp error_from_response(status, body) do
    case decode_json(body) do
      {:ok, %{"error" => error_map}} -> A2A.Error.from_map(error_map)
      {:ok, %{"type" => _} = error_map} -> A2A.Error.from_map(error_map)
      _ -> A2A.Error.new(:http_error, "HTTP #{status}")
    end
  end

  defp decode_stream_event(data, config) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, payload} ->
        decode_stream_payload(payload, config)

      {:error, _} ->
        %A2A.Types.StreamError{
          error: A2A.Error.new(:invalid_agent_response, "Invalid stream payload")
        }
    end
  end

  defp decode_stream_payload(%{"error" => error}, _config) when is_map(error) do
    %A2A.Types.StreamError{error: A2A.Error.from_map(error), raw: error}
  end

  defp decode_stream_payload(payload, config) when is_map(payload) do
    A2A.Types.StreamResponse.from_map(payload,
      version: config.version,
      wire_format: config.wire_format
    )
  end

  defp attach_raw(%A2A.Error{} = error, raw), do: %{error | raw: raw}

  defp raw_from_response(response) do
    %{status: response.status, headers: response.headers, body: response.body}
  end

  defp base_path(%A2A.Client.Config{rest_base_path: base_path}) when base_path in ["", nil],
    do: ""

  defp base_path(%A2A.Client.Config{rest_base_path: base_path}), do: base_path

  defp build_url(base, path) do
    URI.merge(base, path) |> to_string()
  end

  defp subscribe_method(%A2A.Client.Config{subscribe_verb: :get}), do: :get
  defp subscribe_method(_config), do: :post

  defp build_query(opts) do
    opts
    |> Keyword.take([:history_length])
    |> Map.new(fn {key, value} -> {to_lower_camel(key), value} end)
    |> encode_query()
  end

  defp to_lower_camel(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> to_lower_camel()
  end

  defp to_lower_camel(value) when is_binary(value) do
    value
    |> Macro.camelize()
    |> then(fn
      <<first::utf8, rest::binary>> -> String.downcase(<<first::utf8>>) <> rest
      _ -> value
    end)
  end

  defp encode_query(map) when map == %{}, do: ""

  defp encode_query(map) do
    "?" <> URI.encode_query(map)
  end
end
