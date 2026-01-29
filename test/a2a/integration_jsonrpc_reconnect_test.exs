defmodule A2A.IntegrationJSONRPCReconnectTest do
  use ExUnit.Case, async: false

  setup_all do
    plug_opts = [executor: A2A.TestExecutor, capabilities: %{streaming: true}]
    server = A2A.TestHTTPServer.start(A2A.TestJSONRPCReconnectPlug, plug_opts: plug_opts)
    on_exit(fn -> A2A.TestHTTPServer.stop(server.ref) end)
    {:ok, base_url: server.base_url}
  end

  test "reconnects to JSONRPC stream with last-event-id", %{base_url: base_url} do
    connect_fun = fn last_event_id ->
      if last_event_id == "3" do
        {:error, :done}
      else
        headers =
          [{"content-type", "application/json"}, {"accept", "text/event-stream"}]
          |> maybe_put_last_event_id(last_event_id)

        payload = %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "message/stream",
          "params" => %{
            "message" => %{
              "messageId" => "msg-1",
              "role" => "user",
              "parts" => [%{"text" => "hello"}]
            }
          }
        }

        case Req.request(
               method: :post,
               url: base_url,
               headers: headers,
               body: Jason.encode!(payload)
             ) do
          {:ok, %{status: 200, body: body}} -> {:ok, [body]}
          {:ok, response} -> {:error, {:unexpected_status, response.status}}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    events =
      connect_fun
      |> A2A.Transport.SSE.stream_with_reconnect(max_retries: 1)
      |> Enum.to_list()

    decoded = Enum.map(events, &Jason.decode!/1)
    assert Enum.at(decoded, 0)["result"]["task"]["id"] == "task-1"
    assert Enum.at(decoded, 1)["result"]["statusUpdate"]["taskId"] == "task-1"
    assert Enum.at(decoded, 2)["result"]["statusUpdate"]["taskId"] == "task-1"
  end

  defp maybe_put_last_event_id(headers, nil), do: headers

  defp maybe_put_last_event_id(headers, last_event_id) do
    headers ++ [{"last-event-id", last_event_id}]
  end
end
