rest_port = String.to_integer(System.get_env("A2A_TCK_REST_PORT", "9999"))
jsonrpc_port = String.to_integer(System.get_env("A2A_TCK_JSONRPC_PORT", "9998"))

{:ok, _} = A2A.V1TCKExecutor.start_link()
{:ok, task_store} = A2A.TaskStore.ETS.init(name: :a2a_v1_tck_tasks)

card = %A2A.Types.AgentCard{
  name: "a2a_ex v1.0 TCK agent",
  description: "Deterministic interoperability agent for the official A2A v1.0 TCK",
  version: "1.0.0",
  capabilities: %A2A.Types.AgentCapabilities{streaming: true, push_notifications: false},
  default_input_modes: ["text/plain", "application/json"],
  default_output_modes: ["text/plain", "application/json"],
  skills: [
    %A2A.Types.AgentSkill{
      id: "echo",
      name: "Echo",
      description: "Echoes messages for protocol conformance tests",
      tags: ["tck", "echo"]
    }
  ],
  supported_interfaces: [
    %A2A.Types.AgentInterface{
      url: "http://127.0.0.1:#{rest_port}",
      protocol_binding: "HTTP+JSON",
      protocol_version: "1.0"
    },
    %A2A.Types.AgentInterface{
      url: "http://127.0.0.1:#{jsonrpc_port}",
      protocol_binding: "JSONRPC",
      protocol_version: "1.0"
    }
  ]
}

executor_opts = [
  executor: A2A.V1TCKExecutor,
  version: :v1_0,
  task_store: {A2A.TaskStore.ETS, task_store},
  capabilities: %{streaming: true, push_notifications: false},
  # The pinned TCK currently sends POST although the released v1.0 REST binding is GET.
  # Accept both only in this interoperability SUT; the library's v1.0 default remains GET.
  subscribe_verb: :both,
  # The official TCK HEAD still asserts application/json while the current specification
  # recommends application/a2a+json. Keep the production default normative and scope this
  # older-TCK response compatibility to the interoperability SUT.
  response_media_type: "application/json",
  # TCK HEAD also retains the pre-final HTTP mappings. Production v1 uses the
  # canonical 400/400/500 mappings from the current specification.
  error_status_overrides: %{
    task_not_cancelable: 409,
    content_type_not_supported: 415,
    invalid_agent_response: 502
  }
]

defmodule A2A.V1TCKRESTPlug do
  @moduledoc false
  def init(opts), do: opts

  def call(conn, opts) do
    if conn.request_path == "/.well-known/agent-card.json" do
      A2A.Server.AgentCardPlug.call(conn, opts.card)
    else
      A2A.Server.REST.Plug.call(conn, opts.rest)
    end
  end
end

card_opts = A2A.Server.AgentCardPlug.init(card: card, version: :v1_0)
rest_opts = A2A.Server.REST.Plug.init(executor_opts)

{:ok, _} =
  Plug.Cowboy.http(A2A.V1TCKRESTPlug, %{card: card_opts, rest: rest_opts},
    port: rest_port,
    ref: A2A.V1TCKREST
  )

{:ok, _} =
  Plug.Cowboy.http(A2A.Server.JSONRPC.Plug, executor_opts,
    port: jsonrpc_port,
    ref: A2A.V1TCKJSONRPC
  )

IO.puts("A2A v1.0 TCK SUT listening on REST #{rest_port} and JSON-RPC #{jsonrpc_port}")
Process.sleep(:infinity)
