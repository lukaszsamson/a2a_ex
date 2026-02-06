defmodule A2A.Types do
  @moduledoc """
  Shared helpers for A2A type encoding/decoding.
  """

  @type version :: :v0_3 | :latest
  @type wire_format :: :spec_json | :proto_json

  @spec version_from_opts(keyword()) :: version()
  def version_from_opts(opts) do
    Keyword.get(opts, :version, :v0_3)
  end

  @spec wire_format_from_opts(keyword()) :: wire_format()
  def wire_format_from_opts(opts) do
    case Keyword.get(opts, :wire_format) do
      :spec_json ->
        :spec_json

      :proto_json ->
        :proto_json

      _ ->
        case version_from_opts(opts) do
          :latest -> :proto_json
          _ -> :spec_json
        end
    end
  end

  @spec decode_datetime(nil | String.t()) :: DateTime.t() | nil
  def decode_datetime(nil), do: nil

  def decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  @spec encode_datetime(nil | DateTime.t()) :: String.t() | nil
  def encode_datetime(nil), do: nil
  def encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  @spec drop_raw(map(), list()) :: map()
  def drop_raw(map, known_keys) do
    Map.drop(map, known_keys)
  end

  @spec merge_raw(map(), map() | nil) :: map()
  def merge_raw(map, raw) when is_map(raw), do: Map.merge(raw, map)
  def merge_raw(map, _raw), do: map

  @spec put_if(map(), any(), any()) :: map()
  def put_if(map, _key, nil), do: map
  def put_if(map, _key, []), do: map
  def put_if(map, key, value), do: Map.put(map, key, value)

  @spec to_int(nil | String.t() | integer()) :: integer() | nil
  def to_int(nil), do: nil

  def to_int(value) when is_integer(value), do: value

  def to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end
end
