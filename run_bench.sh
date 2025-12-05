#!/usr/bin/env bash
set -euo pipefail

# Config (override via env if you like)
REPEAT="${REPEAT:-5}"
PROGRAM="${PROGRAM:-linear_test}"
PORT_BASE="${PORT_BASE:-14000}"
HOST="${HOST:-127.0.0.1}"
SECURITY="${SECURITY:-16}"

# Fixed flags for your run
FLAGS="-F -N 2 -S ${SECURITY} -h ${HOST}"

mkdir -p logs

for i in $(seq 1 "${REPEAT}"); do
  PORT=$((PORT_BASE + i - 1))
  echo "=== Run ${i}/${REPEAT} | port ${PORT} | program ${PROGRAM} ==="

  /usr/bin/time -l ./mascot-party.x ${FLAGS} -pn "${PORT}" 0 "${PROGRAM}" &> "logs/run${i}_p0.log" &
  pid0=$!

  /usr/bin/time -l ./mascot-party.x ${FLAGS} -pn "${PORT}" 1 "${PROGRAM}" &> "logs/run${i}_p1.log" &
  pid1=$!

  # Wait and fail fast if either side errors; clean up the other if so
  if ! wait "${pid0}"; then
    echo "Party 0 failed on run ${i}"
    kill "${pid1}" 2>/dev/null || true
    exit 1
  fi
  if ! wait "${pid1}"; then
    echo "Party 1 failed on run ${i}"
    exit 1
  fi

  echo "=== Run ${i} complete ==="
  sleep 1
done

echo "All ${REPEAT} runs finished. Logs are in ./logs/ and CSV in mp-spdz-bench.csv"
