#!/usr/bin/env bash
set -euo pipefail

TCK_REVISION="5996b79f9cefa6fc390980e383e358a66fb9e49e"
TCK_DIR="${A2A_TCK_DIR:-${TMPDIR:-/tmp}/a2a-tck-${TCK_REVISION}}"
REST_PORT="${A2A_TCK_REST_PORT:-9999}"

if [[ ! -d "${TCK_DIR}/.git" ]]; then
  git clone https://github.com/a2aproject/a2a-tck.git "${TCK_DIR}"
  git -C "${TCK_DIR}" checkout --detach "${TCK_REVISION}"
fi

actual_revision="$(git -C "${TCK_DIR}" rev-parse HEAD)"
if [[ "${actual_revision}" != "${TCK_REVISION}" ]]; then
  echo "A2A TCK must be at ${TCK_REVISION}; found ${actual_revision}" >&2
  exit 2
fi

MIX_ENV=test mix run scripts/v1_tck_server.exs &
sut_pid=$!
trap 'kill "${sut_pid}" 2>/dev/null || true' EXIT

for _ in $(seq 1 240); do
  if curl -fsS "http://127.0.0.1:${REST_PORT}/.well-known/agent-card.json" >/dev/null; then
    break
  fi

  if ! kill -0 "${sut_pid}" 2>/dev/null; then
    echo "A2A v1.0 TCK SUT exited before becoming ready" >&2
    wait "${sut_pid}"
  fi

  sleep 0.25
done

curl -fsS "http://127.0.0.1:${REST_PORT}/.well-known/agent-card.json" >/dev/null

(
  cd "${TCK_DIR}"
  uv run ./run_tck.py \
    --sut-host "http://127.0.0.1:${REST_PORT}" \
    --transport jsonrpc,http_json "$@"
)
