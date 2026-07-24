defmodule A2A.Server.Headers do
  @moduledoc """
  Header parsing and response utilities for server plugs.
  """

  @spec extensions(Plug.Conn.t()) :: list(A2A.Extension.t())
  def extensions(conn) do
    conn
    |> header_values(["a2a-extensions", "x-a2a-extensions"])
    |> A2A.Extension.parse_header()
  end

  @spec version(Plug.Conn.t()) :: String.t() | nil
  def version(conn) do
    header = conn |> header_values(["a2a-version"]) |> List.first()
    header || query_version(conn)
  end

  @spec request_id(Plug.Conn.t()) :: String.t()
  def request_id(conn) do
    conn.assigns[:request_id] ||
      case header_values(conn, ["x-request-id"]) do
        [value | _] -> value
        [] -> A2A.Context.generate_id()
      end
  end

  @spec ensure_request_id(Plug.Conn.t()) :: Plug.Conn.t()
  def ensure_request_id(conn) do
    request_id = request_id(conn)

    conn
    |> Plug.Conn.assign(:request_id, request_id)
    |> Plug.Conn.put_resp_header("x-request-id", request_id)
  end

  @spec validate_version(Plug.Conn.t(), A2A.Types.version()) :: :ok | {:error, A2A.Error.t()}
  def validate_version(conn, version) do
    case {A2A.Types.normalize_version(version), version(conn)} do
      {:v1_0, "1.0"} ->
        :ok

      {:v1_0, value} ->
        {:error,
         A2A.Error.new(:version_not_supported, "Unsupported version #{value || "0.3"}",
           data: %{"supportedVersions" => ["1.0"]}
         )}

      {:v0_3, value} when value in [nil, "0.3", "0.3.0"] ->
        :ok

      {:v0_3, value} ->
        {:error, A2A.Error.new(:version_not_supported, "Unsupported version #{value}")}
    end
  end

  @spec put_extensions(Plug.Conn.t(), list(A2A.Extension.t())) :: Plug.Conn.t()
  def put_extensions(conn, extensions) do
    case extensions do
      [] -> conn
      list -> Plug.Conn.put_resp_header(conn, "a2a-extensions", A2A.Extension.format_header(list))
    end
  end

  defp header_values(conn, keys) do
    Enum.flat_map(keys, &Plug.Conn.get_req_header(conn, &1))
  end

  defp query_version(%Plug.Conn{query_params: %Plug.Conn.Unfetched{}}), do: nil

  defp query_version(conn) do
    conn.query_params["A2A-Version"] || conn.query_params["a2a-version"]
  end
end
