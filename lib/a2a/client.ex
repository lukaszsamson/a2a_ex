defmodule A2A.Client do
  @moduledoc """
  Client entrypoint for A2A protocol operations.
  """

  alias A2A.Client.Config

  @spec discover(String.t() | A2A.Types.AgentCard.t(), keyword()) ::
          {:ok, A2A.Types.AgentCard.t()} | {:error, A2A.Error.t()}
  def discover(base_url, opts \\ []) do
    config = Config.new(base_url, opts)

    with {:ok, card} <- config.transport.discover(config),
         :ok <- maybe_validate_card(card, config, opts),
         :ok <- maybe_verify_card(card, opts) do
      {:ok, card}
    end
  end

  @spec send_message(
          String.t() | A2A.Types.AgentCard.t(),
          map() | keyword() | A2A.Types.SendMessageRequest.t(),
          keyword()
        ) ::
          {:ok, A2A.Types.Task.t() | A2A.Types.Message.t()} | {:error, A2A.Error.t()}
  def send_message(target, request_opts, opts \\ []) do
    {config, request} = build_request(target, request_opts, opts)
    config.transport.send_message(config, request)
  end

  @spec stream_message(
          String.t() | A2A.Types.AgentCard.t(),
          map() | keyword() | A2A.Types.SendMessageRequest.t(),
          keyword()
        ) ::
          {:ok, A2A.Client.Stream.t()} | {:error, A2A.Error.t()}
  def stream_message(target, request_opts, opts \\ []) do
    {config, request} = build_request(target, request_opts, opts)

    config.transport.stream_message(config, request)
  end

  @spec get_task(String.t() | A2A.Types.AgentCard.t(), String.t(), keyword()) ::
          {:ok, A2A.Types.Task.t()} | {:error, A2A.Error.t()}
  def get_task(target, task_id, opts \\ []) do
    config = build_config(target, opts)
    config.transport.get_task(config, task_id, opts)
  end

  @spec list_tasks(
          String.t() | A2A.Types.AgentCard.t(),
          map() | keyword() | A2A.Types.ListTasksRequest.t(),
          keyword()
        ) ::
          {:ok, A2A.Types.ListTasksResponse.t()} | {:error, A2A.Error.t()}
  def list_tasks(target, request, opts \\ []) do
    config = build_config(target, opts)

    request =
      case request do
        %A2A.Types.ListTasksRequest{} -> request
        map when is_map(map) -> A2A.Types.ListTasksRequest.from_map(map, version: config.version)
        keyword when is_list(keyword) -> A2A.Types.ListTasksRequest.from_map(Map.new(keyword))
      end

    config.transport.list_tasks(config, request)
  end

  @spec cancel_task(String.t() | A2A.Types.AgentCard.t(), String.t(), keyword()) ::
          {:ok, A2A.Types.Task.t()} | {:error, A2A.Error.t()}
  def cancel_task(target, task_id, opts \\ []) do
    config = build_config(target, opts)
    config.transport.cancel_task(config, task_id)
  end

  @spec resubscribe(String.t() | A2A.Types.AgentCard.t(), String.t(), map(), keyword()) ::
          {:ok, A2A.Client.Stream.t()} | {:error, A2A.Error.t()}
  def resubscribe(target, task_id, resume, opts \\ []) do
    config = build_config(target, opts)
    config.transport.resubscribe(config, task_id, resume)
  end

  @spec subscribe(String.t() | A2A.Types.AgentCard.t(), String.t(), keyword()) ::
          {:ok, A2A.Client.Stream.t()} | {:error, A2A.Error.t()}
  def subscribe(target, task_id, opts \\ []) do
    config = build_config(target, opts)
    config.transport.subscribe(config, task_id)
  end

  @spec push_notification_config_set(
          String.t() | A2A.Types.AgentCard.t(),
          String.t(),
          map() | keyword() | A2A.Types.PushNotificationConfig.t(),
          keyword()
        ) ::
          {:ok, A2A.Types.PushNotificationConfig.t()} | {:error, A2A.Error.t()}
  def push_notification_config_set(target, task_id, config_request, opts \\ []) do
    config = build_config(target, opts)
    request = coerce_push_config(config_request)
    config.transport.push_notification_config_set(config, task_id, request)
  end

  @spec push_notification_config_get(
          String.t() | A2A.Types.AgentCard.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, A2A.Types.PushNotificationConfig.t()} | {:error, A2A.Error.t()}
  def push_notification_config_get(target, task_id, config_id, opts \\ []) do
    config = build_config(target, opts)
    config.transport.push_notification_config_get(config, task_id, config_id)
  end

  @spec push_notification_config_list(
          String.t() | A2A.Types.AgentCard.t(),
          String.t(),
          map(),
          keyword()
        ) ::
          {:ok, list(A2A.Types.PushNotificationConfig.t())} | {:error, A2A.Error.t()}
  def push_notification_config_list(target, task_id, query \\ %{}, opts \\ []) do
    config = build_config(target, opts)
    config.transport.push_notification_config_list(config, task_id, query)
  end

  @spec push_notification_config_delete(
          String.t() | A2A.Types.AgentCard.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          :ok | {:error, A2A.Error.t()}
  def push_notification_config_delete(target, task_id, config_id, opts \\ []) do
    config = build_config(target, opts)
    config.transport.push_notification_config_delete(config, task_id, config_id)
  end

  @spec get_extended_agent_card(String.t() | A2A.Types.AgentCard.t(), keyword()) ::
          {:ok, A2A.Types.AgentCard.t()} | {:error, A2A.Error.t()}
  def get_extended_agent_card(target, opts \\ []) do
    config = build_config(target, opts)
    config.transport.get_extended_agent_card(config)
  end

  def select_interface(%A2A.Types.AgentCard{} = card, opts \\ []) do
    binding = interface_binding_override(opts)

    if binding do
      interface_for_binding(card, binding) || default_interface(card)
    else
      default_interface(card)
    end
  end

  def transport_for_binding("JSONRPC"), do: A2A.Transport.JSONRPC
  def transport_for_binding("HTTP+JSON"), do: A2A.Transport.REST
  def transport_for_binding("REST"), do: A2A.Transport.REST
  def transport_for_binding("GRPC"), do: A2A.Transport.GRPC
  def transport_for_binding(_), do: A2A.Transport.REST

  defp interface_binding_override(opts) do
    Keyword.get(opts, :protocol_binding) || binding_for_transport(Keyword.get(opts, :transport))
  end

  defp binding_for_transport(nil), do: nil
  defp binding_for_transport(A2A.Transport.JSONRPC), do: "JSONRPC"
  defp binding_for_transport(A2A.Transport.REST), do: "HTTP+JSON"
  defp binding_for_transport(A2A.Transport.GRPC), do: "GRPC"
  defp binding_for_transport(_), do: nil

  defp interface_for_binding(%A2A.Types.AgentCard{} = card, binding) do
    interfaces = List.wrap(card.supported_interfaces) ++ List.wrap(card.additional_interfaces)

    Enum.find(interfaces, fn interface ->
      Map.get(interface, :protocol_binding) == binding or
        Map.get(interface, "protocolBinding") == binding
    end) ||
      if card.preferred_transport == binding and is_binary(card.url) do
        %A2A.Types.AgentInterface{protocol_binding: binding, url: card.url}
      end
  end

  defp default_interface(%A2A.Types.AgentCard{} = card) do
    cond do
      is_list(card.supported_interfaces) and card.supported_interfaces != [] ->
        hd(card.supported_interfaces)

      card.preferred_transport && card.url ->
        %A2A.Types.AgentInterface{protocol_binding: card.preferred_transport, url: card.url}

      is_list(card.additional_interfaces) and card.additional_interfaces != [] ->
        hd(card.additional_interfaces)

      true ->
        nil
    end
  end

  defp build_request(target, request_opts, opts) do
    config = build_config(target, opts)

    request =
      case request_opts do
        %A2A.Types.SendMessageRequest{} ->
          request_opts

        map when is_map(map) ->
          A2A.Types.SendMessageRequest.from_map(map, version: config.version)

        keyword when is_list(keyword) ->
          build_send_message_from_keyword(keyword, config)
      end

    {config, request}
  end

  defp build_send_message_from_keyword(keyword, config) do
    message = Keyword.fetch!(keyword, :message)

    request = %A2A.Types.SendMessageRequest{
      message: message,
      configuration: Keyword.get(keyword, :configuration),
      metadata: Keyword.get(keyword, :metadata),
      tenant: Keyword.get(keyword, :tenant)
    }

    A2A.Types.SendMessageRequest.from_map(
      A2A.Types.SendMessageRequest.to_map(request, version: config.version),
      version: config.version
    )
  end

  defp build_config(%A2A.Types.AgentCard{} = card, opts) do
    Config.from_agent_card(card, opts)
  end

  defp build_config(base_url, opts) when is_binary(base_url) do
    Config.new(base_url, opts)
  end

  defp coerce_push_config(%A2A.Types.PushNotificationConfig{} = config), do: config

  defp coerce_push_config(map) when is_map(map),
    do: A2A.Types.PushNotificationConfig.from_map(map)

  defp coerce_push_config(keyword) when is_list(keyword),
    do: A2A.Types.PushNotificationConfig.from_map(Map.new(keyword))

  defp maybe_verify_card(card, opts) do
    if Keyword.get(opts, :verify_signatures, false) do
      verifier = Keyword.get(opts, :signature_verifier)
      A2A.AgentCard.verify_signatures(card, verifier: verifier)
    else
      :ok
    end
  end

  defp maybe_validate_card(card, config, opts) do
    if Keyword.get(opts, :validate_card, true) do
      A2A.AgentCard.validate(card, version: config.version)
    else
      :ok
    end
  end
end
