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

- A stable `:v1_0` mode implementing the released A2A v1.0 ProtoJSON contract over HTTP+JSON and JSON-RPC, including SSE.
- A separate `:v0_3` compatibility adapter for legacy v0.3 deployments.
- `:latest` remains an accepted input alias for backwards compatibility, but is immediately normalized to `:v1_0`; it is never stored, emitted, or tested as a conformance identity.
- gRPC is not currently implemented and is not advertised as a supported v1.0 binding.

### A2A v1.0

Select v1.0 explicitly on both sides. The v1 codec always emits the normative
ProtoJSON shape; `wire_format` compatibility settings do not affect it.

```elixir
config =
  A2A.Client.Config.new("https://example.com",
    transport: A2A.Transport.REST,
    version: :v1_0
  )

{:ok, result} =
  A2A.Client.send_message(config,
    message: %A2A.Types.Message{
      message_id: "message-1",
      role: :user,
      parts: [%A2A.Types.Part{text: "Hello"}]
    }
  )
```

```elixir
plug A2A.Server.REST.Plug,
  executor: MyApp.A2AExecutor,
  version: :v1_0
```

V1 HTTP+JSON requests and responses use `application/a2a+json`. JSON-RPC
continues to use its required `application/json` media type.

Public v1 Agent Cards include a content-derived `ETag` and
`Cache-Control: public, max-age=300`; matching `If-None-Match` requests receive
`304 Not Modified`. The policy is configurable when installing the card plug:

```elixir
plug A2A.Server.AgentCardPlug,
  card: MyApp.AgentCard.build(),
  version: :v1_0,
  cache_control: "public, max-age=900"
```

Use `cache_control: false, etag: false` to return `Cache-Control: no-store`
without an ETag, which is useful for per-request dynamic cards.

The client negotiates only interfaces whose `protocolVersion` matches the
requested stable identity (`1.0` for `:v1_0`, `0.3` for `:v0_3`) and carries
the selected interface tenant into requests.

### v0.3 wire format compatibility

The legacy v0.3 adapter uses spec-compliant JSON by default (`wire_format: :spec_json`), e.g.
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

Use `:proto_json` only as a v0.3 interoperability workaround; keep `:spec_json`
for standards-compliant v0.3 deployments. This setting is intentionally ignored
by the v1.0 adapter.

## Installation

Requires Elixir 1.16 or later and Erlang/OTP 26 or later. CI covers the minimum
Elixir 1.16/OTP 26 combination and the current Elixir 1.20/OTP 29 combination.

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
- `examples/e2e_protocol_suite.exs` (real transport E2E protocol smoke suite)
- `examples/e2e_elixir_client_js_server.exs` (Elixir client -> JS SDK server)
- `examples/e2e_js_client_elixir_server.mjs` (JS SDK client -> Elixir server)

### E2E protocol smoke suite

Run:

```bash
elixir examples/e2e_protocol_suite.exs
```

This script starts real local servers and validates, end-to-end:

- REST + JSON-RPC discovery and core task/message flows.
- Streaming (`message:stream`) event delivery on both transports.
- Task lifecycle operations (`get`, `list`, `cancel`).
- Push notification lifecycle (`set/get/list/delete`) with real webhook delivery and token checks.
- JSON-RPC required extension enforcement and positive/negative extension-header paths.

### Cross-language E2E scripts (official JS SDK)

These scripts use a pinned JS harness at `examples/js_sdk_e2e/package.json` with
`@a2a-js/sdk` version `0.3.10`.

Run Elixir client against JS SDK server:

```bash
elixir examples/e2e_elixir_client_js_server.exs
```

Covers:
- discovery and interface advertisement checks
- auth challenge/retry (401 + `WWW-Authenticate`)
- REST + JSON-RPC `send_message`
- JSON-RPC streaming assertion
- transport path checks against official JS SDK server mounts

Run JS SDK client against Elixir server:

```bash
node examples/e2e_js_client_elixir_server.mjs
```

Covers:
- discovery and transport negotiation via `ClientFactory`
- auth challenge/retry using `createAuthenticatingFetchWithRetry`
- JSON-RPC `sendMessage` + `sendMessageStream` + push config lifecycle via JS SDK
- REST `sendMessage` via JS SDK against Elixir `wire_format: :proto_json` compatibility mode
- REST `message:stream` + push config lifecycle using authenticated raw transport calls

Note: some JS SDK REST stream/push paths still have shape/decoding inconsistencies in this interop setup,
so the suite validates those REST endpoints with raw authenticated HTTP calls while keeping SDK coverage
for JSON-RPC and REST `sendMessage`.

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

The v1.0 interoperability checks pin their external dependencies for
reproducibility. CI runs both commands on every push and pull request:

```bash
# Official Python SDK (a2a-sdk 1.1.1), HTTP+JSON and JSON-RPC
scripts/run_v1_python_sdk.sh

# Official A2A TCK at the commit pinned by the script
A2A_TCK_DIR=/path/to/a2a-tck scripts/run_v1_tck.sh --level must
```

## License

Apache 2.0. See `LICENSE`.
