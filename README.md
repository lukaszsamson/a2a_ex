# A2A_EX

Elixir client and server library for the [Agent2Agent (A2A) protocol](https://a2a-protocol.org/latest/). Provides typed structs, REST and JSON-RPC transports, SSE streaming utilities, Plug integration, and a task store abstraction with an ETS adapter.

## Features

- Agent card discovery, validation, and optional signature verification.
- Client APIs for message, task, streaming, and push notification flows.
- Server plugs for REST and JSON-RPC transports with SSE streaming support.
- Task store behavior with ETS adapter.
- Extension negotiation helpers and header utilities.
- gRPC transport placeholder returning unsupported operation errors.

## Protocol compatibility

- [v0.3.0](https://a2a-protocol.org/v0.3.0/specification/) and [latest Release Candidate v1.0](https://a2a-protocol.org/latest/specification/)-compatible mode.
- REST + SSE and JSON-RPC + SSE.

### REST wire format compatibility

By default, REST uses spec-compliant JSON wire format (`wire_format: :spec_json`), e.g.
`role: "user" | "agent"` and `parts`.

For interoperability with SDKs that use protobuf-style REST JSON (`ROLE_USER` / `content`),
you can opt in to compatibility mode with `wire_format: :proto_json`.

Client example:

```elixir
config =
  A2A.Client.Config.new("https://example.com",
    transport: A2A.Transport.REST,
    version: :v0_3,
    wire_format: :proto_json
  )

{:ok, result} =
  A2A.Client.send_message(config,
    message: %A2A.Types.Message{
      role: :user,
      parts: [%A2A.Types.TextPart{text: "Hello"}]
    }
  )
```

Server example:

```elixir
plug A2A.Server.REST.Plug,
  executor: MyApp.A2AExecutor,
  version: :v0_3,
  wire_format: :proto_json
```

Use `:proto_json` only as an interoperability workaround; keep `:spec_json` for standards-compliant v0.3 REST deployments.

## Installation

Add `a2a_ex` to your dependencies:

```elixir
def deps do
  [
    {:a2a_ex, "~> 0.1.0"}
  ]
end
```

## Usage

### Client

```elixir
{:ok, card} = A2A.Client.discover("https://example.com")

{:ok, task_or_message} =
  A2A.Client.send_message(card,
    message: %A2A.Types.Message{
      role: :user,
      parts: [%A2A.Types.TextPart{text: "Draft an outline"}]
    }
  )
```

### Streaming

```elixir
{:ok, stream} =
  A2A.Client.stream_message(card,
    message: %A2A.Types.Message{
      role: :user,
      parts: [%A2A.Types.TextPart{text: "Stream updates"}]
    }
  )

for event <- stream do
  case event do
    %A2A.Types.StreamResponse{} ->
      IO.inspect(event)

    %A2A.Types.StreamError{error: error} ->
      IO.warn("Stream error: #{error.type} #{error.message}")
  end
end
```

Stream cancellation: halting enumeration cancels the underlying Req stream.
You can also call `A2A.Client.Stream.cancel(stream)` to cancel explicitly.

Streaming order: when the handler returns a `Task`, the stream begins with a Task event
followed by update events. To emit the initial Task immediately, call `emit.(task)` early
in your executor before streaming status or artifact updates.

### Server (Plug)

```elixir
plug A2A.Server.REST.Plug,
  executor: MyApp.A2AExecutor,
  task_store: {A2A.TaskStore.ETS, name: MyApp.A2ATaskStore}

plug A2A.Server.AgentCardPlug,
  card: MyApp.AgentCard.build(),
  legacy_path: "/.well-known/agent.json"
```

### Router helpers (Plug/Phoenix)

```elixir
defmodule MyApp.Router do
  use Plug.Router
  import A2A.Server.Router

  rest "/v1", executor: MyApp.A2AExecutor
  jsonrpc "/rpc", executor: MyApp.A2AExecutor
end
```

### Push notifications

```elixir
A2A.Server.Push.deliver(config, task,
  security: [
    strict: true,
    allowed_hosts: ["example.com"],
    replay_protection: true,
    signing_key: System.fetch_env!("PUSH_SIGNING_KEY")
  ]
)
```

## Examples

- `examples/helloworld_server.exs`
- `examples/helloworld_client.exs`
- `examples/rest_server.exs`
- `examples/rest_client.exs`
- `examples/jsonrpc_server.exs`
- `examples/jsonrpc_client.exs`

## Security notes

- Push notifications should use HTTPS webhooks and SSRF protections such as allowlists
  or URL validation before delivery.
- Reject redirects to non-HTTPS URLs and enforce request timeouts/size limits.
- Validate resolved IPs (block localhost, private ranges, and metadata endpoints).
- Resolve DNS per request to reduce DNS rebinding risk.
- Use replay protection for webhook payloads (timestamps, nonces/jti, exp windows).
- Verify webhook auth headers or `X-A2A-Notification-Token` when configured.
- If agent cards include signatures, enable verification with `verify_signatures: true`
  and provide a `signature_verifier` callback.
- Signature verification is application-provided; A2A_EX does not implement JWS/JCS itself.

## Documentation

HexDocs: <https://hexdocs.pm/a2a_ex/0.1.0>

Generate docs locally:

```bash
mix docs
```

## Development

```bash
mix format --check-formatted
mix test
mix dialyzer
```

## License

Apache 2.0. See `LICENSE`.
