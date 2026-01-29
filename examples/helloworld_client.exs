# Elixir Client for Python HelloWorld Server
#
# First start the Python helloworld server:
#   cd a2a-samples/samples/python/agents/helloworld
#   uv run .
#
# Then run this client:
#   elixir examples/helloworld_client.exs

Mix.install([
  {:a2a_ex, path: "."}
])

defmodule HelloWorldClient do
  @base_url "http://localhost:9999"

  # Helper to build structs at runtime
  defp message(fields), do: struct(A2A.Types.Message, fields)
  defp text_part(fields), do: struct(A2A.Types.TextPart, fields)

  def run do
    IO.puts("=" |> String.duplicate(60))
    IO.puts("Elixir Client -> Python HelloWorld Server")
    IO.puts("=" |> String.duplicate(60))
    IO.puts("")

    # Step 1: Fetch public agent card
    IO.puts("Fetching public agent card from #{@base_url}...")

    # Use JSON-RPC transport for Python SDK compatibility
    case A2A.Client.discover(@base_url, transport: A2A.Transport.JSONRPC) do
      {:ok, card} ->
        IO.puts("Successfully fetched public agent card:")
        IO.puts("  Name: #{card.name}")
        IO.puts("  Description: #{card.description}")
        IO.puts("  Version: #{card.version}")
        IO.puts("  Streaming: #{card.capabilities && card.capabilities.streaming}")

        Enum.each(card.skills || [], fn skill ->
          IO.puts("  Skill: #{skill.name} - #{skill.description}")
        end)

        IO.puts("")

        # Check for extended agent card support
        if card.supports_authenticated_extended_card do
          IO.puts("Public card supports authenticated extended card.")
          fetch_extended_card()
        end

        # Step 2: Send sync message
        send_sync_message()

        # Step 3: Send streaming message
        send_streaming_message()

      {:error, error} ->
        IO.puts("Failed to fetch agent card: #{error.message}")
    end

    IO.puts("\nClient demo completed!")
  end

  defp fetch_extended_card do
    IO.puts("Attempting to fetch extended agent card...")

    # Use custom headers for authentication
    case A2A.Client.get_extended_agent_card(
           @base_url,
           transport: A2A.Transport.JSONRPC,
           headers: [{"authorization", "Bearer dummy-token-for-extended-card"}]
         ) do
      {:ok, extended_card} ->
        IO.puts("Successfully fetched extended agent card:")
        IO.puts("  Name: #{extended_card.name}")
        IO.puts("  Version: #{extended_card.version}")

        Enum.each(extended_card.skills || [], fn skill ->
          IO.puts("  Skill: #{skill.name}")
        end)

        IO.puts("")

      {:error, error} ->
        IO.puts("Failed to fetch extended card: #{inspect(error)}")
        IO.puts("Continuing with public card...")
        IO.puts("")
    end
  end

  defp send_sync_message do
    IO.puts("-" |> String.duplicate(40))
    IO.puts("Sending sync message...")
    IO.puts("-" |> String.duplicate(40))

    msg =
      message(
        message_id: random_hex_id(),
        role: :user,
        parts: [text_part(text: "how much is 10 USD in INR?")]
      )

    case A2A.Client.send_message(@base_url, [message: msg], transport: A2A.Transport.JSONRPC) do
      {:ok, response} ->
        IO.puts("Response received:")
        print_response(response)

      {:error, error} ->
        IO.puts("Error: #{inspect(error)}")
    end

    IO.puts("")
  end

  defp send_streaming_message do
    IO.puts("-" |> String.duplicate(40))
    IO.puts("Sending streaming message...")
    IO.puts("-" |> String.duplicate(40))

    msg =
      message(
        message_id: random_hex_id(),
        role: :user,
        parts: [text_part(text: "how much is 10 USD in INR?")]
      )

    case A2A.Client.stream_message(@base_url, [message: msg], transport: A2A.Transport.JSONRPC) do
      {:ok, stream} ->
        IO.puts("Streaming response:")

        Enum.each(stream, fn event ->
          case event do
            %{status_update: update} when not is_nil(update) ->
              IO.puts("  [STATUS] State: #{update.status.state}, Final: #{update.final}")

            %{artifact_update: update} when not is_nil(update) ->
              text =
                case update.artifact.parts do
                  [%{text: t} | _] -> t
                  _ -> ""
                end

              IO.puts("  [ARTIFACT] #{text}")

            %{task: task} when not is_nil(task) ->
              IO.puts("  [TASK] ID: #{task.id}, Status: #{task.status.state}")
              print_task_message(task)

            %{message: msg} when not is_nil(msg) ->
              IO.puts("  [MESSAGE] Role: #{msg.role}")
              print_message_parts(msg)

            {:error, error} ->
              IO.puts("  [ERROR] #{inspect(error)}")

            other ->
              IO.puts("  [EVENT] #{inspect(other)}")
          end
        end)

      {:error, error} ->
        IO.puts("Stream error: #{inspect(error)}")
    end

    IO.puts("")
  end

  defp print_response(%{id: id, status: status} = task) when not is_nil(id) do
    IO.puts("  Task ID: #{id}")
    IO.puts("  Status: #{status && status.state}")
    print_task_message(task)
  end

  defp print_response(%{role: role} = msg) when not is_nil(role) do
    IO.puts("  Message role: #{role}")
    print_message_parts(msg)
  end

  defp print_response(other) do
    IO.puts("  #{inspect(other)}")
  end

  defp print_task_message(%{status: %{message: msg}}) when not is_nil(msg) do
    IO.puts("  Agent message:")
    print_message_parts(msg)
  end

  defp print_task_message(%{history: [_ | _] = history}) do
    # Find agent messages in history
    Enum.each(history, fn msg ->
      if msg.role == :agent do
        IO.puts("  Agent response:")
        print_message_parts(msg)
      end
    end)
  end

  defp print_task_message(_), do: :ok

  defp print_message_parts(%{parts: parts}) when is_list(parts) do
    Enum.each(parts, fn part ->
      case part do
        %{text: text} when is_binary(text) ->
          IO.puts("    Text: #{text}")

        other ->
          IO.puts("    Part: #{inspect(other)}")
      end
    end)
  end

  defp print_message_parts(_), do: :ok

  defp random_hex_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

HelloWorldClient.run()
