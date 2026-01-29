defmodule A2A.SSETest do
  use ExUnit.Case, async: true

  test "decodes multi-line data and ids" do
    body = "id: 1\ndata: first\ndata: line\n\n" <> "id:2\ndata: second\n\n"
    events = A2A.Transport.SSE.decode_events(body)
    assert events == ["first\nline", "second"]

    parser = A2A.Transport.SSE.new_parser()
    {events, parser} = A2A.Transport.SSE.feed(parser, "id: 10\ndata: hello")
    assert events == []
    assert A2A.Transport.SSE.last_event_id(parser) == nil

    {events, parser} = A2A.Transport.SSE.feed(parser, "\n\n")
    assert [%{data: "hello", id: "10"}] = events
    assert A2A.Transport.SSE.last_event_id(parser) == "10"
  end

  test "streams events with reconnect" do
    parent = self()

    connect_fun = fn last_event_id ->
      send(parent, {:connect, last_event_id})

      case last_event_id do
        nil -> {:ok, ["id: 1\ndata: one\n\n"]}
        "1" -> {:ok, ["id: 2\ndata: two\n\n"]}
        _ -> {:error, :done}
      end
    end

    events =
      connect_fun
      |> A2A.Transport.SSE.stream_with_reconnect(max_retries: 0)
      |> Enum.to_list()

    assert events == ["one", "two"]
    assert_received {:connect, nil}
    assert_received {:connect, "1"}
  end

  test "stream_events halts upstream on take" do
    parent = self()

    stream =
      Stream.resource(
        fn -> ["data: one\n\n", "data: two\n\n"] end,
        fn
          [chunk | rest] ->
            send(parent, {:chunk, chunk})
            {[chunk], rest}

          [] ->
            {:halt, []}
        end,
        fn _ -> send(parent, :halted) end
      )

    events =
      stream
      |> A2A.Transport.SSE.stream_events()
      |> Enum.take(1)

    assert events == ["one"]
    assert_received {:chunk, "data: one\n\n"}
    refute_receive {:chunk, "data: two\n\n"}, 50
    assert_received :halted
  end
end
