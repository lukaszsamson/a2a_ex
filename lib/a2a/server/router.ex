defmodule A2A.Server.Router do
  @moduledoc """
  Router helpers for mounting A2A plugs in Plug or Phoenix routers.
  """

  @doc """
  Mount the REST plug at the given path.

  The forwarded path is already stripped by the router, so the `base_path`
  defaults to an empty string unless you pass it explicitly.
  """
  defmacro rest(path, opts \\ []) do
    quote do
      forward(
        unquote(path),
        to: A2A.Server.REST.Plug,
        init_opts: Keyword.put_new(unquote(opts), :base_path, "")
      )
    end
  end

  @doc """
  Mount the JSON-RPC plug at the given path.
  """
  defmacro jsonrpc(path, opts \\ []) do
    quote do
      forward(unquote(path), to: A2A.Server.JSONRPC.Plug, init_opts: unquote(opts))
    end
  end
end
