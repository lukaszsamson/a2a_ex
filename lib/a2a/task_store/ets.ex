defmodule A2A.TaskStore.ETS do
  @moduledoc """
  ETS-backed task store for local testing and small deployments.
  """

  @lock_table :a2a_task_store_locks

  @behaviour A2A.TaskStore

  @spec init(keyword()) :: {:ok, atom() | reference()}
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [:set, :public, :named_table])
        ensure_lock_table()
        {:ok, name}

      _tid ->
        ensure_lock_table()
        {:ok, name}
    end
  end

  @spec put_task(atom() | reference(), A2A.Types.Task.t()) :: :ok
  def put_task(table, %A2A.Types.Task{} = task) do
    true = :ets.insert(table, {task.id, task})
    :ok
  end

  @spec get_task(atom() | reference(), String.t()) ::
          {:ok, A2A.Types.Task.t()} | {:error, :not_found}
  def get_task(table, task_id) do
    case :ets.lookup(table, task_id) do
      [{^task_id, task}] -> {:ok, task}
      [] -> {:error, :not_found}
    end
  end

  @spec list_tasks(atom() | reference(), keyword() | map()) ::
          {:ok,
           %{
             tasks: list(A2A.Types.Task.t()),
             next_page_token: String.t() | nil,
             total_size: non_neg_integer()
           }}
  def list_tasks(table, opts) do
    opts = normalize_opts(opts)

    tasks =
      :ets.tab2list(table)
      |> Enum.map(fn {_id, task} -> task end)
      |> filter_tasks(opts)
      |> sort_tasks()
      |> maybe_strip_artifacts(opts)

    total_size = length(tasks)
    {page, next_token} = paginate(tasks, opts)
    {:ok, %{tasks: page, next_page_token: next_token, total_size: total_size}}
  end

  @spec update_task(atom() | reference(), String.t(), (A2A.Types.Task.t() -> A2A.Types.Task.t())) ::
          {:ok, A2A.Types.Task.t()} | {:error, term()}
  def update_task(table, task_id, fun) do
    do_update_task(table, task_id, fun, 0)
  end

  defp do_update_task(table, task_id, fun, attempts) do
    lock_table = ensure_lock_table()
    lock_key = {table, task_id}

    case :ets.insert_new(lock_table, {lock_key, self()}) do
      true ->
        try do
          case get_task(table, task_id) do
            {:ok, task} ->
              updated = fun.(task)
              :ets.insert(table, {task_id, updated})
              {:ok, updated}

            {:error, reason} ->
              {:error, reason}
          end
        after
          :ets.delete(lock_table, lock_key)
        end

      false when attempts < 10 ->
        Process.sleep(1)
        do_update_task(table, task_id, fun, attempts + 1)

      false ->
        {:error, :locked}
    end
  end

  defp ensure_lock_table do
    case :ets.whereis(@lock_table) do
      :undefined ->
        try do
          :ets.new(@lock_table, [:set, :public, :named_table, read_concurrency: true])
        rescue
          ArgumentError ->
            :ok
        end

      _table ->
        :ok
    end

    @lock_table
  end

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(_), do: %{}

  defp filter_tasks(tasks, opts) do
    tasks
    |> Enum.filter(&match_context?(&1, opts))
    |> Enum.filter(&match_status?(&1, opts))
    |> Enum.filter(&updated_after?(&1, opts))
  end

  defp match_context?(%A2A.Types.Task{context_id: context_id}, opts) do
    case get_opt(opts, "contextId", :context_id) do
      nil -> true
      value -> value == context_id
    end
  end

  defp match_status?(%A2A.Types.Task{status: %A2A.Types.TaskStatus{state: state}}, opts) do
    case get_opt(opts, "status", :status) do
      nil -> true
      value when is_atom(value) -> value == state
      value -> A2A.TaskState.decode(value, []) == state
    end
  end

  defp match_status?(_task, _opts), do: true

  defp updated_after?(%A2A.Types.Task{status: %A2A.Types.TaskStatus{timestamp: timestamp}}, opts) do
    case get_opt(opts, "updatedAfter", :updated_after) do
      nil ->
        true

      value ->
        updated_after =
          case value do
            %DateTime{} = datetime -> datetime
            _ -> A2A.Types.decode_datetime(value)
          end

        case {updated_after, timestamp} do
          {nil, _} -> true
          {_, nil} -> false
          {after_dt, ts} -> DateTime.compare(ts, after_dt) == :gt
        end
    end
  end

  defp updated_after?(_task, _opts), do: true

  defp sort_tasks(tasks) do
    Enum.sort_by(tasks, &sort_key/1, :desc)
  end

  defp sort_key(%A2A.Types.Task{id: id} = task) do
    {task_timestamp(task), id || ""}
  end

  defp task_timestamp(%A2A.Types.Task{
         status: %A2A.Types.TaskStatus{timestamp: %DateTime{} = ts}
       }) do
    DateTime.to_unix(ts, :millisecond)
  end

  defp task_timestamp(_), do: 0

  defp maybe_strip_artifacts(tasks, opts) do
    include =
      case get_opt(opts, "includeArtifacts", :include_artifacts) do
        nil -> true
        value when is_boolean(value) -> value
        value when value in ["true", "1"] -> true
        _ -> false
      end

    if include do
      tasks
    else
      Enum.map(tasks, fn task -> %{task | artifacts: nil} end)
    end
  end

  defp paginate(tasks, opts) do
    page_size = parse_int(get_opt(opts, "pageSize", :page_size))
    page_token = get_opt(opts, "pageToken", :page_token)

    tasks = apply_page_token(tasks, page_token)

    if page_size do
      {page, rest} = Enum.split(tasks, page_size)
      next_token = next_page_token(page, rest)
      {page, next_token}
    else
      {tasks, nil}
    end
  end

  defp apply_page_token(tasks, nil), do: tasks

  defp apply_page_token(tasks, token) when is_integer(token) do
    Enum.drop(tasks, token)
  end

  defp apply_page_token(tasks, token) when is_binary(token) do
    case parse_offset_token(token) do
      {:offset, offset} ->
        Enum.drop(tasks, offset)

      {:cursor, cursor} ->
        drop_after_cursor(tasks, cursor)

      :error ->
        tasks
    end
  end

  defp apply_page_token(tasks, _), do: tasks

  defp parse_offset_token(token) do
    case Integer.parse(token) do
      {int, ""} -> {:offset, int}
      _ -> parse_cursor_token(token)
    end
  end

  defp parse_cursor_token(token) do
    case String.split(token, ":", parts: 2) do
      [ts, id] ->
        case Integer.parse(ts) do
          {timestamp, ""} -> {:cursor, {timestamp, id}}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp drop_after_cursor(tasks, {timestamp, id}) do
    Enum.drop_while(tasks, fn task -> sort_key(task) >= {timestamp, id} end)
  end

  defp next_page_token([], _rest), do: nil
  defp next_page_token(_page, []), do: nil

  defp next_page_token(page, _rest) do
    task = List.last(page)
    {timestamp, id} = sort_key(task)
    "#{timestamp}:#{id}"
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp get_opt(opts, key, fallback) when is_map(opts) do
    value = Map.get(opts, key)
    if value == nil, do: Map.get(opts, fallback), else: value
  end
end
