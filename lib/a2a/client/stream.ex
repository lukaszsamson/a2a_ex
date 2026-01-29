defmodule A2A.Client.Stream do
  @moduledoc """
  Enumerable wrapper for streaming responses.

  Halting enumeration will cancel underlying Req streams automatically. Use
  `cancel/1` for explicit early cancellation.
  """

  defstruct [:enum, :cancel]

  @type t :: %__MODULE__{enum: Enumerable.t(), cancel: (-> any()) | nil}

  @spec new(Enumerable.t(), (-> any()) | nil) :: t()
  def new(enum, cancel_fun \\ nil), do: %__MODULE__{enum: enum, cancel: cancel_fun}

  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{cancel: cancel_fun}) when is_function(cancel_fun, 0) do
    cancel_fun.()
    :ok
  end

  def cancel(_stream), do: :ok
end

defimpl Enumerable, for: A2A.Client.Stream do
  def reduce(%A2A.Client.Stream{enum: enum}, acc, fun) do
    Enumerable.reduce(enum, acc, fun)
  end

  def count(%A2A.Client.Stream{enum: enum}), do: Enumerable.count(enum)
  def member?(%A2A.Client.Stream{enum: enum}, value), do: Enumerable.member?(enum, value)
  def slice(%A2A.Client.Stream{enum: enum}), do: Enumerable.slice(enum)
end
