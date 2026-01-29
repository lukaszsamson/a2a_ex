defmodule A2A.Server.Executor do
  @moduledoc """
  Behaviour defining executor callbacks for server request handling.
  """

  @callback handle_send_message(A2A.Types.SendMessageRequest.t(), map()) ::
              {:ok, A2A.Types.Task.t() | A2A.Types.Message.t()} | {:error, A2A.Error.t()}

  @callback handle_stream_message(A2A.Types.SendMessageRequest.t(), map(), (term() -> :ok)) ::
              {:ok, A2A.Types.Task.t() | A2A.Types.Message.t()} | {:error, A2A.Error.t()}

  @callback handle_get_task(String.t(), keyword(), map()) ::
              {:ok, A2A.Types.Task.t()} | {:error, A2A.Error.t()}

  @callback handle_list_tasks(A2A.Types.ListTasksRequest.t(), map()) ::
              {:ok, A2A.Types.ListTasksResponse.t()} | {:error, A2A.Error.t()}

  @callback handle_cancel_task(String.t(), map()) ::
              {:ok, A2A.Types.Task.t()} | {:error, A2A.Error.t()}

  @callback handle_subscribe(String.t(), map(), (term() -> :ok)) ::
              {:ok, :subscribed} | {:error, A2A.Error.t()}

  @callback handle_resubscribe(String.t(), map(), map(), (term() -> :ok)) ::
              {:ok, :subscribed} | {:error, A2A.Error.t()}

  @callback handle_push_notification_config_set(String.t(), map(), map()) ::
              {:ok, map()} | {:error, A2A.Error.t()}

  @callback handle_push_notification_config_get(String.t(), String.t(), map()) ::
              {:ok, map()} | {:error, A2A.Error.t()}

  @callback handle_push_notification_config_list(String.t(), map(), map()) ::
              {:ok, list()} | {:error, A2A.Error.t()}

  @callback handle_push_notification_config_delete(String.t(), String.t(), map()) ::
              :ok | {:error, A2A.Error.t()}

  @callback handle_get_extended_agent_card(map()) ::
              {:ok, A2A.Types.AgentCard.t()} | {:error, A2A.Error.t()}

  @optional_callbacks handle_stream_message: 3,
                      handle_subscribe: 3,
                      handle_resubscribe: 4,
                      handle_push_notification_config_set: 3,
                      handle_push_notification_config_get: 3,
                      handle_push_notification_config_list: 3,
                      handle_push_notification_config_delete: 3,
                      handle_get_extended_agent_card: 1
end
