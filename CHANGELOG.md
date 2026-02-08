# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.1.1] - 2026-02-08

### Added
- Client auth challenge/retry flow: both REST and JSON-RPC transports automatically
  handle 401 responses by invoking a configurable `on_auth_challenge` callback,
  merging the resulting headers, and retrying the request.
- Push notification config CRUD endpoints on both transports and server plugs
  (set, get, list, delete) with version-aware method names and field mappings.
- Extended agent card endpoint (`GET /extendedAgentCard` for latest,
  `GET /card` for v0.3) on REST and corresponding JSON-RPC methods.
- Compatibility setting for non-standard v0.3 REST message wire format used by
  the official JS and Python SDKs (`wire_format: :proto_json`). Handles differing
  field names (`parts` vs `content`, role enums, push notification config keys).
- `A2A.Types` module with `wire_format` and `version` type definitions and
  `wire_format_from_opts/1` helper for version-based defaults.
- `A2A.Server.ExecutorRunner` for arity-aware executor invocation, supporting
  both `{Module, opts}` and bare `Module` patterns with optional config injection.
- Content-Type validation on server plugs accepting `application/json` and
  `application/a2a+json`.
- `www-authenticate` header support on 401 error responses from server plugs.
- Subscribe verb configuration (`:get`, `:post`, or `:both`) on the REST server plug.
- Stream task-first ordering: server plugs buffer non-task events until the first
  task event is emitted to ensure correct event ordering.
- Request and stream timeout configuration on server plugs.
- Resume/resubscribe support with flexible cursor field name handling
  (`cursor`, `lastEventId`, `last_event_id`).
- JS SDK compatibility mode for JSON-RPC push notification field names
  (`jsonrpc_push_compat: :js_sdk`).
- Cross-SDK end-to-end test suites (Elixir client/JS server and JS client/Elixir server).
- Extensive new unit and integration tests covering transport auth retry,
  wire format matrix, client-server parity, push notifications, JSON-RPC
  extensions, and server handler edge cases.

### Fixed
- REST decoder now accepts JSON arrays in addition to JSON objects.
- Push config set request body shape corrected to match spec.
- Push config list response shape corrected to match spec.
- Agent card endpoint path corrected (`/.well-known/agent-card.json` and `/card`).
- JSON-RPC push notification parameter parsing accepts both `taskId`/`configId`
  and `id`/`pushNotificationConfigId` for cross-SDK compatibility.

## [0.1.0] - 2026-01-29

### Added
- REST and JSON-RPC transports with SSE streaming.
- Plug-based server handlers with request ID passthrough and timeout handling.
- Task store behavior and ETS adapter with cursor pagination.
- Push notification delivery and webhook validation.
- Extension negotiation helpers and version compatibility options.
- SSE reconnection utilities and artifact merge helpers.
- gRPC transport placeholder returning unsupported operation errors.
