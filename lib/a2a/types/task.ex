defmodule A2A.Types.TaskStatus do
  @moduledoc """
  Task status payload.
  """

  defstruct [:state, :message, :timestamp, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map(), keyword()) :: %__MODULE__{}
  def from_map(map, opts \\ []) do
    %__MODULE__{
      state: A2A.TaskState.decode(map["state"], opts),
      message: decode_message(map["message"], opts),
      timestamp: A2A.Types.decode_datetime(map["timestamp"]),
      raw: A2A.Types.drop_raw(map, ["state", "message", "timestamp"])
    }
  end

  @spec to_map(%__MODULE__{}, keyword()) :: map()
  def to_map(%__MODULE__{} = status, opts \\ []) do
    %{}
    |> A2A.Types.put_if("state", A2A.TaskState.encode(status.state, opts))
    |> A2A.Types.put_if("message", encode_message(status.message, opts))
    |> A2A.Types.put_if("timestamp", A2A.Types.encode_datetime(status.timestamp))
    |> A2A.Types.merge_raw(status.raw)
  end

  defp decode_message(nil, _opts), do: nil
  defp decode_message(map, opts), do: A2A.Types.Message.from_map(map, opts)
  defp encode_message(nil, _opts), do: nil
  defp encode_message(message, opts), do: A2A.Types.Message.to_map(message, opts)
end

defmodule A2A.Types.Artifact do
  @moduledoc """
  Artifact payload.
  """

  defstruct [:artifact_id, :name, :description, :parts, :metadata, :extensions, :kind, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map(), keyword()) :: %__MODULE__{}
  def from_map(map, opts \\ []) do
    %__MODULE__{
      artifact_id: map["artifactId"],
      name: map["name"],
      description: map["description"],
      parts: decode_parts(map["parts"], opts),
      metadata: map["metadata"],
      extensions: map["extensions"],
      kind: map["kind"],
      raw:
        A2A.Types.drop_raw(map, [
          "artifactId",
          "name",
          "description",
          "parts",
          "metadata",
          "extensions",
          "kind"
        ])
    }
  end

  @spec to_map(%__MODULE__{}, keyword()) :: map()
  def to_map(%__MODULE__{} = artifact, opts \\ []) do
    %{}
    |> A2A.Types.put_if("artifactId", artifact.artifact_id)
    |> A2A.Types.put_if("name", artifact.name)
    |> A2A.Types.put_if("description", artifact.description)
    |> A2A.Types.put_if("parts", encode_parts(artifact.parts, opts))
    |> A2A.Types.put_if("metadata", artifact.metadata)
    |> A2A.Types.put_if("extensions", artifact.extensions)
    |> maybe_put_kind(artifact.kind || "artifact", opts)
    |> A2A.Types.merge_raw(artifact.raw)
  end

  defp decode_parts(nil, _opts), do: nil
  defp decode_parts(list, opts), do: Enum.map(list, &A2A.Types.Part.decode(&1, opts))
  defp encode_parts(nil, _opts), do: nil
  defp encode_parts(list, opts), do: Enum.map(list, &A2A.Types.Part.encode(&1, opts))

  defp maybe_put_kind(map, kind, opts) do
    case A2A.Types.version_from_opts(opts) do
      :latest -> map
      _ -> A2A.Types.put_if(map, "kind", kind)
    end
  end
end

defmodule A2A.Types.Task do
  @moduledoc """
  Task payload.
  """

  defstruct [:id, :context_id, :status, :artifacts, :history, :metadata, :kind, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map(), keyword()) :: %__MODULE__{}
  def from_map(map, opts \\ []) do
    %__MODULE__{
      id: map["id"],
      context_id: map["contextId"],
      status: decode_status(map["status"], opts),
      artifacts: decode_artifacts(map["artifacts"], opts),
      history: decode_history(map["history"], opts),
      metadata: map["metadata"],
      kind: map["kind"],
      raw:
        A2A.Types.drop_raw(map, [
          "id",
          "contextId",
          "status",
          "artifacts",
          "history",
          "metadata",
          "kind"
        ])
    }
  end

  @spec to_map(%__MODULE__{}, keyword()) :: map()
  def to_map(%__MODULE__{} = task, opts \\ []) do
    %{}
    |> A2A.Types.put_if("id", task.id)
    |> A2A.Types.put_if("contextId", task.context_id)
    |> A2A.Types.put_if("status", encode_status(task.status, opts))
    |> A2A.Types.put_if("artifacts", encode_artifacts(task.artifacts, opts))
    |> A2A.Types.put_if("history", encode_history(task.history, opts))
    |> A2A.Types.put_if("metadata", task.metadata)
    |> maybe_put_kind(task.kind || "task", opts)
    |> A2A.Types.merge_raw(task.raw)
  end

  defp decode_status(nil, _opts), do: nil
  defp decode_status(map, opts), do: A2A.Types.TaskStatus.from_map(map, opts)
  defp encode_status(nil, _opts), do: nil
  defp encode_status(status, opts), do: A2A.Types.TaskStatus.to_map(status, opts)

  defp decode_artifacts(nil, _opts), do: nil
  defp decode_artifacts(list, opts), do: Enum.map(list, &A2A.Types.Artifact.from_map(&1, opts))
  defp encode_artifacts(nil, _opts), do: nil
  defp encode_artifacts(list, opts), do: Enum.map(list, &A2A.Types.Artifact.to_map(&1, opts))

  defp decode_history(nil, _opts), do: nil
  defp decode_history(list, opts), do: Enum.map(list, &A2A.Types.Message.from_map(&1, opts))
  defp encode_history(nil, _opts), do: nil
  defp encode_history(list, opts), do: Enum.map(list, &A2A.Types.Message.to_map(&1, opts))

  defp maybe_put_kind(map, kind, opts) do
    case A2A.Types.version_from_opts(opts) do
      :latest -> map
      _ -> A2A.Types.put_if(map, "kind", kind)
    end
  end
end

defmodule A2A.Types.TaskStatusUpdateEvent do
  @moduledoc """
  Stream event for task status updates.
  """

  defstruct [:task_id, :context_id, :status, :final, :metadata, :kind, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map(), keyword()) :: %__MODULE__{}
  def from_map(map, opts \\ []) do
    %__MODULE__{
      task_id: map["taskId"],
      context_id: map["contextId"],
      status: decode_status(map["status"], opts),
      final: map["final"],
      metadata: map["metadata"],
      kind: map["kind"],
      raw: A2A.Types.drop_raw(map, ["taskId", "contextId", "status", "final", "metadata", "kind"])
    }
  end

  @spec to_map(%__MODULE__{}, keyword()) :: map()
  def to_map(%__MODULE__{} = event, opts \\ []) do
    %{}
    |> A2A.Types.put_if("taskId", event.task_id)
    |> A2A.Types.put_if("contextId", event.context_id)
    |> A2A.Types.put_if("status", encode_status(event.status, opts))
    |> A2A.Types.put_if("final", event.final)
    |> A2A.Types.put_if("metadata", event.metadata)
    |> maybe_put_kind(event.kind || "status-update", opts)
    |> A2A.Types.merge_raw(event.raw)
  end

  defp decode_status(nil, _opts), do: nil
  defp decode_status(map, opts), do: A2A.Types.TaskStatus.from_map(map, opts)
  defp encode_status(nil, _opts), do: nil
  defp encode_status(status, opts), do: A2A.Types.TaskStatus.to_map(status, opts)

  defp maybe_put_kind(map, kind, opts) do
    case A2A.Types.version_from_opts(opts) do
      :latest -> map
      _ -> A2A.Types.put_if(map, "kind", kind)
    end
  end
end

defmodule A2A.Types.TaskArtifactUpdateEvent do
  @moduledoc """
  Stream event for artifact updates.
  """

  defstruct [:task_id, :context_id, :artifact, :append, :last_chunk, :metadata, :kind, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map(), keyword()) :: %__MODULE__{}
  def from_map(map, opts \\ []) do
    %__MODULE__{
      task_id: map["taskId"],
      context_id: map["contextId"],
      artifact: decode_artifact(map["artifact"], opts),
      append: map["append"],
      last_chunk: map["lastChunk"],
      metadata: map["metadata"],
      kind: map["kind"],
      raw:
        A2A.Types.drop_raw(map, [
          "taskId",
          "contextId",
          "artifact",
          "append",
          "lastChunk",
          "metadata",
          "kind"
        ])
    }
  end

  @spec to_map(%__MODULE__{}, keyword()) :: map()
  def to_map(%__MODULE__{} = event, opts \\ []) do
    %{}
    |> A2A.Types.put_if("taskId", event.task_id)
    |> A2A.Types.put_if("contextId", event.context_id)
    |> A2A.Types.put_if("artifact", encode_artifact(event.artifact, opts))
    |> A2A.Types.put_if("append", event.append)
    |> A2A.Types.put_if("lastChunk", event.last_chunk)
    |> A2A.Types.put_if("metadata", event.metadata)
    |> maybe_put_kind(event.kind || "artifact-update", opts)
    |> A2A.Types.merge_raw(event.raw)
  end

  defp decode_artifact(nil, _opts), do: nil
  defp decode_artifact(map, opts), do: A2A.Types.Artifact.from_map(map, opts)
  defp encode_artifact(nil, _opts), do: nil
  defp encode_artifact(artifact, opts), do: A2A.Types.Artifact.to_map(artifact, opts)

  defp maybe_put_kind(map, kind, opts) do
    case A2A.Types.version_from_opts(opts) do
      :latest -> map
      _ -> A2A.Types.put_if(map, "kind", kind)
    end
  end
end

defmodule A2A.Types.StreamResponse do
  @moduledoc """
  Stream response payload container.
  """

  defstruct [:task, :message, :status_update, :artifact_update]

  @type t :: %__MODULE__{}

  @spec from_map(map(), keyword()) :: %__MODULE__{}
  def from_map(map, opts \\ []) do
    # Handle both wrapped format and unwrapped format with "kind" discriminator
    case map do
      %{"kind" => "message"} ->
        %__MODULE__{message: A2A.Types.Message.from_map(map, opts)}

      %{"kind" => "task"} ->
        %__MODULE__{task: A2A.Types.Task.from_map(map, opts)}

      %{"kind" => "status-update"} ->
        %__MODULE__{status_update: A2A.Types.TaskStatusUpdateEvent.from_map(map, opts)}

      %{"kind" => "artifact-update"} ->
        %__MODULE__{artifact_update: A2A.Types.TaskArtifactUpdateEvent.from_map(map, opts)}

      _ ->
        %__MODULE__{
          task: decode_task(map["task"], opts),
          message: decode_message(map["message"], opts),
          status_update: decode_status_update(map["statusUpdate"], opts),
          artifact_update: decode_artifact_update(map["artifactUpdate"], opts)
        }
    end
  end

  @spec to_map(%__MODULE__{}, keyword()) :: map()
  def to_map(%__MODULE__{} = response, opts \\ []) do
    %{}
    |> A2A.Types.put_if("task", encode_task(response.task, opts))
    |> A2A.Types.put_if("message", encode_message(response.message, opts))
    |> A2A.Types.put_if("statusUpdate", encode_status_update(response.status_update, opts))
    |> A2A.Types.put_if("artifactUpdate", encode_artifact_update(response.artifact_update, opts))
  end

  defp decode_task(nil, _opts), do: nil
  defp decode_task(map, opts), do: A2A.Types.Task.from_map(map, opts)
  defp encode_task(nil, _opts), do: nil
  defp encode_task(task, opts), do: A2A.Types.Task.to_map(task, opts)

  defp decode_message(nil, _opts), do: nil
  defp decode_message(map, opts), do: A2A.Types.Message.from_map(map, opts)
  defp encode_message(nil, _opts), do: nil
  defp encode_message(message, opts), do: A2A.Types.Message.to_map(message, opts)

  defp decode_status_update(nil, _opts), do: nil
  defp decode_status_update(map, opts), do: A2A.Types.TaskStatusUpdateEvent.from_map(map, opts)
  defp encode_status_update(nil, _opts), do: nil
  defp encode_status_update(event, opts), do: A2A.Types.TaskStatusUpdateEvent.to_map(event, opts)

  defp decode_artifact_update(nil, _opts), do: nil

  defp decode_artifact_update(map, opts),
    do: A2A.Types.TaskArtifactUpdateEvent.from_map(map, opts)

  defp encode_artifact_update(nil, _opts), do: nil

  defp encode_artifact_update(event, opts),
    do: A2A.Types.TaskArtifactUpdateEvent.to_map(event, opts)
end

defmodule A2A.Types.StreamError do
  @moduledoc """
  Stream error wrapper for streaming responses.
  """

  defstruct [:error, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: %__MODULE__{}
  def from_map(map) when is_map(map) do
    %__MODULE__{error: A2A.Error.from_map(map), raw: map}
  end
end
