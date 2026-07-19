defmodule A2A.Server.AgentCardPlug do
  @moduledoc """
  Serves an agent card at the well-known discovery URI.

  V1.0 cards include a content-derived `ETag` and a configurable `Cache-Control`
  header by default. Set `cache_control: false` to emit `no-store`, or
  `etag: false` to omit the validator.
  """

  import Plug.Conn

  @spec init(keyword()) :: map()
  def init(opts) do
    version = opts |> Keyword.get(:version, :v0_3) |> A2A.Types.normalize_version()

    %{
      card: Keyword.get(opts, :card),
      card_fun: Keyword.get(opts, :card_fun),
      path: Keyword.get(opts, :path, "/.well-known/agent-card.json"),
      legacy_path: Keyword.get(opts, :legacy_path),
      version: version,
      cache_control: Keyword.get(opts, :cache_control, default_cache_control(version)),
      etag: Keyword.get(opts, :etag, version == :v1_0)
    }
  end

  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, opts) do
    if match_path?(conn.request_path, opts) and conn.method == "GET" do
      response =
        case build_card(opts) do
          {:ok, card} ->
            body = Jason.encode!(A2A.Types.AgentCard.to_map(card, version: opts.version))
            etag = build_etag(body, opts.etag)

            conn =
              conn
              |> put_cache_control(opts.cache_control)
              |> put_etag(etag)

            if not_modified?(conn, etag) do
              send_resp(conn, 304, "")
            else
              conn
              |> put_resp_content_type(media_type(opts.version))
              |> send_resp(200, body)
            end

          {:error, error} ->
            conn
            |> put_resp_content_type(media_type(opts.version))
            |> send_resp(500, Jason.encode!(%{"error" => A2A.Error.to_map(error)}))
        end

      halt(response)
    else
      conn
    end
  end

  defp match_path?(path, %{path: path}), do: true
  defp match_path?(path, %{legacy_path: path}) when is_binary(path), do: true
  defp match_path?(_path, _opts), do: false

  defp build_card(%{card: %A2A.Types.AgentCard{} = card}), do: {:ok, card}

  defp build_card(%{card_fun: fun}) when is_function(fun, 0) do
    case fun.() do
      %A2A.Types.AgentCard{} = card -> {:ok, card}
      {:ok, %A2A.Types.AgentCard{} = card} -> {:ok, card}
      {:error, %A2A.Error{} = error} -> {:error, error}
      _ -> {:error, A2A.Error.new(:invalid_agent_response, "Invalid agent card")}
    end
  end

  defp build_card(_opts),
    do: {:error, A2A.Error.new(:invalid_agent_response, "Agent card not configured")}

  defp default_cache_control(:v1_0), do: "public, max-age=300"
  defp default_cache_control(_version), do: nil

  defp media_type(:v1_0), do: "application/a2a+json"
  defp media_type(_version), do: "application/json"

  defp build_etag(_body, false), do: nil
  defp build_etag(_body, value) when is_binary(value), do: quote_etag(value)

  defp build_etag(body, true) do
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    quote_etag(digest)
  end

  defp quote_etag("W/\"" <> _ = etag), do: etag
  defp quote_etag(<<?\", _::binary>> = etag), do: etag
  defp quote_etag(etag), do: ~s("#{etag}")

  defp put_cache_control(conn, value) when is_binary(value),
    do: put_resp_header(conn, "cache-control", value)

  defp put_cache_control(conn, false), do: put_resp_header(conn, "cache-control", "no-store")
  defp put_cache_control(conn, _value), do: conn

  defp put_etag(conn, etag) when is_binary(etag), do: put_resp_header(conn, "etag", etag)
  defp put_etag(conn, _etag), do: conn

  defp not_modified?(_conn, nil), do: false

  defp not_modified?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.any?(fn candidate -> candidate == "*" or weak_etag(candidate) == weak_etag(etag) end)
  end

  defp weak_etag("W/" <> etag), do: etag
  defp weak_etag(etag), do: etag
end
