defmodule A2A.TaskStore do
  @moduledoc """
  Behaviour for task storage backends used by the server.
  """

  @callback put_task(term(), A2A.Types.Task.t()) :: :ok | {:error, term()}
  @callback get_task(term(), String.t()) :: {:ok, A2A.Types.Task.t()} | {:error, term()}
  @callback list_tasks(term(), keyword() | map()) ::
              {:ok,
               %{
                 tasks: list(A2A.Types.Task.t()),
                 next_page_token: String.t() | nil,
                 total_size: non_neg_integer() | nil
               }}
              | {:error, term()}
  @callback update_task(term(), String.t(), (A2A.Types.Task.t() -> A2A.Types.Task.t())) ::
              {:ok, A2A.Types.Task.t()} | {:error, term()}
end
