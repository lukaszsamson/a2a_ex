defmodule A2A.Extension do
  @moduledoc """
  Extension header and metadata helpers.
  """

  @type t :: String.t()

  @spec metadata_get(map() | nil, String.t(), any(), any()) :: any()
  def metadata_get(metadata, uri, key, default \\ nil) do
    metadata
    |> Map.get(uri, %{})
    |> Map.get(key, default)
  end

  @spec metadata_put(map() | nil, String.t(), any(), any()) :: map()
  def metadata_put(metadata, uri, key, value) do
    metadata = metadata || %{}
    extension_meta = metadata |> Map.get(uri, %{}) |> Map.put(key, value)
    Map.put(metadata, uri, extension_meta)
  end

  @spec parse_header(nil | String.t() | list(String.t())) :: list(String.t())
  def parse_header(nil), do: []
  def parse_header([]), do: []
  def parse_header(headers) when is_list(headers), do: parse_header(Enum.join(headers, ","))

  def parse_header(header) when is_binary(header) do
    header
    |> String.replace(",", " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  @spec format_header(list(String.t())) :: String.t()
  def format_header(extensions) when is_list(extensions) do
    extensions
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  @spec missing_required(list(String.t()) | nil, list(String.t())) :: list(String.t())
  def missing_required(requested, required) do
    requested = MapSet.new(requested || [])

    required
    |> Enum.reject(&MapSet.member?(requested, &1))
  end
end
