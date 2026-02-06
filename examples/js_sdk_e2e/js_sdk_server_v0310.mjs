import express from "express";
import { v4 as uuidv4 } from "uuid";
import { AGENT_CARD_PATH } from "@a2a-js/sdk";
import { DefaultRequestHandler, InMemoryTaskStore } from "@a2a-js/sdk/server";
import {
  agentCardHandler,
  jsonRpcHandler,
  restHandler,
  UserBuilder,
} from "@a2a-js/sdk/server/express";

const port = Number(process.env.A2A_E2E_JS_SERVER_PORT || 4310);
const host = process.env.A2A_E2E_JS_SERVER_HOST || "127.0.0.1";
const expectedToken = process.env.A2A_E2E_AUTH_TOKEN || "retry-token";

const authStats = {
  authorized: 0,
  unauthorized: 0,
};
const pushEvents = [];

const agentCard = {
  name: "A2A JS SDK v0.3.10 Server",
  description: "Cross-language E2E fixture for a2a_ex",
  protocolVersion: "0.3.0",
  version: "0.1.0",
  url: `http://${host}:${port}/a2a/jsonrpc`,
  preferredTransport: "JSONRPC",
  skills: [{ id: "chat", name: "Chat", description: "Echo + stream", tags: ["chat"] }],
  capabilities: {
    streaming: true,
    pushNotifications: true,
  },
  defaultInputModes: ["text"],
  defaultOutputModes: ["text"],
  additionalInterfaces: [
    { url: `http://${host}:${port}/a2a/jsonrpc`, transport: "JSONRPC" },
    { url: `http://${host}:${port}/a2a/rest`, transport: "HTTP+JSON" },
  ],
};

function authGuard(req, res, next) {
  const auth = req.get("authorization");
  if (auth === `Bearer ${expectedToken}`) {
    authStats.authorized += 1;
    return next();
  }

  authStats.unauthorized += 1;
  res.set("WWW-Authenticate", 'Bearer realm="a2a", error="invalid_token"');
  return res.status(401).json({ error: "Unauthorized" });
}

class E2EExecutor {
  async execute(requestContext, eventBus) {
    const incomingText =
      requestContext.userMessage?.parts?.find((p) => p?.kind === "text")?.text ?? "";
    const taskId = requestContext.taskId;
    const contextId = requestContext.contextId;

    const initialTask = {
      kind: "task",
      id: taskId,
      contextId,
      history: [requestContext.userMessage],
      status: {
        state: "submitted",
        timestamp: new Date().toISOString(),
      },
    };
    eventBus.publish(initialTask);

    if (incomingText.includes("stream")) {
      eventBus.publish({
        kind: "status-update",
        taskId,
        contextId,
        status: { state: "working", timestamp: new Date().toISOString() },
        final: false,
      });

      eventBus.publish({
        kind: "artifact-update",
        taskId,
        contextId,
        append: false,
        lastChunk: true,
        artifact: {
          artifactId: `art-${uuidv4()}`,
          name: "stream",
          parts: [{ kind: "text", text: "js-stream-chunk" }],
        },
      });
    } else {
      eventBus.publish({
        kind: "message",
        messageId: uuidv4(),
        role: "agent",
        parts: [{ kind: "text", text: `js-sdk-echo:${incomingText}` }],
        contextId,
        taskId,
      });
    }

    eventBus.publish({
      kind: "status-update",
      taskId,
      contextId,
      status: { state: "completed", timestamp: new Date().toISOString() },
      final: true,
    });

    eventBus.finished();
  }

  cancelTask = async (_taskId, eventBus) => {
    eventBus.finished();
  };
}

const app = express();
app.get("/health", (_req, res) => res.status(200).json({ ok: true }));
app.get("/auth-attempts", (_req, res) => res.status(200).json(authStats));
app.get("/debug/card", async (_req, res) => {
  const card = await requestHandler.getAgentCard();
  res.status(200).json(card);
});
app.post("/push-receiver", express.json(), (req, res) => {
  pushEvents.push({
    headers: {
      "x-a2a-notification-token": req.get("x-a2a-notification-token") ?? null,
    },
    body: req.body,
    receivedAt: new Date().toISOString(),
  });
  res.status(204).end();
});
app.get("/debug/push-events", (_req, res) => {
  res.status(200).json({ events: pushEvents });
});

const requestHandler = new DefaultRequestHandler(
  agentCard,
  new InMemoryTaskStore(),
  new E2EExecutor(),
);

app.use(`/${AGENT_CARD_PATH}`, agentCardHandler({ agentCardProvider: requestHandler }));
app.use("/a2a/jsonrpc", authGuard, jsonRpcHandler({ requestHandler, userBuilder: UserBuilder.noAuthentication }));
app.use("/a2a/rest", authGuard, restHandler({ requestHandler, userBuilder: UserBuilder.noAuthentication }));

const server = app.listen(port, host, () => {
  console.log(`E2E_JS_SERVER_READY http://${host}:${port}`);
});

function shutdown() {
  server.close(() => process.exit(0));
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
