defmodule A2A.Transport.SSE do
  @moduledoc """
  SSE parsing and streaming helpers.
  """

  defmodule Parser do
    @moduledoc """
    Incremental parser state for SSE streams.
    """
    defstruct buffer: "", last_event_id: nil

    @type t :: %__MODULE__{buffer: String.t(), last_event_id: String.t() | nil}
  end

  @spec new_parser() :: Parser.t()
  def new_parser, do: %Parser{}

  @spec last_event_id(Parser.t()) :: String.t() | nil
  def last_event_id(%Parser{last_event_id: last_event_id}), do: last_event_id

  @spec decode_events(String.t()) :: list(String.t())
  def decode_events(body) when is_binary(body) do
    {events, _parser} = feed(new_parser(), body)
    Enum.map(events, & &1.data)
  end

  @spec stream_events(Enumerable.t(), keyword()) :: Enumerable.t()
  def stream_events(enum, opts \\ []) do
    parser = Keyword.get(opts, :parser, new_parser())

    Stream.transform(enum, parser, fn chunk, parser ->
      {events, parser} = feed(parser, chunk)
      {Enum.map(events, & &1.data), parser}
    end)
  end

  @spec stream_with_reconnect(
          (String.t() | nil -> {:ok, Enumerable.t()} | {:error, term()}),
          keyword()
        ) :: Enumerable.t()
  def stream_with_reconnect(connect_fun, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 3)
    backoff_ms = Keyword.get(opts, :backoff_ms, 250)
    backoff_factor = Keyword.get(opts, :backoff_factor, 2)

    Stream.resource(
      fn ->
        %{
          last_event_id: nil,
          attempt: 0,
          backoff: backoff_ms,
          base_backoff: backoff_ms,
          enum: nil,
          enum_state: nil,
          parser: new_parser()
        }
      end,
      fn state ->
        case ensure_connected(state, connect_fun, max_retries, backoff_factor) do
          {:halt, state} ->
            {:halt, state}

          state ->
            case next_chunk(state) do
              {:ok, chunk, state} ->
                {events, parser} = feed(state.parser, chunk)

                new_state = %{
                  state
                  | parser: parser,
                    last_event_id: parser.last_event_id
                }

                {Enum.map(events, & &1.data), new_state}

              :done ->
                new_state = %{
                  state
                  | enum: nil,
                    enum_state: nil,
                    parser: %Parser{last_event_id: state.last_event_id}
                }

                {[], new_state}
            end
        end
      end,
      fn _ -> :ok end
    )
  end

  @spec feed(Parser.t(), String.t()) :: {list(map()), Parser.t()}
  def feed(%Parser{} = parser, chunk) when is_binary(chunk) do
    buffer = parser.buffer <> chunk
    {complete, rest} = split_complete_events(buffer)
    {events, last_event_id} = parse_events(complete, parser.last_event_id)
    {events, %Parser{parser | buffer: rest, last_event_id: last_event_id}}
  end

  defp ensure_connected(%{enum: nil} = state, connect_fun, max_retries, backoff_factor) do
    case connect_fun.(state.last_event_id) do
      {:ok, enum} ->
        %{
          state
          | enum: enum,
            enum_state: :start,
            attempt: 0,
            backoff: state.base_backoff
        }

      {:error, _reason} when state.attempt < max_retries ->
        Process.sleep(state.backoff)

        %{
          state
          | attempt: state.attempt + 1,
            backoff: state.backoff * backoff_factor
        }

      {:error, _reason} ->
        {:halt, state}
    end
  end

  defp ensure_connected(state, _connect_fun, _max_retries, _backoff_factor), do: state

  defp next_chunk(%{enum: nil}), do: :done

  defp next_chunk(%{enum: enum, enum_state: :start} = state) do
    case Enumerable.reduce(enum, {:cont, nil}, fn chunk, _acc -> {:suspend, chunk} end) do
      {:suspended, chunk, continuation} ->
        {:ok, chunk, %{state | enum_state: continuation}}

      {:done, _} ->
        :done

      {:halted, _} ->
        :done
    end
  end

  defp next_chunk(%{enum_state: continuation} = state) when is_function(continuation, 1) do
    case continuation.({:cont, nil}) do
      {:suspended, chunk, next_continuation} ->
        {:ok, chunk, %{state | enum_state: next_continuation}}

      {:done, _} ->
        :done

      {:halted, _} ->
        :done
    end
  end

  defp split_complete_events(buffer) do
    parts = String.split(buffer, ~r/\r?\n\r?\n/, trim: false)
    {tail, events} = List.pop_at(parts, -1)
    {Enum.reject(events, &(&1 == "")), tail || ""}
  end

  defp parse_events(events, last_event_id) do
    Enum.reduce(events, {[], last_event_id}, fn event, {acc, last_id} ->
      {data, event_id} = parse_event(event, last_id)

      if data == "" do
        {acc, event_id}
      else
        {acc ++ [%{data: data, id: event_id}], event_id}
      end
    end)
  end

  defp parse_event(event, last_event_id) do
    {data_lines, event_id} =
      event
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({[], last_event_id}, fn line, {data, event_id} ->
        cond do
          String.starts_with?(line, "data:") ->
            data = data ++ [String.trim_leading(String.trim_leading(line, "data:"))]
            {data, event_id}

          String.starts_with?(line, "id:") ->
            {data, String.trim_leading(String.trim_leading(line, "id:"))}

          true ->
            {data, event_id}
        end
      end)

    {Enum.join(data_lines, "\n"), event_id}
  end
end
