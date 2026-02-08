// E2E: JS SDK v0.3.10 client -> Elixir server
//
// Coverage in this script:
// - discovery + transport negotiation from agent card
// - agent card edge behavior (authenticated extended card + alias methods)
// - auth challenge/retry (401 + WWW-Authenticate)
// - error contract interoperability (invalid params/method not found/task not found)
// - JSON-RPC and REST send_message
// - task lifecycle parity (get/cancel/resubscribe + list + subscribe)
// - JSON-RPC and REST sendMessageStream
// - push config lifecycle (set/get/list/delete) + real webhook delivery
//
// Run:
//   node examples/e2e_js_client_elixir_server.mjs

import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { execFile as execFileCb } from "node:child_process";
import { promisify } from "node:util";
import { createRequire } from "node:module";
import { randomUUID } from "node:crypto";

const execFile = promisify(execFileCb);
const __dirname = dirname(fileURLToPath(import.meta.url));
const jsDir = resolve(__dirname, "js_sdk_e2e");
const elixirScript = resolve(jsDir, "elixir_server_for_js_client.exs");
const host = "127.0.0.1";
const port = 4311;
const baseUrl = `http://${host}:${port}`;
const authToken = "retry-token";
const requiredExtension = "https://example.com/extensions/e2e";

async function ensureDeps() {
  await execFile("npm", ["install"], { cwd: jsDir });
}

async function loadJsSdk() {
  const req = createRequire(resolve(jsDir, "package.json"));
  const clientPath = req.resolve("@a2a-js/sdk/client");
  const mod = await import(clientPath);
  return mod;
}

async function waitHealthy(timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  const url = `${baseUrl}/health`;

  while (Date.now() <= deadline) {
    try {
      const res = await fetch(url);
      if (res.ok) return;
    } catch {
      // no-op
    }

    await delay(120);
  }

  throw new Error(`Elixir server not healthy at ${url}`);
}

function spawnElixirServer() {
  const child = spawn(
    "elixir",
    [elixirScript],
    {
      cwd: resolve(__dirname, ".."),
      env: {
        ...process.env,
        A2A_E2E_ELIXIR_SERVER_HOST: host,
        A2A_E2E_ELIXIR_SERVER_PORT: String(port),
        A2A_E2E_AUTH_TOKEN: authToken,
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );

  child.stdout.on("data", (d) => process.stdout.write(`[elixir-server] ${d}`));
  child.stderr.on("data", (d) => process.stderr.write(`[elixir-server] ${d}`));

  return child;
}

async function runChecks() {
  const {
    ClientFactory,
    ClientFactoryOptions,
    JsonRpcTransportFactory,
    RestTransportFactory,
    createAuthenticatingFetchWithRetry,
  } = await loadJsSdk();

  let currentToken = "stale-token";
  const authHandler = {
    headers: async () => ({
      Authorization: `Bearer ${currentToken}`,
      "a2a-extensions": requiredExtension,
    }),
    shouldRetryWithHeaders: async (_req, res) => {
      if (res.status === 401) {
        currentToken = authToken;
        return {
          Authorization: `Bearer ${currentToken}`,
          "a2a-extensions": requiredExtension,
        };
      }
      return undefined;
    },
  };
  const authFetch = createAuthenticatingFetchWithRetry(fetch, authHandler);

  const defaultFactory = new ClientFactory(ClientFactoryOptions.createFrom(ClientFactoryOptions.default, {
    transports: [
      new JsonRpcTransportFactory({ fetchImpl: authFetch }),
      new RestTransportFactory({ fetchImpl: authFetch }),
    ],
  }));

  // Negotiation path (card preferred transport).
  const negotiatedClient = await defaultFactory.createFromUrl(baseUrl);

  await runExtensionNegotiationChecks();
  await runAgentCardEdgeChecks(negotiatedClient, authFetch);
  await runErrorContractChecks(authFetch);

  const negotiatedResponse = await negotiatedClient.sendMessage({
    message: {
      kind: "message",
      messageId: randomUUID(),
      role: "user",
      parts: [{ kind: "text", text: "hello-negotiated" }],
    },
  });

  const taskId =
    negotiatedResponse?.id ??
    negotiatedResponse?.task?.id ??
    negotiatedResponse?.taskId ??
    negotiatedResponse?.message?.taskId;
  if (!taskId) {
    throw new Error(`Expected task response with id, got: ${JSON.stringify(negotiatedResponse)}`);
  }

  const responseText =
    negotiatedResponse?.message?.parts?.find((p) => p?.kind === "text")?.text ??
    negotiatedResponse?.parts?.find((p) => p?.kind === "text")?.text ??
    negotiatedResponse?.status?.message?.parts?.find((p) => p?.kind === "text")?.text ??
    negotiatedResponse?.task?.status?.message?.parts?.find((p) => p?.kind === "text")?.text;
  if (responseText !== "elixir-echo:hello-negotiated") {
    throw new Error(`Unexpected negotiated response text: ${JSON.stringify(negotiatedResponse)}`);
  }

  // JSON-RPC lifecycle methods.
  const rpcTask = await negotiatedClient.getTask({ name: `tasks/${taskId}` });
  if ((rpcTask?.id ?? rpcTask?.task?.id) !== taskId) {
    throw new Error(`Unexpected getTask response: ${JSON.stringify(rpcTask)}`);
  }

  const rpcCanceled = await negotiatedClient.cancelTask({ name: `tasks/${taskId}` });
  const canceledState = rpcCanceled?.status?.state ?? rpcCanceled?.task?.status?.state;
  if (canceledState !== "canceled") {
    throw new Error(`Unexpected cancelTask response: ${JSON.stringify(rpcCanceled)}`);
  }

  const rpcResubscribeEvents = [];
  for await (const event of negotiatedClient.resubscribeTask({ taskId })) {
    rpcResubscribeEvents.push(event);
    if (rpcResubscribeEvents.length >= 3) break;
  }
  if (rpcResubscribeEvents.length < 1) {
    throw new Error("JSON-RPC resubscribe produced no events");
  }
  if (!rpcResubscribeEvents.some((event) => streamEventTaskId(event) === taskId)) {
    throw new Error(`JSON-RPC resubscribe did not reference expected task: ${JSON.stringify(rpcResubscribeEvents)}`);
  }

  const listRpcRes = await authFetch(`${baseUrl}/`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 101,
      method: "tasks/list",
      params: {},
    }),
  });
  const listRpcBody = await listRpcRes.json();
  if (!Array.isArray(listRpcBody?.result?.tasks)) {
    throw new Error(`Unexpected tasks/list response: ${JSON.stringify(listRpcBody)}`);
  }

  const subscribeRpcRes = await authFetch(`${baseUrl}/`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "text/event-stream",
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 102,
      method: "tasks/subscribe",
      params: { taskId },
    }),
  });
  if (!subscribeRpcRes.ok) {
    throw new Error(`tasks/subscribe failed: ${subscribeRpcRes.status} ${await subscribeRpcRes.text()}`);
  }
  const subscribeBody = await subscribeRpcRes.text();
  if (!subscribeBody.includes("data:")) {
    throw new Error(`tasks/subscribe did not produce SSE data: ${subscribeBody}`);
  }

  // JSON-RPC streaming
  const rpcStreamEvents = [];
  for await (const event of negotiatedClient.sendMessageStream({
    message: {
      kind: "message",
      messageId: randomUUID(),
      role: "user",
      parts: [{ kind: "text", text: "stream-jsonrpc" }],
    },
  })) {
    rpcStreamEvents.push(event);
    if (hasFinalStatusEvent(rpcStreamEvents) || rpcStreamEvents.length >= 10) break;
  }
  if (rpcStreamEvents.length === 0) {
    throw new Error("JSON-RPC stream produced no events");
  }
  assertStreamSemantics(rpcStreamEvents, "JSON-RPC stream");

  // REST path via official JS SDK REST transport against proto_json compatibility mode.
  currentToken = "stale-token";
  const restOnlyFactory = new ClientFactory({
    transports: [new RestTransportFactory({ fetchImpl: authFetch })],
  });
  const restClient = await restOnlyFactory.createFromUrl(baseUrl);

  const restResponse = await restClient.sendMessage({
    message: {
      kind: "message",
      messageId: randomUUID(),
      role: "user",
      parts: [{ kind: "text", text: "hello-rest" }],
    },
  });

  const restTaskId = restResponse?.id ?? restResponse?.task?.id ?? restResponse?.message?.taskId;
  const restTaskIdWithMessage = restTaskId ?? restResponse?.taskId;
  if (!restTaskIdWithMessage) {
    throw new Error(`Unexpected REST response shape: ${JSON.stringify(restResponse)}`);
  }

  const restText =
    restResponse?.message?.parts?.find((p) => p?.kind === "text")?.text ??
    restResponse?.parts?.find((p) => p?.kind === "text")?.text ??
    restResponse?.status?.message?.parts?.find((p) => p?.kind === "text")?.text ??
    restResponse?.task?.status?.message?.parts?.find((p) => p?.kind === "text")?.text;
  if (restText !== "elixir-echo:hello-rest") {
    throw new Error(`Unexpected REST response text: ${JSON.stringify(restResponse)}`);
  }

  // REST lifecycle methods parity.
  const restGetRes = await authFetch(`${baseUrl}/v1/tasks/${restTaskIdWithMessage}`, { method: "GET" });
  if (!restGetRes.ok) {
    throw new Error(`REST get task failed: ${restGetRes.status} ${await restGetRes.text()}`);
  }
  const restTask = await restGetRes.json();
  if ((restTask?.id ?? restTask?.task?.id) !== restTaskIdWithMessage) {
    throw new Error(`Unexpected REST getTask response: ${JSON.stringify(restTask)}`);
  }

  const restCancelRes = await authFetch(`${baseUrl}/v1/tasks/${restTaskIdWithMessage}:cancel`, { method: "POST" });
  if (!restCancelRes.ok) {
    throw new Error(`REST cancel task failed: ${restCancelRes.status} ${await restCancelRes.text()}`);
  }
  const restCanceled = await restCancelRes.json();
  const restCanceledState = restCanceled?.status?.state ?? restCanceled?.task?.status?.state;
  if (restCanceledState !== "canceled") {
    throw new Error(`Unexpected REST cancelTask response: ${JSON.stringify(restCanceled)}`);
  }

  const restSubscribeRes = await authFetch(`${baseUrl}/v1/tasks/${restTaskIdWithMessage}:subscribe`, {
    method: "POST",
    headers: { accept: "text/event-stream" },
  });
  if (!restSubscribeRes.ok) {
    throw new Error(`REST subscribe failed: ${restSubscribeRes.status} ${await restSubscribeRes.text()}`);
  }
  const restSubscribeBody = await restSubscribeRes.text();
  if (!restSubscribeBody.includes("data:")) {
    throw new Error(`REST subscribe did not produce SSE data: ${restSubscribeBody}`);
  }
  const restSubscribeEvents = parseSseData(restSubscribeBody);
  if (!restSubscribeEvents.some((event) => streamEventTaskId(event) === restTaskIdWithMessage)) {
    throw new Error(`REST subscribe did not reference expected task: ${JSON.stringify(restSubscribeEvents)}`);
  }

  const restStreamRes = await authFetch(`${baseUrl}/v1/message:stream`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "text/event-stream",
    },
    body: JSON.stringify({
      message: {
        messageId: randomUUID(),
        role: "user",
        parts: [{ kind: "text", text: "stream-rest" }],
      },
    }),
  });
  if (!restStreamRes.ok) {
    throw new Error(`REST stream failed: ${restStreamRes.status} ${await restStreamRes.text()}`);
  }
  const restStreamBody = await restStreamRes.text();
  if (!restStreamBody.includes("data:")) {
    throw new Error(`REST stream did not produce SSE data: ${restStreamBody}`);
  }
  const restStreamEvents = parseSseData(restStreamBody);
  assertStreamSemantics(restStreamEvents, "REST stream");

  // REST push lifecycle via raw transport call (SDK REST push path is inconsistent here).
  const restPushConfigId = `cfg-rest-${randomUUID()}`;
  const restPushSetRes = await authFetch(
    `${baseUrl}/v1/tasks/${restTaskIdWithMessage}/pushNotificationConfigs`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        pushNotificationConfig: {
          id: restPushConfigId,
          url: "https://example.com/webhook",
          token: "tok-rest",
        },
      }),
    },
  );
  if (!restPushSetRes.ok) {
    throw new Error(`REST push set failed: ${restPushSetRes.status} ${await restPushSetRes.text()}`);
  }

  const restPushGetRes = await authFetch(
    `${baseUrl}/v1/tasks/${restTaskIdWithMessage}/pushNotificationConfigs/${restPushConfigId}`,
    { method: "GET" },
  );
  if (!restPushGetRes.ok) {
    throw new Error(`REST push get failed: ${restPushGetRes.status} ${await restPushGetRes.text()}`);
  }

  const restPushListRes = await authFetch(
    `${baseUrl}/v1/tasks/${restTaskIdWithMessage}/pushNotificationConfigs`,
    { method: "GET" },
  );
  if (!restPushListRes.ok) {
    throw new Error(`REST push list failed: ${restPushListRes.status} ${await restPushListRes.text()}`);
  }
  const restPushList = await restPushListRes.json();
  const restPushItems = Array.isArray(restPushList)
    ? restPushList
    : restPushList?.pushNotificationConfigs;
  if (!Array.isArray(restPushItems) || restPushItems.length === 0) {
    throw new Error(`Unexpected REST push list response: ${JSON.stringify(restPushList)}`);
  }

  const restPushDeleteRes = await authFetch(
    `${baseUrl}/v1/tasks/${restTaskIdWithMessage}/pushNotificationConfigs/${restPushConfigId}`,
    { method: "DELETE" },
  );
  if (!restPushDeleteRes.ok) {
    throw new Error(
      `REST push delete failed: ${restPushDeleteRes.status} ${await restPushDeleteRes.text()}`,
    );
  }

  // Push lifecycle
  const pushToken = "tok-1";
  const pushConfig = await negotiatedClient.setTaskPushNotificationConfig({
    taskId,
    pushNotificationConfig: {
      id: `cfg-${randomUUID()}`,
      url: `${baseUrl}/push-receiver`,
      token: pushToken,
    },
  });

  const pushConfigId = pushConfig?.pushNotificationConfig?.id ?? pushConfig?.id;
  if (!pushConfigId) {
    throw new Error(`Unexpected push config response: ${JSON.stringify(pushConfig)}`);
  }

  const pushFetched = await negotiatedClient.getTaskPushNotificationConfig({
    taskId,
    configId: pushConfigId,
  });
  const fetchedPushId = pushFetched?.pushNotificationConfig?.id ?? pushFetched?.id;
  if (fetchedPushId !== pushConfigId) {
    throw new Error(`Unexpected push get response: ${JSON.stringify(pushFetched)}`);
  }

  const pushList = await negotiatedClient.listTaskPushNotificationConfig({ taskId });
  const pushListItems = Array.isArray(pushList) ? pushList : pushList?.pushNotificationConfigs;
  if (!Array.isArray(pushListItems) || pushListItems.length === 0) {
    throw new Error(`Unexpected push list response: ${JSON.stringify(pushList)}`);
  }

  await negotiatedClient.sendMessage({
    message: {
      kind: "message",
      messageId: randomUUID(),
      taskId,
      role: "user",
      parts: [{ kind: "text", text: "push-followup" }],
    },
  });

  const pushEvent = await waitForPushEvent(taskId);
  if (pushEvent?.headers?.["x-a2a-notification-token"] !== pushToken) {
    throw new Error(`Unexpected push notification token header: ${JSON.stringify(pushEvent)}`);
  }
  const deliveredTaskId = pushEvent?.body?.id ?? pushEvent?.body?.taskId;
  if (deliveredTaskId !== taskId) {
    throw new Error(`Push payload task mismatch: ${JSON.stringify(pushEvent)}`);
  }

  await negotiatedClient.deleteTaskPushNotificationConfig({
    taskId,
    configId: pushConfigId,
  });

  // Ensure auth challenge path was actually exercised.
  const authStats = await (await fetch(`${baseUrl}/auth-attempts`)).json();
  if ((authStats?.unauthorized ?? 0) < 1 || (authStats?.authorized ?? 0) < 1) {
    throw new Error(`Auth challenge/retry not exercised: ${JSON.stringify(authStats)}`);
  }
}

async function runAgentCardEdgeChecks(negotiatedClient, authFetch) {
  const publicCardRes = await fetch(`${baseUrl}/.well-known/agent-card.json`);
  if (!publicCardRes.ok) {
    throw new Error(`Failed to fetch public card: ${publicCardRes.status}`);
  }
  const publicCard = await publicCardRes.json();
  if (publicCard?.supportsAuthenticatedExtendedCard !== true) {
    throw new Error(`Expected supportsAuthenticatedExtendedCard=true on public card: ${JSON.stringify(publicCard)}`);
  }
  const hasJsonRpcInterface = (publicCard?.additionalInterfaces ?? []).some(
    (iface) => iface?.transport === "JSONRPC",
  );
  const hasRestInterface = (publicCard?.additionalInterfaces ?? []).some(
    (iface) => iface?.transport === "HTTP+JSON",
  );
  if (!hasJsonRpcInterface || !hasRestInterface) {
    throw new Error(`Public card missing expected interfaces: ${JSON.stringify(publicCard?.additionalInterfaces)}`);
  }

  const extendedCard = await negotiatedClient.getAgentCard();
  const extendedSkillIds = (extendedCard?.skills ?? []).map((skill) => skill?.id);
  if (!extendedSkillIds.includes("extended-chat")) {
    throw new Error(`Expected extended card skill 'extended-chat': ${JSON.stringify(extendedCard)}`);
  }

  const authExtMethodRes = await authFetch(`${baseUrl}/`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 180,
      method: "agent/getAuthenticatedExtendedCard",
      params: {},
    }),
  });
  const authExtMethodBody = await authExtMethodRes.json();
  if (
    authExtMethodRes.status !== 200 ||
    authExtMethodBody?.result?.supportsAuthenticatedExtendedCard !== true
  ) {
    throw new Error(`Unexpected getAuthenticatedExtendedCard response: ${JSON.stringify({ status: authExtMethodRes.status, body: authExtMethodBody })}`);
  }

  const legacyExtMethodRes = await authFetch(`${baseUrl}/`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 181,
      method: "agent/getExtendedCard",
      params: {},
    }),
  });
  const legacyExtMethodBody = await legacyExtMethodRes.json();
  if (
    legacyExtMethodRes.status !== 200 ||
    legacyExtMethodBody?.result?.supportsAuthenticatedExtendedCard !== true
  ) {
    throw new Error(`Unexpected legacy getExtendedCard response: ${JSON.stringify({ status: legacyExtMethodRes.status, body: legacyExtMethodBody })}`);
  }
}

async function waitForPushEvent(taskId, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() <= deadline) {
    const res = await fetch(`${baseUrl}/push-events`);
    if (res.ok) {
      const payload = await res.json();
      const events = payload?.events;
      if (Array.isArray(events)) {
        const match = events.find((event) => {
          const body = event?.body ?? {};
          return body.id === taskId || body.taskId === taskId;
        });
        if (match) return match;
      }
    }

    await delay(120);
  }

  throw new Error(`Timed out waiting for push delivery for task ${taskId}`);
}

async function runErrorContractChecks(authFetch) {
  // JSON-RPC: method not found
  const unknownMethodRes = await authFetch(`${baseUrl}/`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 301,
      method: "tasks/notARealMethod",
      params: {},
    }),
  });
  const unknownMethodBody = await unknownMethodRes.json();
  if (unknownMethodRes.status !== 200 || unknownMethodBody?.error?.code !== -32601) {
    throw new Error(`Unexpected JSON-RPC method-not-found response: ${JSON.stringify({ status: unknownMethodRes.status, body: unknownMethodBody })}`);
  }

  // JSON-RPC: invalid params
  const invalidParamsRes = await authFetch(`${baseUrl}/`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 302,
      method: "tasks/get",
      params: [],
    }),
  });
  const invalidParamsBody = await invalidParamsRes.json();
  if (invalidParamsRes.status !== 200 || invalidParamsBody?.error?.code !== -32602) {
    throw new Error(`Unexpected JSON-RPC invalid-params response: ${JSON.stringify({ status: invalidParamsRes.status, body: invalidParamsBody })}`);
  }

  // JSON-RPC: task not found
  const taskNotFoundRes = await authFetch(`${baseUrl}/`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 303,
      method: "tasks/get",
      params: { id: "task-does-not-exist" },
    }),
  });
  const taskNotFoundBody = await taskNotFoundRes.json();
  if (taskNotFoundRes.status !== 200 || !taskNotFoundBody?.error) {
    throw new Error(`Unexpected JSON-RPC task-not-found response: ${JSON.stringify({ status: taskNotFoundRes.status, body: taskNotFoundBody })}`);
  }

  // REST: invalid params
  const restInvalidRes = await authFetch(`${baseUrl}/v1/message:send`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({}),
  });
  if (restInvalidRes.status < 400) {
    throw new Error(`Expected REST invalid-params to be 4xx/5xx, got ${restInvalidRes.status}`);
  }

  // REST: task not found
  const restTaskNotFoundRes = await authFetch(`${baseUrl}/v1/tasks/task-does-not-exist`, {
    method: "GET",
  });
  if (restTaskNotFoundRes.status < 400) {
    throw new Error(`Expected REST task-not-found to be 4xx/5xx, got ${restTaskNotFoundRes.status}`);
  }
}

async function runExtensionNegotiationChecks() {
  // Missing required extension on JSON-RPC should fail.
  const missingRpc = await fetch(`${baseUrl}/`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${authToken}`,
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 290,
      method: "message/send",
      params: {
        message: {
          messageId: randomUUID(),
          role: "user",
          parts: [{ kind: "text", text: "missing extension jsonrpc" }],
        },
      },
    }),
  });
  const missingRpcBody = await missingRpc.json();
  if (missingRpc.status !== 200 || missingRpcBody?.error?.code !== -32000) {
    throw new Error(`Unexpected JSON-RPC missing-extension response: ${JSON.stringify({ status: missingRpc.status, body: missingRpcBody })}`);
  }

  // Missing required extension on REST should fail.
  const missingRest = await fetch(`${baseUrl}/v1/message:send`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${authToken}`,
    },
    body: JSON.stringify({
      message: {
        messageId: randomUUID(),
        role: "user",
        parts: [{ kind: "text", text: "missing extension rest" }],
      },
    }),
  });
  if (missingRest.status < 400) {
    throw new Error(`Expected REST missing-extension failure, got ${missingRest.status}`);
  }
}

function parseSseData(body) {
  const events = [];
  const chunks = body.split("\n\n");
  for (const chunk of chunks) {
    const dataLines = chunk
      .split("\n")
      .filter((line) => line.startsWith("data:"))
      .map((line) => line.slice(5).trim())
      .filter(Boolean);
    if (dataLines.length === 0) continue;
    const data = dataLines.join("\n");
    try {
      const parsed = JSON.parse(data);
      events.push(parsed?.result ?? parsed);
    } catch {
      // ignore malformed frames
    }
  }
  return events;
}

function streamEventKind(event) {
  if (!event || typeof event !== "object") return "unknown";
  if (event.kind === "task" || (event.id && event.status && !event.taskId)) return "task";
  if (event.kind === "status-update" || event.statusUpdate || (event.taskId && event.status)) return "status";
  if (event.kind === "artifact-update" || event.artifactUpdate || (event.taskId && event.artifact)) return "artifact";
  if (event.kind === "message" || event.message || event.messageId) return "message";
  if (event.task) return "task";
  return "unknown";
}

function streamEventTaskId(event) {
  if (!event || typeof event !== "object") return undefined;
  if (event.taskId) return event.taskId;
  if (event.id && (event.kind === "task" || event.status)) return event.id;
  if (event.task?.id) return event.task.id;
  if (event.statusUpdate?.taskId) return event.statusUpdate.taskId;
  if (event.artifactUpdate?.taskId) return event.artifactUpdate.taskId;
  if (event.message?.taskId) return event.message.taskId;
  return undefined;
}

function isFinalStatusEvent(event) {
  if (!event || typeof event !== "object") return false;
  if (event.kind === "status-update" && event.final === true) return true;
  if (event.statusUpdate?.final === true) return true;
  if (event.taskId && event.status && event.final === true) return true;
  return false;
}

function hasFinalStatusEvent(events) {
  return events.some((event) => isFinalStatusEvent(event));
}

function assertStreamSemantics(events, label) {
  if (!Array.isArray(events) || events.length < 2) {
    throw new Error(`${label} expected multiple events, got ${JSON.stringify(events)}`);
  }

  const kinds = events.map((event) => streamEventKind(event));
  const taskIndex = kinds.indexOf("task");
  const statusIndexes = kinds.map((kind, idx) => (kind === "status" ? idx : -1)).filter((idx) => idx >= 0);
  const artifactIndex = kinds.indexOf("artifact");

  if (taskIndex < 0) throw new Error(`${label} missing task event: ${JSON.stringify(events)}`);
  if (statusIndexes.length === 0) throw new Error(`${label} missing status events: ${JSON.stringify(events)}`);
  if (artifactIndex < 0) throw new Error(`${label} missing artifact event: ${JSON.stringify(events)}`);
  if (!hasFinalStatusEvent(events)) throw new Error(`${label} missing final status event: ${JSON.stringify(events)}`);

  const firstStatus = Math.min(...statusIndexes);
  const lastStatus = Math.max(...statusIndexes);

  if (!(taskIndex < firstStatus)) {
    throw new Error(`${label} task event should occur before first status event`);
  }
  if (!(firstStatus < artifactIndex)) {
    throw new Error(`${label} working status should occur before artifact event`);
  }
  if (!(artifactIndex <= lastStatus)) {
    throw new Error(`${label} artifact event should occur before or at final status event`);
  }
}

async function main() {
  await ensureDeps();
  const child = spawnElixirServer();

  try {
    await waitHealthy();
    await runChecks();
    console.log("E2E passed: JS client -> Elixir server");
  } finally {
    child.kill("SIGTERM");
    await new Promise((resolveDone) => {
      child.once("close", () => resolveDone());
      setTimeout(resolveDone, 500);
    });
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
