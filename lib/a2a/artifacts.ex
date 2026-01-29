defmodule A2A.Artifacts do
  @moduledoc """
  Utilities for merging artifact update events.
  """

  @spec merge_update(list(A2A.Types.Artifact.t()) | nil, A2A.Types.TaskArtifactUpdateEvent.t()) ::
          list(A2A.Types.Artifact.t())
  def merge_update(artifacts, %A2A.Types.TaskArtifactUpdateEvent{} = event) do
    artifacts = artifacts || []
    artifact = event.artifact

    case event.append do
      true ->
        append_artifact(artifacts, artifact)

      _ ->
        replace_artifact(artifacts, artifact)
    end
  end

  @spec merge_updates(
          list(A2A.Types.Artifact.t()) | nil,
          list(A2A.Types.TaskArtifactUpdateEvent.t())
        ) ::
          list(A2A.Types.Artifact.t())
  def merge_updates(artifacts, events) when is_list(events) do
    Enum.reduce(events, artifacts || [], fn event, acc ->
      merge_update(acc, event)
    end)
  end

  defp append_artifact(artifacts, %A2A.Types.Artifact{} = artifact) do
    {existing, rest} = split_artifact(artifacts, artifact.artifact_id)

    case existing do
      nil ->
        artifacts ++ [artifact]

      %A2A.Types.Artifact{} = current ->
        merged = %{current | parts: (current.parts || []) ++ (artifact.parts || [])}
        rest ++ [merged]
    end
  end

  defp replace_artifact(artifacts, %A2A.Types.Artifact{} = artifact) do
    {existing, rest} = split_artifact(artifacts, artifact.artifact_id)

    if existing do
      rest ++ [artifact]
    else
      artifacts ++ [artifact]
    end
  end

  defp split_artifact(artifacts, artifact_id) do
    {match, rest} =
      Enum.split_with(artifacts, fn %A2A.Types.Artifact{artifact_id: id} -> id == artifact_id end)

    {List.first(match), rest}
  end
end
