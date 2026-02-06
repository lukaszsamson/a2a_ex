defmodule A2A.TransportGRPCTest do
  use ExUnit.Case, async: true

  setup do
    config = A2A.Client.Config.new("https://example.com", transport: A2A.Transport.GRPC)
    %{config: config}
  end

  test "all gRPC operations return unsupported_operation", %{config: config} do
    request = %A2A.Types.SendMessageRequest{
      message: %A2A.Types.Message{message_id: "msg-1", role: :user, parts: []}
    }

    list_request = %A2A.Types.ListTasksRequest{}
    push_config = %A2A.Types.PushNotificationConfig{id: "cfg-1", url: "https://example.com/hook"}

    checks = [
      A2A.Transport.GRPC.discover(config),
      A2A.Transport.GRPC.send_message(config, request),
      A2A.Transport.GRPC.stream_message(config, request),
      A2A.Transport.GRPC.get_task(config, "task-1", []),
      A2A.Transport.GRPC.list_tasks(config, list_request),
      A2A.Transport.GRPC.cancel_task(config, "task-1"),
      A2A.Transport.GRPC.resubscribe(config, "task-1", %{}),
      A2A.Transport.GRPC.subscribe(config, "task-1"),
      A2A.Transport.GRPC.push_notification_config_set(config, "task-1", push_config),
      A2A.Transport.GRPC.push_notification_config_get(config, "task-1", "cfg-1"),
      A2A.Transport.GRPC.push_notification_config_list(config, "task-1", %{}),
      A2A.Transport.GRPC.push_notification_config_delete(config, "task-1", "cfg-1"),
      A2A.Transport.GRPC.get_extended_agent_card(config)
    ]

    Enum.each(checks, fn result ->
      assert {:error, %A2A.Error{type: :unsupported_operation, message: "gRPC transport not configured"}} =
               result
    end)
  end
end
