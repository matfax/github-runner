#!/bin/bash
set -euo pipefail

cd /home/runner

if [[ -z "${REPO_URL:-}" ]]; then
  echo "REPO_URL env var is required."
  exit 1
fi

# Cleanup function to deregister runner from GitHub
cleanup_runner() {
  if [[ -n "${PAT_TOKEN:-}" ]] && [[ -f .runner ]]; then
    echo "🧹 Deregistering runner from GitHub..."
    ./config.sh remove --token "${PAT_TOKEN}" || {
      echo "⚠️ Failed to deregister runner, but continuing with exit."
    }
  fi
}

# Register cleanup to run on exit
trap cleanup_runner EXIT

if [[ ! -d .runner ]]; then
  if [[ -z "${REG_TOKEN:-}" ]]; then
    echo "REG_TOKEN env var is required for initial configuration."
    exit 1
  fi

  NAME="${RUNNER_NAME:-runner-$(hostname)}"
  LABELS="${RUNNER_LABELS:-self-hosted,linux,docker}"
  WORKDIR="${RUNNER_WORKDIR:-/home/runner/_work}"

  ./config.sh \
    --url "${REPO_URL}" \
    --token "${REG_TOKEN}" \
    --name "${NAME}" \
    --unattended \
    --replace \
    --work "${WORKDIR}" \
    --labels "${LABELS}"

  # Avoid leaving the token lying around
  unset REG_TOKEN
else
  echo "Runner already configured. Skipping config."
fi

# Idle watchdog
echo "✅ Listening for jobs..."
DIAG_PATH="./_diag"
IDLE_TIMEOUT_MINUTES=${RUNNER_IDLE_TIMEOUT_MINUTES:-15}
MAX_RESTARTS=${RUNNER_MAX_RESTARTS:-5}
RESTART_COUNT=0

while [[ $RESTART_COUNT -lt $MAX_RESTARTS ]]; do
  ./run.sh &
  RUN_PID=$!
  LAST_ACTIVITY=$(date +%s)
  IDLE_STOP=false

  while kill -0 "$RUN_PID" 2>/dev/null; do
    if [[ -d "$DIAG_PATH" ]]; then
      # newest file mtime
      LATEST_FILE=$(ls -t "$DIAG_PATH" 2>/dev/null | head -n1 || true)
      if [[ -n "$LATEST_FILE" ]]; then
        LAST_ACTIVITY=$(stat -c %Y "$DIAG_PATH/$LATEST_FILE")
      fi
    fi

    NOW=$(date +%s)
    IDLE_MINUTES=$(( (NOW - LAST_ACTIVITY) / 60 ))
    if (( IDLE_MINUTES >= IDLE_TIMEOUT_MINUTES )); then
      echo "⏱️ Idle timeout (${IDLE_TIMEOUT_MINUTES} min) reached. Stopping runner..."
      IDLE_STOP=true
      kill "$RUN_PID" 2>/dev/null || true
      break
    fi

    sleep 10
  done

  if kill -0 "$RUN_PID" 2>/dev/null; then
    wait "$RUN_PID" || true
  fi

  if [[ "$IDLE_STOP" == "true" ]]; then
    echo "🛑 Runner stopped due to idle timeout. Exiting container."
    exit 0
  fi

  RESTART_COUNT=$((RESTART_COUNT + 1))
  if [[ $RESTART_COUNT -ge $MAX_RESTARTS ]]; then
    echo "❌ Max restarts ($MAX_RESTARTS) reached. Exiting container."
    exit 1
  fi

  echo "⚠️ Runner exited (code $?) Restarting run.sh inside container (attempt $((RESTART_COUNT+1)) of $MAX_RESTARTS)..."
  sleep 5
done

echo "❌ Max restart loop exited unexpectedly."
exit 1
