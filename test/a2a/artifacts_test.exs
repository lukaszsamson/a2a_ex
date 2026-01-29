defmodule A2A.ArtifactsTest do
  use ExUnit.Case, async: true

  test "merges artifact updates" do
    artifacts =
      A2A.Artifacts.merge_update([], %A2A.Types.TaskArtifactUpdateEvent{
        task_id: "task-1",
        context_id: "ctx-1",
        artifact: %A2A.Types.Artifact{
          artifact_id: "art-1",
          parts: [%A2A.Types.TextPart{text: "A"}]
        },
        append: false
      })

    artifacts =
      A2A.Artifacts.merge_update(artifacts, %A2A.Types.TaskArtifactUpdateEvent{
        task_id: "task-1",
        context_id: "ctx-1",
        artifact: %A2A.Types.Artifact{
          artifact_id: "art-1",
          parts: [%A2A.Types.TextPart{text: "B"}]
        },
        append: true
      })

    assert [%A2A.Types.Artifact{artifact_id: "art-1", parts: parts}] = artifacts
    assert Enum.map(parts, & &1.text) == ["A", "B"]
  end

  test "merges multiple updates" do
    events = [
      %A2A.Types.TaskArtifactUpdateEvent{
        task_id: "task-1",
        context_id: "ctx-1",
        artifact: %A2A.Types.Artifact{artifact_id: "art-1", parts: []},
        append: false
      },
      %A2A.Types.TaskArtifactUpdateEvent{
        task_id: "task-1",
        context_id: "ctx-1",
        artifact: %A2A.Types.Artifact{artifact_id: "art-2", parts: []},
        append: false
      }
    ]

    artifacts = A2A.Artifacts.merge_updates([], events)
    assert Enum.map(artifacts, & &1.artifact_id) == ["art-1", "art-2"]
  end
end
