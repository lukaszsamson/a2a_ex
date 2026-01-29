defmodule A2A.Server.AgentCardPlug do
  @moduledoc """
  Serves an agent card at the well-known discovery URI.
  """

  import Plug.Conn

  @spec init(keyword()) :: map()
  def init(opts) do
    %{
      card: Keyword.get(opts, :card),
      card_fun: Keyword.get(opts, :card_fun),
      path: Keyword.get(opts, :path, "/.well-known/agent-card.json"),
      legacy_path: Keyword.get(opts, :legacy_path),
      version: Keyword.get(opts, :version, :v0_3)
    }
  end

  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, opts) do
    if match_path?(conn.request_path, opts) and conn.method == "GET" do
      response =
        case build_card(opts) do
          {:ok, card} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              200,
              Jason.encode!(A2A.Types.AgentCard.to_map(card, version: opts.version))
            )

          {:error, error} ->
            conn
            |> put_resp_content_type("application/json")
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
end
