#!/usr/bin/env bash
set -euo pipefail

REST_PORT="${A2A_TCK_REST_PORT:-9999}"

MIX_ENV=test mix run scripts/v1_tck_server.exs &
sut_pid=$!
trap 'kill "${sut_pid}" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:${REST_PORT}/.well-known/agent-card.json" >/dev/null; then
    break
  fi
  sleep 0.1
done

curl -fsS "http://127.0.0.1:${REST_PORT}/.well-known/agent-card.json" >/dev/null

uv run --with a2a-sdk==1.1.1 test/interop/v1_python_sdk_client.py
