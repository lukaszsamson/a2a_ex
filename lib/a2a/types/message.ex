defmodule A2A.Types.TextPart do
  @moduledoc """
  Text part payload.
  """

  defstruct [:text, :metadata, :kind, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: %__MODULE__{}
  def from_map(map) do
    %__MODULE__{
      text: map["text"],
      metadata: map["metadata"],
      kind: map["kind"],
      raw: A2A.Types.drop_raw(map, ["text", "metadata", "kind"])
    }
  end
end

defmodule A2A.Types.FilePart do
  @moduledoc """
  File part payload.
  """

  defstruct [:name, :media_type, :file_with_bytes, :file_with_uri, :metadata, :kind, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: %__MODULE__{}
  def from_map(map) do
    %__MODULE__{
      name: map["name"],
      media_type: map["mediaType"] || map["mimeType"],
      file_with_bytes: map["fileWithBytes"],
      file_with_uri: map["fileWithUri"],
      metadata: map["metadata"],
      kind: map["kind"],
      raw:
        A2A.Types.drop_raw(map, [
          "name",
          "mediaType",
          "fileWithBytes",
          "fileWithUri",
          "metadata",
          "kind"
        ])
    }
  end
end

defmodule A2A.Types.DataPart do
  @moduledoc """
  Data part payload.
  """

  defstruct [:data, :metadata, :kind, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: %__MODULE__{}
  def from_map(map) do
    %__MODULE__{
      data: map["data"],
      metadata: map["metadata"],
      kind: map["kind"],
      raw: A2A.Types.drop_raw(map, ["data", "metadata", "kind"])
    }
  end
end

defmodule A2A.Types.Part do
  @moduledoc """
  Part discriminator helpers.
  """

  @spec decode(map(), keyword()) ::
          %A2A.Types.TextPart{} | %A2A.Types.FilePart{} | %A2A.Types.DataPart{}
  def decode(map, _opts \\ []) do
    kind = map["kind"]

    cond do
      kind == "text" or Map.has_key?(map, "text") ->
        A2A.Types.TextPart.from_map(map)

      kind == "file" or Map.has_key?(map, "fileWithBytes") or Map.has_key?(map, "fileWithUri") ->
        A2A.Types.FilePart.from_map(map)

      kind == "data" or Map.has_key?(map, "data") ->
        A2A.Types.DataPart.from_map(map)

      true ->
        A2A.Types.DataPart.from_map(map)
    end
  end

  @spec encode(
          %A2A.Types.TextPart{} | %A2A.Types.FilePart{} | %A2A.Types.DataPart{},
          keyword()
        ) :: map()
  def encode(%A2A.Types.TextPart{} = part, opts) do
    %{}
    |> A2A.Types.put_if("text", part.text)
    |> A2A.Types.put_if("metadata", part.metadata)
    |> maybe_put_kind(part.kind || "text", opts)
    |> A2A.Types.merge_raw(part.raw)
  end

  def encode(%A2A.Types.FilePart{} = part, opts) do
    media_type_key =
      case A2A.Types.wire_format_from_opts(opts) do
        :proto_json -> "mimeType"
        _ -> "mediaType"
      end

    %{}
    |> A2A.Types.put_if("name", part.name)
    |> A2A.Types.put_if(media_type_key, part.media_type)
    |> A2A.Types.put_if("fileWithBytes", part.file_with_bytes)
    |> A2A.Types.put_if("fileWithUri", part.file_with_uri)
    |> A2A.Types.put_if("metadata", part.metadata)
    |> maybe_put_kind(part.kind || "file", opts)
    |> A2A.Types.merge_raw(part.raw)
  end

  def encode(%A2A.Types.DataPart{} = part, opts) do
    data = encode_data(part.data, opts)

    %{}
    |> A2A.Types.put_if("data", data)
    |> A2A.Types.put_if("metadata", part.metadata)
    |> maybe_put_kind(part.kind || "data", opts)
    |> A2A.Types.merge_raw(part.raw)
  end

  defp encode_data(data, opts) do
    allow_non_object = Keyword.get(opts, :allow_non_object_data, false)

    if is_map(data) or allow_non_object do
      data
    else
      raise ArgumentError, "DataPart.data must be a map"
    end
  end

  defp maybe_put_kind(map, kind, opts) do
    case A2A.Types.wire_format_from_opts(opts) do
      :proto_json -> map
      _ -> A2A.Types.put_if(map, "kind", kind)
    end
  end
end

defmodule A2A.Types.Message do
  @moduledoc """
  A2A message payload.
  """

  defstruct [
    :message_id,
    :role,
    :context_id,
    :task_id,
    :reference_task_ids,
    :parts,
    :metadata,
    :extensions,
    :kind,
    :raw
  ]

  @type t :: %__MODULE__{}

  @spec from_map(map(), keyword()) :: %__MODULE__{}
  def from_map(map, _opts \\ []) do
    parts = map["parts"] || map["content"]

    %__MODULE__{
      message_id: map["messageId"],
      role: decode_role(map["role"]),
      context_id: map["contextId"],
      task_id: map["taskId"],
      reference_task_ids: map["referenceTaskIds"],
      parts: decode_parts(parts),
      metadata: map["metadata"],
      extensions: map["extensions"],
      kind: map["kind"],
      raw:
        A2A.Types.drop_raw(map, [
          "messageId",
          "role",
          "contextId",
          "taskId",
          "referenceTaskIds",
          "parts",
          "content",
          "metadata",
          "extensions",
          "kind"
        ])
    }
  end

  @spec to_map(%__MODULE__{}, keyword()) :: map()
  def to_map(%__MODULE__{} = message, opts \\ []) do
    parts_field =
      case A2A.Types.wire_format_from_opts(opts) do
        :proto_json -> "content"
        _ -> "parts"
      end

    %{}
    |> A2A.Types.put_if("messageId", message.message_id)
    |> A2A.Types.put_if("role", encode_role(message.role, opts))
    |> A2A.Types.put_if("contextId", message.context_id)
    |> A2A.Types.put_if("taskId", message.task_id)
    |> A2A.Types.put_if("referenceTaskIds", message.reference_task_ids)
    |> A2A.Types.put_if(parts_field, encode_parts(message.parts, opts))
    |> A2A.Types.put_if("metadata", message.metadata)
    |> A2A.Types.put_if("extensions", message.extensions)
    |> maybe_put_kind(message.kind || "message", opts)
    |> A2A.Types.merge_raw(message.raw)
  end

  defp decode_parts(nil), do: nil
  defp decode_parts(list), do: Enum.map(list, &A2A.Types.Part.decode/1)

  defp encode_parts(nil, _opts), do: nil
  defp encode_parts(list, opts), do: Enum.map(list, &A2A.Types.Part.encode(&1, opts))

  defp decode_role("user"), do: :user
  defp decode_role("agent"), do: :agent
  defp decode_role("ROLE_USER"), do: :user
  defp decode_role("ROLE_AGENT"), do: :agent
  defp decode_role(role), do: role

  defp encode_role(role, opts) do
    case A2A.Types.wire_format_from_opts(opts) do
      :proto_json ->
        case role do
          :user -> "ROLE_USER"
          :agent -> "ROLE_AGENT"
          _ -> role
        end

      _ ->
        case role do
          :user -> "user"
          :agent -> "agent"
          _ -> role
        end
    end
  end

  defp maybe_put_kind(map, kind, opts) do
    case A2A.Types.wire_format_from_opts(opts) do
      :proto_json -> map
      _ -> A2A.Types.put_if(map, "kind", kind)
    end
  end
end
