# Elixir HelloWorld Server (compatible with Python test_client.py)
#
# Run this server:
#   elixir examples/helloworld_server.exs
#
# Then run the Python client:
#   cd a2a-samples/samples/python/agents/helloworld
#   uv run test_client.py

Mix.install([
  {:a2a_ex, path: "."},
  {:plug_cowboy, "~> 2.7"}
])

defmodule HelloWorldExecutor do
  @moduledoc """
  HelloWorld executor that returns "Hello World" for any message.
  Mimics the Python helloworld agent behavior.
  """

  @behaviour A2A.Server.Executor

  # Helper to build structs at runtime
  defp task(fields), do: struct(A2A.Types.Task, fields)
  defp task_status(fields), do: struct(A2A.Types.TaskStatus, fields)
  defp text_part(fields), do: struct(A2A.Types.TextPart, fields)
  defp message_struct(fields), do: struct(A2A.Types.Message, fields)
  defp status_event(fields), do: struct(A2A.Types.TaskStatusUpdateEvent, fields)
  defp list_response(fields), do: struct(A2A.Types.ListTasksResponse, fields)

  @impl true
  def handle_send_message(request, _ctx) do
    task_id = "task-#{random_id()}"
    context_id = request.message.context_id || "ctx-#{random_id()}"

    # Create agent response message with "Hello World"
    agent_message =
      message_struct(
        message_id: "msg-#{random_id()}",
        role: :agent,
        parts: [text_part(text: "Hello World")]
      )

    # Create completed task with the response in status.message
    t =
      task(
        id: task_id,
        context_id: context_id,
        status:
          task_status(
            state: :completed,
            message: agent_message,
            timestamp: DateTime.utc_now()
          ),
        history: [request.message, agent_message]
      )

    {:ok, t}
  end

  @impl true
  def handle_stream_message(request, _ctx, emit) do
    task_id = "task-#{random_id()}"
    context_id = request.message.context_id || "ctx-#{random_id()}"

    # Emit working status
    emit.(
      status_event(
        task_id: task_id,
        context_id: context_id,
        status:
          task_status(
            state: :working,
            timestamp: DateTime.utc_now()
          ),
        final: false
      )
    )

    # Create agent response message
    agent_message =
      message_struct(
        message_id: "msg-#{random_id()}",
        role: :agent,
        parts: [text_part(text: "Hello World")]
      )

    # Emit completed status with the message
    emit.(
      status_event(
        task_id: task_id,
        context_id: context_id,
        status:
          task_status(
            state: :completed,
            message: agent_message,
            timestamp: DateTime.utc_now()
          ),
        final: true
      )
    )

    # Return completed task
    t =
      task(
        id: task_id,
        context_id: context_id,
        status:
          task_status(
            state: :completed,
            message: agent_message,
            timestamp: DateTime.utc_now()
          ),
        history: [request.message, agent_message]
      )

    {:ok, t}
  end

  @impl true
  def handle_get_task(task_id, _query, _ctx) do
    {:error, A2A.Error.new(:task_not_found, "Task #{task_id} not found")}
  end

  @impl true
  def handle_list_tasks(_request, _ctx) do
    {:ok, list_response(tasks: [], total_size: 0)}
  end

  @impl true
  def handle_cancel_task(_task_id, _ctx) do
    {:error, A2A.Error.new(:unsupported_operation, "cancel not supported")}
  end

  defp random_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

# Combined plug that serves agent card and REST endpoints
defmodule HelloWorldServerPlug do
  use Plug.Builder

  # Serve public agent card at /.well-known/agent-card.json
  plug A2A.Server.AgentCardPlug, card_fun: &__MODULE__.public_agent_card/0

  # REST transport endpoints (compatible with Python A2A SDK)
  plug A2A.Server.REST.Plug,
    executor: HelloWorldExecutor,
    capabilities: %{streaming: true, extended_agent_card: true},
    base_path: ""

  def public_agent_card do
    A2A.Types.AgentCard.from_map(%{
      "name" => "Hello World Agent",
      "description" => "Just a hello world agent",
      "url" => "http://localhost:9999/",
      "version" => "1.0.0",
      "defaultInputModes" => ["text"],
      "defaultOutputModes" => ["text"],
      "capabilities" => %{
        "streaming" => true
      },
      "supportedInterfaces" => [
        %{
          "protocolBinding" => "A2A/REST",
          "url" => "http://localhost:9999/"
        }
      ],
      "skills" => [
        %{
          "id" => "hello_world",
          "name" => "Returns hello world",
          "description" => "just returns hello world",
          "tags" => ["hello world"],
          "examples" => ["hi", "hello world"]
        }
      ],
      "supportsAuthenticatedExtendedCard" => true
    })
  end

  def extended_agent_card do
    A2A.Types.AgentCard.from_map(%{
      "name" => "Hello World Agent - Extended Edition",
      "description" => "The full-featured hello world agent for authenticated users.",
      "url" => "http://localhost:9999/",
      "version" => "1.0.1",
      "defaultInputModes" => ["text"],
      "defaultOutputModes" => ["text"],
      "capabilities" => %{
        "streaming" => true
      },
      "supportedInterfaces" => [
        %{
          "protocolBinding" => "A2A/REST",
          "url" => "http://localhost:9999/"
        }
      ],
      "skills" => [
        %{
          "id" => "hello_world",
          "name" => "Returns hello world",
          "description" => "just returns hello world",
          "tags" => ["hello world"],
          "examples" => ["hi", "hello world"]
        },
        %{
          "id" => "super_hello_world",
          "name" => "Returns a SUPER Hello World",
          "description" => "A more enthusiastic greeting, only for authenticated users.",
          "tags" => ["hello world", "super", "extended"],
          "examples" => ["super hi", "give me a super hello"]
        }
      ],
      "supportsAuthenticatedExtendedCard" => true
    })
  end
end

# Extended agent card executor that provides the extended card
defmodule ExtendedCardExecutor do
  @behaviour A2A.Server.Executor

  # Delegate all regular calls to HelloWorldExecutor
  defdelegate handle_send_message(request, ctx), to: HelloWorldExecutor
  defdelegate handle_stream_message(request, ctx, emit), to: HelloWorldExecutor
  defdelegate handle_get_task(task_id, query, ctx), to: HelloWorldExecutor
  defdelegate handle_list_tasks(request, ctx), to: HelloWorldExecutor
  defdelegate handle_cancel_task(task_id, ctx), to: HelloWorldExecutor

  def handle_get_extended_agent_card(_ctx) do
    {:ok, HelloWorldServerPlug.extended_agent_card()}
  end
end

# Final plug with extended card support - uses JSON-RPC for Python compatibility
defmodule FinalServerPlug do
  use Plug.Builder

  # Serve public agent card at /.well-known/agent-card.json
  plug A2A.Server.AgentCardPlug,
    card_fun: &HelloWorldServerPlug.public_agent_card/0

  # JSON-RPC transport at / for Python SDK compatibility
  plug A2A.Server.JSONRPC.Plug,
    executor: ExtendedCardExecutor,
    capabilities: %{streaming: true, extended_agent_card: true}
end

IO.puts("""
Starting Elixir HelloWorld Server on http://localhost:9999

Endpoints:
  GET  /.well-known/agent-card.json  - Public agent card
  POST /                             - JSON-RPC endpoint (message/send, message/stream, etc.)

This server is compatible with the Python test_client.py from:
  a2a-samples/samples/python/agents/helloworld

Press Ctrl+C to stop.
""")

# Start Cowboy on port 9999
{:ok, _} = Plug.Cowboy.http(FinalServerPlug, [], port: 9999)

# Keep the process running
Process.sleep(:infinity)
