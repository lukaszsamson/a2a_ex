defmodule A2A.Server do
  @moduledoc """
  Server helpers for building request context.
  """

  @spec build_ctx(map(), String.t(), list()) :: map()
  def build_ctx(identity, request_id, extensions \\ []) do
    %{identity: identity, request_id: request_id, extensions: extensions}
  end
end
