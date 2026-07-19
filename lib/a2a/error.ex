defmodule A2A.Error do
  @moduledoc """
  Structured A2A error representation and mappings.
  """

  @enforce_keys [:type, :message]
  defstruct [:type, :message, :code, :data, :retryable?, :raw]

  @type t :: %__MODULE__{
          type: atom() | String.t(),
          message: String.t(),
          code: integer() | nil,
          data: term(),
          retryable?: boolean() | nil,
          raw: map() | nil
        }

  @spec new(atom() | String.t(), String.t(), keyword()) :: t()
  def new(type, message, opts \\ []) do
    %__MODULE__{
      type: normalize_type(type),
      message: message,
      code: Keyword.get(opts, :code),
      data: Keyword.get(opts, :data),
      retryable?: Keyword.get(opts, :retryable?),
      raw: Keyword.get(opts, :raw)
    }
  end

  def from_map(map) when is_map(map) do
    {error_map, raw} = unwrap_error(map)

    case error_map do
      %{"details" => details} when is_list(details) ->
        from_v1_details(error_map, details, raw)

      %{"data" => details} when is_list(details) ->
        from_v1_details(error_map, details, raw)

      %{"data" => %{"type" => type} = data} ->
        new(type, error_message(data, error_map),
          code: Map.get(error_map, "code"),
          data: extract_data(data),
          retryable?: Map.get(data, "retryable") || Map.get(error_map, "retryable"),
          raw: raw
        )

      %{"type" => type} ->
        new(type, Map.get(error_map, "message", ""),
          code: Map.get(error_map, "code"),
          data: Map.get(error_map, "data"),
          retryable?: Map.get(error_map, "retryable"),
          raw: raw
        )

      %{"code" => code} ->
        new(:unknown, Map.get(error_map, "message", ""),
          code: code,
          data: Map.get(error_map, "data"),
          retryable?: Map.get(error_map, "retryable"),
          raw: raw
        )

      _ ->
        new(:unknown, Map.get(error_map, "message", ""), raw: raw)
    end
  end

  defp unwrap_error(%{"error" => error} = map) when is_map(error), do: {error, map}
  defp unwrap_error(%{"data" => %{"error" => error}} = map) when is_map(error), do: {error, map}
  defp unwrap_error(map), do: {map, map}

  defp error_message(data, error_map) do
    Map.get(data, "message") || Map.get(error_map, "message") || ""
  end

  defp extract_data(data) do
    case Map.get(data, "data") || Map.get(data, :data) do
      nil ->
        data
        |> Map.drop(["type", "message", "retryable"])
        |> case do
          map when map == %{} -> nil
          map -> map
        end

      value ->
        value
    end
  end

  def to_map(%__MODULE__{} = error) do
    %{}
    |> A2A.Types.put_if("type", type_to_string(error.type))
    |> A2A.Types.put_if("message", error.message)
    |> A2A.Types.put_if("code", error.code)
    |> A2A.Types.put_if("data", error.data)
    |> A2A.Types.put_if("retryable", error.retryable?)
  end

  def http_status(%__MODULE__{type: type}) do
    case normalize_type(type) do
      :task_not_found -> 404
      :task_not_cancelable -> 409
      :push_notification_not_supported -> 501
      :unsupported_operation -> 501
      :content_type_not_supported -> 415
      :invalid_agent_response -> 502
      :request_timeout -> 504
      :stream_timeout -> 504
      :extended_agent_card_not_configured -> 501
      :extension_support_required -> 400
      :version_not_supported -> 426
      :unauthorized -> 401
      _ -> 500
    end
  end

  @spec http_status(t(), A2A.Types.version()) :: pos_integer()
  def http_status(%__MODULE__{} = error, version) do
    case A2A.Types.normalize_version(version) do
      :v0_3 -> http_status(error)
      :v1_0 -> v1_http_status(error.type)
    end
  end

  @spec jsonrpc_code(t(), A2A.Types.version()) :: integer()
  def jsonrpc_code(%__MODULE__{}, :v0_3), do: -32000
  def jsonrpc_code(%__MODULE__{} = error, :latest), do: jsonrpc_code(error, :v1_0)

  def jsonrpc_code(%__MODULE__{type: type}, :v1_0) do
    case normalize_type(type) do
      :task_not_found -> -32001
      :task_not_cancelable -> -32002
      :push_notification_not_supported -> -32003
      :unsupported_operation -> -32004
      :content_type_not_supported -> -32005
      :invalid_agent_response -> -32006
      :extended_agent_card_not_configured -> -32007
      :extension_support_required -> -32008
      :version_not_supported -> -32009
      :invalid_params -> -32602
      _ -> -32603
    end
  end

  @spec v1_details(t()) :: list(map())
  def v1_details(%__MODULE__{} = error) do
    metadata = if is_map(error.data), do: stringify_keys(error.data), else: %{}

    [
      %{
        "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
        "reason" => reason(error.type),
        "domain" => "a2a-protocol.org",
        "metadata" => metadata
      }
    ]
  end

  @spec google_rpc_status(t()) :: map()
  def google_rpc_status(%__MODULE__{} = error) do
    status = http_status(error, :v1_0)

    %{
      "code" => status,
      "status" => google_status_name(status),
      "message" => error.message,
      "details" => v1_details(error)
    }
  end

  def normalize_type(type) when is_atom(type), do: type
  def normalize_type("TaskNotFoundError"), do: :task_not_found
  def normalize_type("TaskNotCancelableError"), do: :task_not_cancelable
  def normalize_type("PushNotificationNotSupportedError"), do: :push_notification_not_supported
  def normalize_type("UnsupportedOperationError"), do: :unsupported_operation
  def normalize_type("ContentTypeNotSupportedError"), do: :content_type_not_supported
  def normalize_type("InvalidAgentResponseError"), do: :invalid_agent_response
  def normalize_type("RequestTimeoutError"), do: :request_timeout
  def normalize_type("StreamTimeoutError"), do: :stream_timeout

  def normalize_type("ExtendedAgentCardNotConfiguredError"),
    do: :extended_agent_card_not_configured

  def normalize_type("ExtensionSupportRequiredError"), do: :extension_support_required
  def normalize_type("VersionNotSupportedError"), do: :version_not_supported
  def normalize_type("UnauthorizedError"), do: :unauthorized
  def normalize_type("InvalidParamsError"), do: :invalid_params
  def normalize_type(type), do: type

  def type_to_string(:task_not_found), do: "TaskNotFoundError"
  def type_to_string(:task_not_cancelable), do: "TaskNotCancelableError"
  def type_to_string(:push_notification_not_supported), do: "PushNotificationNotSupportedError"
  def type_to_string(:unsupported_operation), do: "UnsupportedOperationError"
  def type_to_string(:content_type_not_supported), do: "ContentTypeNotSupportedError"
  def type_to_string(:invalid_agent_response), do: "InvalidAgentResponseError"
  def type_to_string(:request_timeout), do: "RequestTimeoutError"
  def type_to_string(:stream_timeout), do: "StreamTimeoutError"

  def type_to_string(:extended_agent_card_not_configured),
    do: "ExtendedAgentCardNotConfiguredError"

  def type_to_string(:extension_support_required), do: "ExtensionSupportRequiredError"
  def type_to_string(:version_not_supported), do: "VersionNotSupportedError"
  def type_to_string(:unauthorized), do: "UnauthorizedError"
  def type_to_string(:invalid_params), do: "InvalidParamsError"
  def type_to_string(type) when is_atom(type), do: Atom.to_string(type)
  def type_to_string(type), do: type

  defp from_v1_details(error_map, details, raw) do
    info =
      Enum.find(details, fn
        %{"@type" => "type.googleapis.com/google.rpc.ErrorInfo"} -> true
        _ -> false
      end) || %{}

    type = info |> Map.get("reason", "UNKNOWN") |> type_from_reason()

    new(type, Map.get(error_map, "message", ""),
      code: Map.get(error_map, "code"),
      data: Map.get(info, "metadata"),
      raw: raw
    )
  end

  defp type_from_reason(reason) do
    case reason do
      "TASK_NOT_FOUND" -> :task_not_found
      "TASK_NOT_CANCELABLE" -> :task_not_cancelable
      "PUSH_NOTIFICATION_NOT_SUPPORTED" -> :push_notification_not_supported
      "UNSUPPORTED_OPERATION" -> :unsupported_operation
      "CONTENT_TYPE_NOT_SUPPORTED" -> :content_type_not_supported
      "INVALID_AGENT_RESPONSE" -> :invalid_agent_response
      "EXTENDED_AGENT_CARD_NOT_CONFIGURED" -> :extended_agent_card_not_configured
      "EXTENSION_SUPPORT_REQUIRED" -> :extension_support_required
      "VERSION_NOT_SUPPORTED" -> :version_not_supported
      "INVALID_PARAMS" -> :invalid_params
      other -> other
    end
  end

  defp reason(type) do
    type
    |> type_to_string()
    |> String.replace_suffix("Error", "")
    |> Macro.underscore()
    |> String.upcase()
  end

  defp stringify_keys(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(value) when is_binary(value), do: value

  defp stringify(value) when is_atom(value) or is_number(value) or is_boolean(value),
    do: to_string(value)

  defp stringify(value), do: Jason.encode!(value)

  defp v1_http_status(type) do
    case normalize_type(type) do
      :task_not_found -> 404
      :invalid_agent_response -> 500
      :unauthorized -> 401
      _ -> 400
    end
  end

  defp google_status_name(400), do: "INVALID_ARGUMENT"
  defp google_status_name(401), do: "UNAUTHENTICATED"
  defp google_status_name(404), do: "NOT_FOUND"
  defp google_status_name(409), do: "FAILED_PRECONDITION"
  defp google_status_name(415), do: "INVALID_ARGUMENT"
  defp google_status_name(502), do: "INTERNAL"
  defp google_status_name(500), do: "INTERNAL"
  defp google_status_name(_), do: "UNKNOWN"
end
