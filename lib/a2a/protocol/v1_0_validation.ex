defmodule A2A.Protocol.V1_0.Validation do
  @moduledoc false

  @valid_roles ["ROLE_USER", "ROLE_AGENT"]
  @content_fields ["text", "raw", "url", "data"]

  def send_message(%{"message" => message}) when is_map(message), do: message(message)
  def send_message(_), do: {:error, "message is required"}

  def list_tasks(params) when is_map(params) do
    with :ok <- bounded_integer(params, "pageSize", 1, 100),
         :ok <- non_negative_integer(params, "historyLength") do
      :ok
    end
  end

  def get_task(params) when is_map(params), do: non_negative_integer(params, "historyLength")

  def push_config(%{"url" => url}) when is_binary(url) and url != "" do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> :ok
      _ -> {:error, "url must be an absolute HTTP(S) URL"}
    end
  end

  def push_config(_), do: {:error, "url is required"}

  defp message(message) do
    with :ok <- required_string(message, "messageId"),
         :ok <- valid_role(message),
         :ok <- parts(message) do
      :ok
    end
  end

  defp valid_role(%{"role" => role}) when role in @valid_roles, do: :ok
  defp valid_role(_), do: {:error, "role must be ROLE_USER or ROLE_AGENT"}

  defp parts(%{"parts" => parts}) when is_list(parts) and parts != [] do
    Enum.reduce_while(parts, :ok, fn part, :ok ->
      case part(part) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp parts(_), do: {:error, "parts must contain at least one part"}

  defp part(part) when is_map(part) do
    present = Enum.count(@content_fields, &Map.has_key?(part, &1))
    if present == 1, do: :ok, else: {:error, "each part must set exactly one content field"}
  end

  defp part(_), do: {:error, "each part must be an object"}

  defp required_string(map, field) do
    case map[field] do
      value when is_binary(value) and value != "" -> :ok
      _ -> {:error, "#{field} is required"}
    end
  end

  defp bounded_integer(map, field, min, max) do
    case value(map, field) do
      nil -> :ok
      integer when is_integer(integer) and integer >= min and integer <= max -> :ok
      _ -> {:error, "#{field} must be between #{min} and #{max}"}
    end
  end

  defp non_negative_integer(map, field) do
    case value(map, field) do
      nil -> :ok
      integer when is_integer(integer) and integer >= 0 -> :ok
      _ -> {:error, "#{field} must be a non-negative integer"}
    end
  end

  defp value(map, field) do
    case Map.get(map, field) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> value
        end

      value ->
        value
    end
  end
end
