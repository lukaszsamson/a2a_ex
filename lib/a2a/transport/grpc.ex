defmodule A2A.Transport.GRPC do
  @moduledoc """
  Placeholder transport for unconfigured gRPC support.
  """

  @behaviour A2A.Transport

  @spec discover(A2A.Client.Config.t()) :: {:error, A2A.Error.t()}
  def discover(_config),
    do: {:error, A2A.Error.new(:unsupported_operation, "gRPC transport not configured")}

  @spec send_message(A2A.Client.Config.t(), A2A.Types.SendMessageRequest.t()) ::
          {:error, A2A.Error.t()}
  def send_message(_config, _request),
    do: {:error, A2A.Error.new(:unsupported_operation, "gRPC transport not configured")}

  @spec stream_message(A2A.Client.Config.t(), A2A.Types.SendMessageRequest.t()) ::
          {:error, A2A.Error.t()}
  def stream_message(_config, _request),
    do: {:error, A2A.Error.new(:unsupported_operation, "gRPC transport not configured")}

  @spec get_task(A2A.Client.Config.t(), String.t(), keyword() | map()) ::
          {:error, A2A.Error.t()}
  def get_task(_config, _task_id, _opts),
    do: {:error, A2A.Error.new(:unsupported_operation, "gRPC transport not configured")}

  @spec list_tasks(A2A.Client.Config.t(), A2A.Types.ListTasksRequest.t()) ::
          {:error, A2A.Error.t()}
  def list_tasks(_config, _request),
    do: {:error, A2A.Error.new(:unsupported_operation, "gRPC transport not configured")}

  @spec cancel_task(A2A.Client.Config.t(), String.t()) :: {:error, A2A.Error.t()}
  def cancel_task(_config, _task_id),
    do: {:error, A2A.Error.new(:unsupported_operation, "gRPC transport not configured")}

  @spec resubscribe(A2A.Client.Config.t(), String.t(), map()) :: {:error, A2A.Error.t()}
  def resubscribe(_config, _task_id, _resume),
    do: {:error, A2A.Error.new(:unsupported_operation, "gRPC transport not configured")}

  @spec subscribe(A2A.Client.Config.t(), String.t()) :: {:error, A2A.Error.t()}
  def subscribe(_config, _task_id),
    do: {:error, A2A.Error.new(:unsupported_operation, "gRPC transport not configured")}

  @spec push_notification_config_set(
          A2A.Client.Config.t(),
          String.t(),
          A2A.Types.PushNotificationConfig.t() | map()
        ) :: {:error, A2A.Error.t()}
  def push_notification_config_set(_config, _task_id, _request),
    do: {:error, A2A.Error.new(:unsupported_operation, "gRPC transport not configured")}

  @spec push_notification_config_get(A2A.Client.Config.t(), String.t(), String.t()) ::
          {:error, A2A.Error.t()}
  def push_notification_config_get(_config, _task_id, _config_id),
    do: {:error, A2A.Error.new(:unsupported_operation, "gRPC transport not configured")}

  @spec push_notification_config_list(A2A.Client.Config.t(), String.t(), map() | keyword()) ::
          {:error, A2A.Error.t()}
  def push_notification_config_list(_config, _task_id, _query),
    do: {:error, A2A.Error.new(:unsupported_operation, "gRPC transport not configured")}

  @spec push_notification_config_delete(A2A.Client.Config.t(), String.t(), String.t()) ::
          {:error, A2A.Error.t()}
  def push_notification_config_delete(_config, _task_id, _config_id),
    do: {:error, A2A.Error.new(:unsupported_operation, "gRPC transport not configured")}

  @spec get_extended_agent_card(A2A.Client.Config.t()) :: {:error, A2A.Error.t()}
  def get_extended_agent_card(_config),
    do: {:error, A2A.Error.new(:unsupported_operation, "gRPC transport not configured")}
end
