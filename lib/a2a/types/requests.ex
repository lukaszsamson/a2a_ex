defmodule A2A.Types.PushNotificationConfig do
  @moduledoc """
  Push notification configuration payload.
  """

  defstruct [:id, :url, :token, :authentication, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: %__MODULE__{}
  def from_map(map) do
    %__MODULE__{
      id: map["id"],
      url: map["url"],
      token: map["token"],
      authentication: A2A.Types.AuthenticationInfo.from_map(map["authentication"]),
      raw: A2A.Types.drop_raw(map, ["id", "url", "token", "authentication"])
    }
  end

  @spec to_map(%__MODULE__{}) :: map()
  def to_map(%__MODULE__{} = config) do
    %{}
    |> A2A.Types.put_if("id", config.id)
    |> A2A.Types.put_if("url", config.url)
    |> A2A.Types.put_if("token", config.token)
    |> A2A.Types.put_if(
      "authentication",
      A2A.Types.AuthenticationInfo.to_map(config.authentication)
    )
    |> A2A.Types.merge_raw(config.raw)
  end
end

defmodule A2A.Types.SendMessageConfiguration do
  @moduledoc """
  Optional send message configuration.
  """

  defstruct [:blocking, :history_length, :accepted_output_modes, :push_notification_config, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(nil | map()) :: %__MODULE__{} | nil
  def from_map(nil), do: nil

  def from_map(map) do
    %__MODULE__{
      blocking: map["blocking"],
      history_length: map["historyLength"],
      accepted_output_modes: map["acceptedOutputModes"],
      push_notification_config: decode_config(map["pushNotificationConfig"]),
      raw:
        A2A.Types.drop_raw(map, [
          "blocking",
          "historyLength",
          "acceptedOutputModes",
          "pushNotificationConfig"
        ])
    }
  end

  @spec to_map(nil | %__MODULE__{}) :: map() | nil
  def to_map(nil), do: nil

  def to_map(%__MODULE__{} = config) do
    %{}
    |> A2A.Types.put_if("blocking", config.blocking)
    |> A2A.Types.put_if("historyLength", config.history_length)
    |> A2A.Types.put_if("acceptedOutputModes", config.accepted_output_modes)
    |> A2A.Types.put_if("pushNotificationConfig", encode_config(config.push_notification_config))
    |> A2A.Types.merge_raw(config.raw)
  end

  defp decode_config(nil), do: nil
  defp decode_config(map), do: A2A.Types.PushNotificationConfig.from_map(map)
  defp encode_config(nil), do: nil
  defp encode_config(config), do: A2A.Types.PushNotificationConfig.to_map(config)
end

defmodule A2A.Types.SendMessageRequest do
  @moduledoc """
  Send message request payload.
  """

  defstruct [:message, :configuration, :metadata, :tenant, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map(), keyword()) :: %__MODULE__{}
  def from_map(map, opts \\ []) do
    %__MODULE__{
      message: decode_message(map["message"], opts),
      configuration: decode_configuration(map["configuration"]),
      metadata: map["metadata"],
      tenant: map["tenant"],
      raw: A2A.Types.drop_raw(map, ["message", "configuration", "metadata", "tenant"])
    }
  end

  @spec to_map(%__MODULE__{}, keyword()) :: map()
  def to_map(%__MODULE__{} = request, opts \\ []) do
    %{}
    |> A2A.Types.put_if("message", encode_message(request.message, opts))
    |> A2A.Types.put_if("configuration", encode_configuration(request.configuration))
    |> A2A.Types.put_if("metadata", request.metadata)
    |> A2A.Types.put_if("tenant", request.tenant)
    |> A2A.Types.merge_raw(request.raw)
  end

  defp decode_message(nil, _opts), do: nil
  defp decode_message(map, opts), do: A2A.Types.Message.from_map(map, opts)
  defp encode_message(nil, _opts), do: nil
  defp encode_message(message, opts), do: A2A.Types.Message.to_map(message, opts)

  defp decode_configuration(nil), do: nil
  defp decode_configuration(map), do: A2A.Types.SendMessageConfiguration.from_map(map)
  defp encode_configuration(nil), do: nil
  defp encode_configuration(config), do: A2A.Types.SendMessageConfiguration.to_map(config)
end

defmodule A2A.Types.SendMessageResponse do
  @moduledoc """
  Send message response payload.
  """

  defstruct [:task, :message, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map(), keyword()) :: %__MODULE__{}
  def from_map(map, opts \\ []) do
    # Handle both wrapped format ({"task": {...}} or {"message": {...}})
    # and unwrapped format with "kind" discriminator ({"kind": "message", ...})
    case map do
      %{"kind" => "message"} ->
        %__MODULE__{message: A2A.Types.Message.from_map(map, opts), raw: %{}}

      %{"kind" => "task"} ->
        %__MODULE__{task: A2A.Types.Task.from_map(map, opts), raw: %{}}

      _ ->
        %__MODULE__{
          task: decode_task(map["task"], opts),
          message: decode_message(map["message"], opts),
          raw: A2A.Types.drop_raw(map, ["task", "message"])
        }
    end
  end

  @spec to_map(%__MODULE__{}, keyword()) :: map()
  def to_map(%__MODULE__{} = response, opts \\ []) do
    %{}
    |> A2A.Types.put_if("task", encode_task(response.task, opts))
    |> A2A.Types.put_if("message", encode_message(response.message, opts))
    |> A2A.Types.merge_raw(response.raw)
  end

  defp decode_task(nil, _opts), do: nil
  defp decode_task(map, opts), do: A2A.Types.Task.from_map(map, opts)
  defp encode_task(nil, _opts), do: nil
  defp encode_task(task, opts), do: A2A.Types.Task.to_map(task, opts)

  defp decode_message(nil, _opts), do: nil
  defp decode_message(map, opts), do: A2A.Types.Message.from_map(map, opts)
  defp encode_message(nil, _opts), do: nil
  defp encode_message(message, opts), do: A2A.Types.Message.to_map(message, opts)
end

defmodule A2A.Types.ListTasksRequest do
  @moduledoc """
  List tasks request payload.
  """

  defstruct [:context_id, :status, :page_size, :page_token, :updated_after, :include_artifacts]

  @type t :: %__MODULE__{}

  @spec from_map(map(), keyword()) :: %__MODULE__{}
  def from_map(map, opts \\ []) do
    %__MODULE__{
      context_id: map["contextId"],
      status: A2A.TaskState.decode(map["status"], opts),
      page_size: A2A.Types.to_int(map["pageSize"]),
      page_token: map["pageToken"],
      updated_after: A2A.Types.decode_datetime(map["updatedAfter"]),
      include_artifacts: map["includeArtifacts"]
    }
  end

  @spec to_map(%__MODULE__{}, keyword()) :: map()
  def to_map(%__MODULE__{} = request, opts \\ []) do
    %{}
    |> A2A.Types.put_if("contextId", request.context_id)
    |> A2A.Types.put_if("status", A2A.TaskState.encode(request.status, opts))
    |> A2A.Types.put_if("pageSize", request.page_size)
    |> A2A.Types.put_if("pageToken", request.page_token)
    |> A2A.Types.put_if("updatedAfter", A2A.Types.encode_datetime(request.updated_after))
    |> A2A.Types.put_if("includeArtifacts", request.include_artifacts)
  end
end

defmodule A2A.Types.ListTasksResponse do
  @moduledoc """
  List tasks response payload.
  """

  defstruct [:tasks, :next_page_token, :total_size, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map(), keyword()) :: %__MODULE__{}
  def from_map(map, opts \\ []) do
    %__MODULE__{
      tasks: decode_tasks(map["tasks"], opts),
      next_page_token: map["nextPageToken"],
      total_size: map["totalSize"],
      raw: A2A.Types.drop_raw(map, ["tasks", "nextPageToken", "totalSize"])
    }
  end

  @spec to_map(%__MODULE__{}, keyword()) :: map()
  def to_map(%__MODULE__{} = response, opts \\ []) do
    %{}
    |> A2A.Types.put_if("tasks", encode_tasks(response.tasks, opts))
    |> A2A.Types.put_if("nextPageToken", response.next_page_token)
    |> A2A.Types.put_if("totalSize", response.total_size)
    |> A2A.Types.merge_raw(response.raw)
  end

  defp decode_tasks(nil, _opts), do: nil
  defp decode_tasks(list, opts), do: Enum.map(list, &A2A.Types.Task.from_map(&1, opts))
  defp encode_tasks(nil, _opts), do: nil
  defp encode_tasks(list, opts), do: Enum.map(list, &A2A.Types.Task.to_map(&1, opts))
end

defmodule A2A.Types.GetTaskRequest do
  @moduledoc """
  Get task request payload.
  """

  defstruct [:name, :history_length]

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: %__MODULE__{}
  def from_map(map) do
    %__MODULE__{
      name: map["name"],
      history_length: map["historyLength"]
    }
  end

  @spec to_map(%__MODULE__{}) :: map()
  def to_map(%__MODULE__{} = request) do
    %{}
    |> A2A.Types.put_if("name", request.name)
    |> A2A.Types.put_if("historyLength", request.history_length)
  end
end

defmodule A2A.Types.CancelTaskRequest do
  @moduledoc """
  Cancel task request payload.
  """

  defstruct [:name]

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: %__MODULE__{}
  def from_map(map) do
    %__MODULE__{
      name: map["name"]
    }
  end

  @spec to_map(%__MODULE__{}) :: map()
  def to_map(%__MODULE__{} = request) do
    %{}
    |> A2A.Types.put_if("name", request.name)
  end
end
