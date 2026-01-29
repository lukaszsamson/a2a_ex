# A2A REST Client Example
#
# Start the server first: elixir examples/rest_server.exs
# Then run: elixir examples/rest_client.exs

Mix.install([
  {:a2a_ex, path: "."}
])

defmodule Demo do
  @base_url "http://localhost:4000"

  # Helper to build structs at runtime
  defp message(fields), do: struct(A2A.Types.Message, fields)
  defp text_part(fields), do: struct(A2A.Types.TextPart, fields)

  def run do
    IO.puts("=" |> String.duplicate(60))
    IO.puts("A2A REST Client Demo")
    IO.puts("=" |> String.duplicate(60))
    IO.puts("")

    # Demo 1: Discover agent
    demo_discover()

    # Demo 2: Send message (sync)
    {:ok, task} = demo_send_message()

    # Demo 3: Stream message
    demo_stream_message()

    # Demo 4: List tasks
    demo_list_tasks()

    # Demo 5: Get task
    demo_get_task(task.id)

    # Demo 6: Cancel task
    demo_cancel_task()

    # Demo 7: Error handling
    demo_error_handling()

    IO.puts("\nAll demos completed!")
  end

  defp demo_discover do
    IO.puts("-" |> String.duplicate(40))
    IO.puts("Demo 1: Discover Agent")
    IO.puts("-" |> String.duplicate(40))

    case A2A.Client.discover(@base_url) do
      {:ok, card} ->
        IO.puts("Agent Name: #{card.name}")
        IO.puts("Description: #{card.description}")
        IO.puts("Streaming: #{card.capabilities.streaming}")

        Enum.each(card.skills || [], fn skill ->
          IO.puts("  Skill: #{skill.name} - #{skill.description}")
        end)

      {:error, error} ->
        IO.puts("Discovery failed: #{error.message}")
    end

    IO.puts("")
  end

  defp demo_send_message do
    IO.puts("-" |> String.duplicate(40))
    IO.puts("Demo 2: Send Message (Sync)")
    IO.puts("-" |> String.duplicate(40))

    msg =
      message(
        message_id: "msg-#{System.unique_integer([:positive])}",
        role: :user,
        parts: [text_part(text: "Hello from REST client!")]
      )

    case A2A.Client.send_message(@base_url, message: msg) do
      {:ok, %{id: id, context_id: context_id, status: status} = task} ->
        IO.puts("Task ID: #{id}")
        IO.puts("Context ID: #{context_id}")
        IO.puts("Status: #{status.state}")
        IO.puts("")
        {:ok, task}

      {:ok, other} ->
        IO.puts("Got response: #{inspect(other)}")
        {:ok, nil}

      {:error, error} ->
        IO.puts("Error: #{error.message}")
        {:error, error}
    end
  end

  defp demo_stream_message do
    IO.puts("-" |> String.duplicate(40))
    IO.puts("Demo 3: Stream Message")
    IO.puts("-" |> String.duplicate(40))

    msg =
      message(
        message_id: "msg-#{System.unique_integer([:positive])}",
        role: :user,
        parts: [text_part(text: "Tell me about streaming in A2A!")]
      )

    case A2A.Client.stream_message(@base_url, message: msg) do
      {:ok, stream} ->
        IO.puts("Receiving stream events:")
        IO.puts("")

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

              IO.write("  [ARTIFACT] #{text}")
              IO.puts(" (append: #{update.append}, last_chunk: #{update.last_chunk})")

            %{task: task} when not is_nil(task) ->
              IO.puts("  [TASK] ID: #{task.id}, Status: #{task.status.state}")

            %{message: msg} when not is_nil(msg) ->
              IO.puts("  [MESSAGE] Role: #{msg.role}")

            {:error, error} ->
              IO.puts("  [ERROR] #{inspect(error)}")

            other ->
              IO.puts("  [OTHER] #{inspect(other)}")
          end
        end)

      {:error, error} ->
        IO.puts("Stream error: #{error.message}")
    end

    IO.puts("")
  end

  defp demo_list_tasks do
    IO.puts("-" |> String.duplicate(40))
    IO.puts("Demo 4: List Tasks")
    IO.puts("-" |> String.duplicate(40))

    case A2A.Client.list_tasks(@base_url, %{}) do
      {:ok, response} ->
        IO.puts("Total tasks: #{response.total_size || length(response.tasks || [])}")

        Enum.each(response.tasks || [], fn task ->
          IO.puts("  - #{task.id}: #{task.status.state}")
        end)

      {:error, error} ->
        IO.puts("Error: #{error.message}")
    end

    IO.puts("")
  end

  defp demo_get_task(task_id) do
    IO.puts("-" |> String.duplicate(40))
    IO.puts("Demo 5: Get Task")
    IO.puts("-" |> String.duplicate(40))

    case A2A.Client.get_task(@base_url, task_id) do
      {:ok, task} ->
        IO.puts("Task ID: #{task.id}")
        IO.puts("Context ID: #{task.context_id}")
        IO.puts("Status: #{task.status.state}")

        artifact_count = length(task.artifacts || [])
        IO.puts("Artifacts: #{artifact_count}")

      {:error, error} ->
        IO.puts("Error: #{error.message}")
    end

    IO.puts("")
  end

  defp demo_cancel_task do
    IO.puts("-" |> String.duplicate(40))
    IO.puts("Demo 6: Cancel Task")
    IO.puts("-" |> String.duplicate(40))

    # First create a task to cancel
    msg =
      message(
        message_id: "msg-#{System.unique_integer([:positive])}",
        role: :user,
        parts: [text_part(text: "Task to be canceled")]
      )

    case A2A.Client.send_message(@base_url, message: msg) do
      {:ok, %{id: task_id}} ->
        IO.puts("Created task: #{task_id}")

        case A2A.Client.cancel_task(@base_url, task_id) do
          {:ok, task} ->
            IO.puts("Canceled task: #{task.id}")
            IO.puts("New status: #{task.status.state}")

          {:error, error} ->
            IO.puts("Cancel error: #{error.message}")
        end

      {:error, error} ->
        IO.puts("Could not create task: #{error.message}")
    end

    IO.puts("")
  end

  defp demo_error_handling do
    IO.puts("-" |> String.duplicate(40))
    IO.puts("Demo 7: Error Handling")
    IO.puts("-" |> String.duplicate(40))

    # Try to get a non-existent task
    case A2A.Client.get_task(@base_url, "non-existent-task-id") do
      {:ok, _task} ->
        IO.puts("Unexpectedly found task")

      {:error, error} ->
        IO.puts("Error type: #{error.type}")
        IO.puts("Error message: #{error.message}")
    end

    IO.puts("")
  end
end

Demo.run()
