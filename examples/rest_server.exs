# A2A REST Server Example
#
# Run: elixir examples/rest_server.exs
# Then run the client in another terminal: elixir examples/rest_client.exs

Mix.install([
  {:a2a_ex, path: "."},
  {:plug_cowboy, "~> 2.7"}
])

defmodule TaskStore do
  @moduledoc """
  Simple in-memory task store using Agent.
  """

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def put(task) do
    Agent.update(__MODULE__, &Map.put(&1, task.id, task))
    task
  end

  def get(task_id) do
    Agent.get(__MODULE__, &Map.get(&1, task_id))
  end

  def list do
    Agent.get(__MODULE__, &Map.values(&1))
    |> Enum.sort_by(& &1.status.timestamp, {:desc, DateTime})
  end
end

defmodule MockAgent do
  @moduledoc """
  Mock agent implementing A2A.Server.Executor behaviour.
  Demonstrates sync and streaming responses.
  """

  @behaviour A2A.Server.Executor

  # Helper to build structs at runtime (avoids compile-time struct expansion issues)
  defp task(fields), do: struct(A2A.Types.Task, fields)
  defp task_status(fields), do: struct(A2A.Types.TaskStatus, fields)
  defp text_part(fields), do: struct(A2A.Types.TextPart, fields)
  defp artifact(fields), do: struct(A2A.Types.Artifact, fields)
  defp status_event(fields), do: struct(A2A.Types.TaskStatusUpdateEvent, fields)
  defp artifact_event(fields), do: struct(A2A.Types.TaskArtifactUpdateEvent, fields)
  defp list_response(fields), do: struct(A2A.Types.ListTasksResponse, fields)

  @impl true
  def handle_send_message(request, _ctx) do
    # Generate task ID and context ID
    task_id = "task-#{System.unique_integer([:positive])}"
    context_id = request.message.context_id || "ctx-#{System.unique_integer([:positive])}"

    # Create task with submitted status
    t =
      task(
        id: task_id,
        context_id: context_id,
        status:
          task_status(
            state: :submitted,
            message: nil,
            timestamp: DateTime.utc_now()
          ),
        history: [request.message]
      )

    # Store task
    TaskStore.put(t)

    # Return the task immediately (sync response)
    {:ok, t}
  end

  @impl true
  def handle_stream_message(request, _ctx, emit) do
    # Generate task ID and context ID
    task_id = "task-#{System.unique_integer([:positive])}"
    context_id = request.message.context_id || "ctx-#{System.unique_integer([:positive])}"

    # Get message text
    message_text =
      case request.message.parts do
        [%{text: text} | _] -> text
        _ -> "Hello"
      end

    # Emit status update: working
    emit.(
      status_event(
        task_id: task_id,
        context_id: context_id,
        status:
          task_status(
            state: :working,
            message: nil,
            timestamp: DateTime.utc_now()
          ),
        final: false
      )
    )

    # Simulate streaming artifact generation
    response_chunks = [
      "I received your message: ",
      "\"#{message_text}\". ",
      "Here's my streaming response. ",
      "Each chunk arrives with a delay. ",
      "This demonstrates the A2A streaming protocol."
    ]

    artifact_id = "art-#{System.unique_integer([:positive])}"

    # Emit artifact chunks
    Enum.with_index(response_chunks, fn chunk, idx ->
      is_last = idx == length(response_chunks) - 1

      emit.(
        artifact_event(
          task_id: task_id,
          context_id: context_id,
          artifact:
            artifact(
              artifact_id: artifact_id,
              name: "response",
              parts: [text_part(text: chunk)]
            ),
          append: idx > 0,
          last_chunk: is_last
        )
      )

      # Small delay between chunks
      Process.sleep(200)
    end)

    # Emit final status: completed
    emit.(
      status_event(
        task_id: task_id,
        context_id: context_id,
        status:
          task_status(
            state: :completed,
            message: nil,
            timestamp: DateTime.utc_now()
          ),
        final: true
      )
    )

    # Build final task
    full_response = Enum.join(response_chunks)

    t =
      task(
        id: task_id,
        context_id: context_id,
        status:
          task_status(
            state: :completed,
            timestamp: DateTime.utc_now()
          ),
        artifacts: [
          artifact(
            artifact_id: artifact_id,
            name: "response",
            parts: [text_part(text: full_response)]
          )
        ],
        history: [request.message]
      )

    TaskStore.put(t)
    {:ok, t}
  end

  @impl true
  def handle_get_task(task_id, _query, _ctx) do
    case TaskStore.get(task_id) do
      nil ->
        {:error, A2A.Error.new(:task_not_found, "Task #{task_id} not found")}

      t ->
        {:ok, t}
    end
  end

  @impl true
  def handle_list_tasks(_request, _ctx) do
    tasks = TaskStore.list()

    {:ok,
     list_response(
       tasks: tasks,
       total_size: length(tasks)
     )}
  end

  @impl true
  def handle_cancel_task(task_id, _ctx) do
    case TaskStore.get(task_id) do
      nil ->
        {:error, A2A.Error.new(:task_not_found, "Task #{task_id} not found")}

      t ->
        # Check if task is in terminal state
        if t.status.state in [:completed, :canceled, :failed, :rejected] do
          {:error, A2A.Error.new(:task_not_cancelable, "Task #{task_id} is already terminal")}
        else
          updated_task = %{
            t
            | status:
                task_status(
                  state: :canceled,
                  message: nil,
                  timestamp: DateTime.utc_now()
                )
          }

          TaskStore.put(updated_task)
          {:ok, updated_task}
        end
    end
  end

  @impl true
  def handle_subscribe(task_id, _ctx, emit) do
    case TaskStore.get(task_id) do
      nil ->
        {:error, A2A.Error.new(:task_not_found, "Task #{task_id} not found")}

      t ->
        # Emit current task status
        emit.(
          status_event(
            task_id: t.id,
            context_id: t.context_id,
            status: t.status,
            final: t.status.state in [:completed, :canceled, :failed, :rejected]
          )
        )

        {:ok, :subscribed}
    end
  end
end


# Combined plug that serves agent card and REST endpoints
defmodule ServerPlug do
  use Plug.Builder

  # Serve agent card at /.well-known/agent-card.json
  plug A2A.Server.AgentCardPlug, card_fun: &__MODULE__.agent_card/0

  # REST transport endpoints
  plug A2A.Server.REST.Plug,
    executor: MockAgent,
    capabilities: %{streaming: true}

  def agent_card do
    A2A.Types.AgentCard.from_map(%{
      "name" => "A2A Example Agent (REST)",
      "description" => "An example agent demonstrating the A2A protocol over REST transport",
      "version" => "1.0.0",
      "url" => "http://localhost:4000",
      "preferredTransport" => "HTTP+JSON",
      "capabilities" => %{
        "streaming" => true,
        "pushNotifications" => false
      },
      "skills" => [
        %{
          "id" => "echo",
          "name" => "Echo",
          "description" => "Echoes back your message with streaming chunks"
        }
      ]
    })
  end
end

# Start the task store
{:ok, _} = TaskStore.start_link([])

IO.puts("""
Starting A2A REST Server on http://localhost:4000

Endpoints:
  GET  /.well-known/agent-card.json  - Agent discovery
  POST /v1/message:send              - Send message (sync)
  POST /v1/message:stream            - Send message (streaming)
  GET  /v1/tasks/:id                 - Get task
  GET  /v1/tasks                     - List tasks
  POST /v1/tasks/:id:cancel          - Cancel task

Press Ctrl+C to stop.
""")

# Start Cowboy with the combined plug
{:ok, _} = Plug.Cowboy.http(ServerPlug, [], port: 4000)

# Keep the process running
Process.sleep(:infinity)
