defmodule A2A.TypesRoundtripTest do
  use ExUnit.Case, async: true

  test "round-trips message parts across versions" do
    message = build_message()

    for version <- [:v0_3, :latest] do
      map = A2A.Types.Message.to_map(message, version: version)
      decoded = A2A.Types.Message.from_map(map, version: version)

      assert decoded.message_id == "msg-1"

      assert Enum.map(decoded.parts, & &1.__struct__) == [
               A2A.Types.TextPart,
               A2A.Types.FilePart,
               A2A.Types.DataPart
             ]

      case version do
        :v0_3 ->
          assert map["role"] == "user"
          assert map["kind"] == "message"
          assert Enum.all?(map["parts"], &Map.has_key?(&1, "kind"))

        :latest ->
          assert map["role"] == "ROLE_USER"
          refute Map.has_key?(map, "kind")
          refute Enum.any?(map["parts"], &Map.has_key?(&1, "kind"))
      end
    end
  end

  test "round-trips tasks and events across versions" do
    message = build_message()
    artifact = build_artifact()
    status = %A2A.Types.TaskStatus{state: :working, message: message}

    task = %A2A.Types.Task{
      id: "task-1",
      context_id: "ctx-1",
      status: status,
      artifacts: [artifact],
      history: [message],
      metadata: %{"meta" => "1"}
    }

    status_update = %A2A.Types.TaskStatusUpdateEvent{
      task_id: "task-1",
      context_id: "ctx-1",
      status: status,
      final: false,
      metadata: %{"progress" => 1}
    }

    artifact_update = %A2A.Types.TaskArtifactUpdateEvent{
      task_id: "task-1",
      context_id: "ctx-1",
      artifact: artifact,
      append: true,
      last_chunk: true
    }

    stream_response = %A2A.Types.StreamResponse{
      task: task,
      message: message,
      status_update: status_update,
      artifact_update: artifact_update
    }

    for version <- [:v0_3, :latest] do
      task_map = A2A.Types.Task.to_map(task, version: version)
      decoded_task = A2A.Types.Task.from_map(task_map, version: version)

      assert decoded_task.id == "task-1"
      assert decoded_task.status.state == :working
      assert length(decoded_task.history) == 1

      case version do
        :v0_3 ->
          assert task_map["kind"] == "task"
          assert get_in(task_map, ["status", "state"]) == "working"

        :latest ->
          refute Map.has_key?(task_map, "kind")
          assert get_in(task_map, ["status", "state"]) == "TASK_STATE_WORKING"
      end

      status_map = A2A.Types.TaskStatusUpdateEvent.to_map(status_update, version: version)
      decoded_status = A2A.Types.TaskStatusUpdateEvent.from_map(status_map, version: version)
      assert decoded_status.status.state == :working

      artifact_map = A2A.Types.TaskArtifactUpdateEvent.to_map(artifact_update, version: version)

      decoded_artifact =
        A2A.Types.TaskArtifactUpdateEvent.from_map(artifact_map, version: version)

      assert decoded_artifact.append

      case version do
        :v0_3 ->
          assert status_map["kind"] == "status-update"
          assert artifact_map["kind"] == "artifact-update"

        :latest ->
          refute Map.has_key?(status_map, "kind")
          refute Map.has_key?(artifact_map, "kind")
      end

      stream_map = A2A.Types.StreamResponse.to_map(stream_response, version: version)
      decoded_stream = A2A.Types.StreamResponse.from_map(stream_map, version: version)
      assert decoded_stream.task.id == "task-1"
      assert decoded_stream.status_update.task_id == "task-1"
    end
  end

  test "round-trips send message configuration" do
    config = %A2A.Types.SendMessageConfiguration{
      blocking: true,
      history_length: 2,
      accepted_output_modes: ["text"],
      push_notification_config: %A2A.Types.PushNotificationConfig{
        url: "https://example.com/webhook",
        token: "token-1",
        authentication: %A2A.Types.AuthenticationInfo{schemes: ["Bearer"], credentials: "abc"}
      }
    }

    request = %A2A.Types.SendMessageRequest{
      message: build_message(),
      configuration: config,
      metadata: %{"trace" => "1"},
      tenant: "tenant-1"
    }

    for version <- [:v0_3, :latest] do
      map = A2A.Types.SendMessageRequest.to_map(request, version: version)
      decoded = A2A.Types.SendMessageRequest.from_map(map, version: version)

      assert decoded.configuration.history_length == 2
      assert decoded.configuration.push_notification_config.url == "https://example.com/webhook"
      assert decoded.metadata["trace"] == "1"
    end
  end

  test "requires data parts to encode objects by default" do
    part = %A2A.Types.DataPart{data: [1, 2]}

    assert_raise ArgumentError, fn ->
      A2A.Types.Part.encode(part, version: :v0_3)
    end
  end

  test "allows non-object data parts when enabled" do
    for value <- ["string-value", [1, 2], 42] do
      map = %{"data" => value}
      part = A2A.Types.Part.decode(map)

      assert %A2A.Types.DataPart{data: ^value} = part

      encoded = A2A.Types.Part.encode(part, version: :v0_3, allow_non_object_data: true)
      assert encoded["data"] == value
      assert encoded["kind"] == "data"

      latest_encoded =
        A2A.Types.Part.encode(part, version: :latest, allow_non_object_data: true)

      assert latest_encoded["data"] == value
      refute Map.has_key?(latest_encoded, "kind")
    end
  end

  defp build_message do
    %A2A.Types.Message{
      message_id: "msg-1",
      role: :user,
      context_id: "ctx-1",
      task_id: "task-1",
      reference_task_ids: ["task-0"],
      parts: [
        %A2A.Types.TextPart{text: "hi"},
        %A2A.Types.FilePart{
          name: "file.txt",
          media_type: "text/plain",
          file_with_uri: "https://example.com/file.txt"
        },
        %A2A.Types.DataPart{data: %{"key" => "value"}}
      ],
      metadata: %{"source" => "test"},
      extensions: ["urn:test"]
    }
  end

  defp build_artifact do
    %A2A.Types.Artifact{
      artifact_id: "art-1",
      name: "artifact",
      description: "artifact desc",
      parts: [%A2A.Types.TextPart{text: "payload"}],
      metadata: %{"size" => 1}
    }
  end

  describe "SendMessageResponse.from_map with kind discriminator" do
    test "parses unwrapped message with kind: message" do
      # Python SDK returns this format
      map = %{
        "kind" => "message",
        "messageId" => "msg-123",
        "role" => "agent",
        "parts" => [%{"kind" => "text", "text" => "Hello World"}]
      }

      response = A2A.Types.SendMessageResponse.from_map(map)

      assert response.message != nil
      assert response.task == nil
      assert response.message.message_id == "msg-123"
      assert response.message.role == :agent
      assert [%A2A.Types.TextPart{text: "Hello World"}] = response.message.parts
    end

    test "parses unwrapped task with kind: task" do
      map = %{
        "kind" => "task",
        "id" => "task-123",
        "contextId" => "ctx-456",
        "status" => %{"state" => "completed"}
      }

      response = A2A.Types.SendMessageResponse.from_map(map)

      assert response.task != nil
      assert response.message == nil
      assert response.task.id == "task-123"
      assert response.task.context_id == "ctx-456"
      assert response.task.status.state == :completed
    end

    test "parses wrapped message format" do
      map = %{
        "message" => %{
          "messageId" => "msg-123",
          "role" => "agent",
          "parts" => [%{"kind" => "text", "text" => "Hello"}]
        }
      }

      response = A2A.Types.SendMessageResponse.from_map(map)

      assert response.message != nil
      assert response.message.message_id == "msg-123"
    end

    test "parses wrapped task format" do
      map = %{
        "task" => %{
          "id" => "task-123",
          "status" => %{"state" => "working"}
        }
      }

      response = A2A.Types.SendMessageResponse.from_map(map)

      assert response.task != nil
      assert response.task.id == "task-123"
    end
  end

  describe "StreamResponse.from_map with kind discriminator" do
    test "parses unwrapped message with kind: message" do
      map = %{
        "kind" => "message",
        "messageId" => "msg-123",
        "role" => "agent",
        "parts" => [%{"kind" => "text", "text" => "Hello"}]
      }

      response = A2A.Types.StreamResponse.from_map(map)

      assert response.message != nil
      assert response.task == nil
      assert response.status_update == nil
      assert response.artifact_update == nil
      assert response.message.message_id == "msg-123"
    end

    test "parses unwrapped task with kind: task" do
      map = %{
        "kind" => "task",
        "id" => "task-123",
        "status" => %{"state" => "completed"}
      }

      response = A2A.Types.StreamResponse.from_map(map)

      assert response.task != nil
      assert response.message == nil
      assert response.task.id == "task-123"
    end

    test "parses unwrapped status-update with kind: status-update" do
      map = %{
        "kind" => "status-update",
        "taskId" => "task-123",
        "contextId" => "ctx-456",
        "status" => %{"state" => "working"},
        "final" => false
      }

      response = A2A.Types.StreamResponse.from_map(map)

      assert response.status_update != nil
      assert response.task == nil
      assert response.status_update.task_id == "task-123"
      assert response.status_update.status.state == :working
      assert response.status_update.final == false
    end

    test "parses unwrapped artifact-update with kind: artifact-update" do
      map = %{
        "kind" => "artifact-update",
        "taskId" => "task-123",
        "contextId" => "ctx-456",
        "artifact" => %{
          "artifactId" => "art-1",
          "parts" => [%{"kind" => "text", "text" => "data"}]
        },
        "append" => true,
        "lastChunk" => true
      }

      response = A2A.Types.StreamResponse.from_map(map)

      assert response.artifact_update != nil
      assert response.task == nil
      assert response.artifact_update.task_id == "task-123"
      assert response.artifact_update.artifact.artifact_id == "art-1"
      assert response.artifact_update.append == true
      assert response.artifact_update.last_chunk == true
    end

    test "parses wrapped format with task key" do
      map = %{
        "task" => %{
          "id" => "task-123",
          "status" => %{"state" => "working"}
        }
      }

      response = A2A.Types.StreamResponse.from_map(map)

      assert response.task != nil
      assert response.task.id == "task-123"
    end

    test "parses wrapped format with statusUpdate key" do
      map = %{
        "statusUpdate" => %{
          "taskId" => "task-123",
          "status" => %{"state" => "completed"},
          "final" => true
        }
      }

      response = A2A.Types.StreamResponse.from_map(map)

      assert response.status_update != nil
      assert response.status_update.final == true
    end
  end
end
