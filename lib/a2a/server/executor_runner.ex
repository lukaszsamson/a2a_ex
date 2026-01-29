defmodule A2A.Server.ExecutorRunner do
  @moduledoc """
  Helper for invoking executor callbacks with optional module options.
  """

  @spec call(module() | {module(), term()}, atom(), list()) :: term()
  def call(executor, fun, args) when is_list(args) do
    case executor do
      {module, exec_opts} when is_atom(module) ->
        if function_exported?(module, fun, length(args) + 1) do
          apply(module, fun, [exec_opts | args])
        else
          apply(module, fun, args)
        end

      module when is_atom(module) ->
        apply(module, fun, args)
    end
  end

  @spec exported?(module() | {module(), term()}, atom(), non_neg_integer()) :: boolean()
  def exported?(executor, fun, arity) do
    case executor do
      {module, _exec_opts} when is_atom(module) ->
        function_exported?(module, fun, arity + 1) or function_exported?(module, fun, arity)

      module when is_atom(module) ->
        function_exported?(module, fun, arity)

      _ ->
        false
    end
  end
end
