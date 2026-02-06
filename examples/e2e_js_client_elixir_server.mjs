// E2E: JS SDK v0.3.10 client -> Elixir server
//
// Coverage in this script:
// - discovery + transport negotiation from agent card
// - auth challenge/retry (401 + WWW-Authenticate)
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
    headers: async () => ({ Authorization: `Bearer ${currentToken}` }),
    shouldRetryWithHeaders: async (_req, res) => {
      if (res.status === 401) {
        currentToken = authToken;
        return { Authorization: `Bearer ${currentToken}` };
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

  let rpcResubscribeEvents = 0;
  for await (const event of negotiatedClient.resubscribeTask({ taskId })) {
    rpcResubscribeEvents += 1;
    if (rpcResubscribeEvents >= 1) break;
  }
  if (rpcResubscribeEvents < 1) {
    throw new Error("JSON-RPC resubscribe produced no events");
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
  let streamCount = 0;
  for await (const event of negotiatedClient.sendMessageStream({
    message: {
      kind: "message",
      messageId: randomUUID(),
      role: "user",
      parts: [{ kind: "text", text: "stream-jsonrpc" }],
    },
  })) {
    streamCount += 1;
    if (streamCount >= 2) break;
  }
  if (streamCount === 0) {
    throw new Error("JSON-RPC stream produced no events");
  }

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
