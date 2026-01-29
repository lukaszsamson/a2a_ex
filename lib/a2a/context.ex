defmodule A2A.Context do
  @moduledoc """
  Helpers for ensuring message and task context identifiers.
  """

  @spec ensure_context_id(A2A.Types.Message.t()) :: {A2A.Types.Message.t(), String.t()}
  def ensure_context_id(%A2A.Types.Message{context_id: nil} = message) do
    context_id = generate_id()
    {%{message | context_id: context_id}, context_id}
  end

  @spec ensure_context_id(A2A.Types.Message.t()) :: {A2A.Types.Message.t(), String.t()}
  def ensure_context_id(%A2A.Types.Message{context_id: context_id} = message) do
    {message, context_id}
  end

  @spec ensure_context_id(A2A.Types.Task.t()) :: {A2A.Types.Task.t(), String.t()}
  def ensure_context_id(%A2A.Types.Task{context_id: nil} = task) do
    context_id = generate_id()
    {%{task | context_id: context_id}, context_id}
  end

  @spec ensure_context_id(A2A.Types.Task.t()) :: {A2A.Types.Task.t(), String.t()}
  def ensure_context_id(%A2A.Types.Task{context_id: context_id} = task) do
    {task, context_id}
  end

  @spec generate_id() :: String.t()
  def generate_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
