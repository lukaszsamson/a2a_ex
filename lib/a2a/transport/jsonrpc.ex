defmodule A2A.Transport.JSONRPC do
  @moduledoc """
  Client-side JSON-RPC transport implementation.
  """

  @behaviour A2A.Transport

  @spec discover(A2A.Client.Config.t()) ::
          {:ok, A2A.Types.AgentCard.t()} | {:error, A2A.Error.t()}
  def discover(config), do: A2A.Transport.REST.discover(config)

  @spec send_message(A2A.Client.Config.t(), A2A.Types.SendMessageRequest.t()) ::
          {:ok, A2A.Types.Task.t() | A2A.Types.Message.t()} | {:error, A2A.Error.t()}
  def send_message(%A2A.Client.Config{} = config, %A2A.Types.SendMessageRequest{} = request) do
    call(
      config,
      :send_message,
      A2A.Types.SendMessageRequest.to_map(request, version: config.version),
      fn result ->
        response = A2A.Types.SendMessageResponse.from_map(result, version: config.version)
        {:ok, response.task || response.message}
      end
    )
  end

  @spec stream_message(A2A.Client.Config.t(), A2A.Types.SendMessageRequest.t()) ::
          {:ok, A2A.Client.Stream.t()} | {:error, A2A.Error.t()}
  def stream_message(%A2A.Client.Config{} = config, %A2A.Types.SendMessageRequest{} = request) do
    stream_request(
      config,
      :stream_message,
      A2A.Types.SendMessageRequest.to_map(request, version: config.version)
    )
  end

  @spec get_task(A2A.Client.Config.t(), String.t(), keyword() | map()) ::
          {:ok, A2A.Types.Task.t()} | {:error, A2A.Error.t()}
  def get_task(%A2A.Client.Config{} = config, task_id, _opts) do
    call(config, :get_task, %{"name" => "tasks/#{task_id}"}, fn result ->
      {:ok, A2A.Types.Task.from_map(result, version: config.version)}
    end)
  end

  @spec list_tasks(A2A.Client.Config.t(), A2A.Types.ListTasksRequest.t()) ::
          {:ok, A2A.Types.ListTasksResponse.t()} | {:error, A2A.Error.t()}
  def list_tasks(%A2A.Client.Config{} = config, %A2A.Types.ListTasksRequest{} = request) do
    call(
      config,
      :list_tasks,
      A2A.Types.ListTasksRequest.to_map(request, version: config.version),
      fn result ->
        {:ok, A2A.Types.ListTasksResponse.from_map(result, version: config.version)}
      end
    )
  end

  @spec cancel_task(A2A.Client.Config.t(), String.t()) ::
          {:ok, A2A.Types.Task.t()} | {:error, A2A.Error.t()}
  def cancel_task(%A2A.Client.Config{} = config, task_id) do
    call(config, :cancel_task, %{"name" => "tasks/#{task_id}"}, fn result ->
      {:ok, A2A.Types.Task.from_map(result, version: config.version)}
    end)
  end

  @spec resubscribe(A2A.Client.Config.t(), String.t(), map()) ::
          {:ok, A2A.Client.Stream.t()} | {:error, A2A.Error.t()}
  def resubscribe(%A2A.Client.Config{} = config, task_id, resume) do
    stream_request(config, :resubscribe, %{"taskId" => task_id, "resume" => resume})
  end

  @spec subscribe(A2A.Client.Config.t(), String.t()) ::
          {:ok, A2A.Client.Stream.t()} | {:error, A2A.Error.t()}
  def subscribe(%A2A.Client.Config{} = config, task_id) do
    stream_request(config, :subscribe, %{"taskId" => task_id})
  end

  defp stream_request(config, method_key, params) do
    method_name = method_name(method_key, config.version)

    payload = %{
      "jsonrpc" => "2.0",
      "id" => unique_id(),
      "method" => method_name,
      "params" => params
    }

    url = build_url(config.base_url, "")
    headers = A2A.Client.Config.request_headers(config) |> ensure_content_type()
    headers = ensure_accept(headers)
    metadata = %{transport: :jsonrpc, method: method_name, url: url}

    A2A.Telemetry.span([:a2a, :client, :request], metadata, fn ->
      req_opts =
        config.req_options
        |> Keyword.put_new(:receive_timeout, 30_000)
        |> Keyword.merge(
          method: :post,
          url: url,
          headers: headers,
          body: Jason.encode!(payload),
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

  @spec push_notification_config_set(
          A2A.Client.Config.t(),
          String.t(),
          A2A.Types.PushNotificationConfig.t() | map()
        ) :: {:ok, A2A.Types.PushNotificationConfig.t()} | {:error, A2A.Error.t()}
  def push_notification_config_set(%A2A.Client.Config{} = config, task_id, request) do
    params = %{
      "taskId" => task_id,
      "config" => A2A.Types.PushNotificationConfig.to_map(request)
    }

    call(config, :push_notification_config_set, params, fn result ->
      {:ok, A2A.Types.PushNotificationConfig.from_map(result)}
    end)
  end

  @spec push_notification_config_get(A2A.Client.Config.t(), String.t(), String.t()) ::
          {:ok, A2A.Types.PushNotificationConfig.t()} | {:error, A2A.Error.t()}
  def push_notification_config_get(%A2A.Client.Config{} = config, task_id, config_id) do
    params = %{"taskId" => task_id, "configId" => config_id}

    call(config, :push_notification_config_get, params, fn result ->
      {:ok, A2A.Types.PushNotificationConfig.from_map(result)}
    end)
  end

  @spec push_notification_config_list(A2A.Client.Config.t(), String.t(), map()) ::
          {:ok, list(A2A.Types.PushNotificationConfig.t())} | {:error, A2A.Error.t()}
  def push_notification_config_list(%A2A.Client.Config{} = config, task_id, query) do
    params = Map.merge(%{"taskId" => task_id}, query)

    call(config, :push_notification_config_list, params, fn result ->
      {:ok, decode_push_config_list(result)}
    end)
  end

  @spec push_notification_config_delete(A2A.Client.Config.t(), String.t(), String.t()) ::
          :ok | {:error, A2A.Error.t()}
  def push_notification_config_delete(%A2A.Client.Config{} = config, task_id, config_id) do
    params = %{"taskId" => task_id, "configId" => config_id}

    call(config, :push_notification_config_delete, params, fn _result ->
      :ok
    end)
  end

  @spec get_extended_agent_card(A2A.Client.Config.t()) ::
          {:ok, A2A.Types.AgentCard.t()} | {:error, A2A.Error.t()}
  def get_extended_agent_card(%A2A.Client.Config{} = config) do
    if config.version == :latest do
      call(config, :get_extended_agent_card, %{}, fn result ->
        {:ok, A2A.Types.AgentCard.from_map(result)}
      end)
    else
      {:error, A2A.Error.new(:unsupported_operation, "Extended agent card not supported")}
    end
  end

  defp call(config, method_key, params, handler) do
    method_name = method_name(method_key, config.version)

    payload = %{
      "jsonrpc" => "2.0",
      "id" => unique_id(),
      "method" => method_name,
      "params" => params
    }

    url = build_url(config.base_url, "")
    headers = A2A.Client.Config.request_headers(config) |> ensure_content_type()
    metadata = %{transport: :jsonrpc, method: method_name, url: url}

    A2A.Telemetry.span([:a2a, :client, :request], metadata, fn ->
      req_opts =
        config.req_options
        |> Keyword.put_new(:receive_timeout, 30_000)
        |> Keyword.merge(method: :post, url: url, headers: headers, body: Jason.encode!(payload))

      resp = Req.request(req_opts)

      case resp do
        {:ok, %{status: status} = response} when status in 200..299 ->
          with {:ok, decoded} <- decode_json_response(response) do
            case decoded do
              %{"result" => result} ->
                handler.(result)

              %{"error" => error} ->
                {:error, attach_raw(A2A.Error.from_map(error), raw_from_response(response))}

              _ ->
                {:error,
                 attach_raw(
                   A2A.Error.new(:invalid_agent_response, "Invalid JSON-RPC response"),
                   raw_from_response(response)
                 )}
            end
          end

        {:ok, %{status: status} = response} ->
          error = A2A.Error.new(:http_error, "HTTP #{status}")
          {:error, attach_raw(error, raw_from_response(response))}

        {:error, reason} ->
          {:error, A2A.Error.new(:transport_error, inspect(reason))}
      end
    end)
  end

  defp ensure_content_type(headers) do
    if Enum.any?(headers, fn {key, _} -> String.downcase(key) == "content-type" end) do
      headers
    else
      headers ++ [{"content-type", "application/json"}]
    end
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

  defp method_name(key, :latest) do
    case key do
      :send_message -> "SendMessage"
      :stream_message -> "SendStreamingMessage"
      :get_task -> "GetTask"
      :list_tasks -> "ListTasks"
      :cancel_task -> "CancelTask"
      :resubscribe -> "SubscribeToTask"
      :subscribe -> "SubscribeToTask"
      :push_notification_config_set -> "CreateTaskPushNotificationConfig"
      :push_notification_config_get -> "GetTaskPushNotificationConfig"
      :push_notification_config_list -> "ListTaskPushNotificationConfig"
      :push_notification_config_delete -> "DeleteTaskPushNotificationConfig"
      :get_extended_agent_card -> "GetExtendedAgentCard"
    end
  end

  defp method_name(key, _version) do
    case key do
      :send_message -> "message/send"
      :stream_message -> "message/stream"
      :get_task -> "tasks/get"
      :list_tasks -> "tasks/list"
      :cancel_task -> "tasks/cancel"
      :resubscribe -> "tasks/resubscribe"
      :subscribe -> "tasks/subscribe"
      :push_notification_config_set -> "tasks/pushNotificationConfig/set"
      :push_notification_config_get -> "tasks/pushNotificationConfig/get"
      :push_notification_config_list -> "tasks/pushNotificationConfig/list"
      :push_notification_config_delete -> "tasks/pushNotificationConfig/delete"
      :get_extended_agent_card -> "agent/getExtendedCard"
    end
  end

  defp decode_json(body) when is_map(body), do: {:ok, body}

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, A2A.Error.new(:invalid_agent_response, "Invalid JSON")}
    end
  end

  defp decode_json(_body), do: {:error, A2A.Error.new(:invalid_agent_response, "Invalid JSON")}

  defp decode_json_response(%{body: body} = response) do
    case decode_json(body) do
      {:ok, map} -> {:ok, map}
      {:error, error} -> {:error, attach_raw(error, raw_from_response(response))}
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

  defp decode_stream_payload(%{"result" => payload}, config) when is_map(payload) do
    A2A.Types.StreamResponse.from_map(payload, version: config.version)
  end

  defp decode_stream_payload(%{"error" => error}, _config) when is_map(error) do
    %A2A.Types.StreamError{error: A2A.Error.from_map(error), raw: error}
  end

  defp decode_stream_payload(payload, _config) when is_map(payload) do
    %A2A.Types.StreamError{
      error:
        A2A.Error.new(:invalid_agent_response, "Invalid JSON-RPC stream response", raw: payload),
      raw: payload
    }
  end

  defp attach_raw(%A2A.Error{} = error, raw), do: %{error | raw: raw}

  defp raw_from_response(response) do
    %{status: response.status, headers: response.headers, body: response.body}
  end

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

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end

  defp build_url(base, path) do
    URI.merge(base, path) |> to_string()
  end
end
