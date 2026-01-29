defmodule A2A.Transport do
  @moduledoc """
  Behaviour for A2A protocol transports.
  """

  @callback discover(A2A.Client.Config.t()) ::
              {:ok, A2A.Types.AgentCard.t()} | {:error, A2A.Error.t()}
  @callback send_message(A2A.Client.Config.t(), A2A.Types.SendMessageRequest.t()) ::
              {:ok, A2A.Types.Task.t() | A2A.Types.Message.t()} | {:error, A2A.Error.t()}
  @callback stream_message(A2A.Client.Config.t(), A2A.Types.SendMessageRequest.t()) ::
              {:ok, A2A.Client.Stream.t()} | {:error, A2A.Error.t()}
  @callback get_task(A2A.Client.Config.t(), String.t(), keyword()) ::
              {:ok, A2A.Types.Task.t()} | {:error, A2A.Error.t()}
  @callback list_tasks(A2A.Client.Config.t(), A2A.Types.ListTasksRequest.t()) ::
              {:ok, A2A.Types.ListTasksResponse.t()} | {:error, A2A.Error.t()}
  @callback cancel_task(A2A.Client.Config.t(), String.t()) ::
              {:ok, A2A.Types.Task.t()} | {:error, A2A.Error.t()}
  @callback resubscribe(A2A.Client.Config.t(), String.t(), map()) ::
              {:ok, A2A.Client.Stream.t()} | {:error, A2A.Error.t()}
  @callback subscribe(A2A.Client.Config.t(), String.t()) ::
              {:ok, A2A.Client.Stream.t()} | {:error, A2A.Error.t()}

  @callback push_notification_config_set(
              A2A.Client.Config.t(),
              String.t(),
              A2A.Types.PushNotificationConfig.t()
            ) ::
              {:ok, A2A.Types.PushNotificationConfig.t()} | {:error, A2A.Error.t()}
  @callback push_notification_config_get(A2A.Client.Config.t(), String.t(), String.t()) ::
              {:ok, A2A.Types.PushNotificationConfig.t()} | {:error, A2A.Error.t()}
  @callback push_notification_config_list(A2A.Client.Config.t(), String.t(), map()) ::
              {:ok, list(A2A.Types.PushNotificationConfig.t())} | {:error, A2A.Error.t()}
  @callback push_notification_config_delete(A2A.Client.Config.t(), String.t(), String.t()) ::
              :ok | {:error, A2A.Error.t()}
  @callback get_extended_agent_card(A2A.Client.Config.t()) ::
              {:ok, A2A.Types.AgentCard.t()} | {:error, A2A.Error.t()}
end
