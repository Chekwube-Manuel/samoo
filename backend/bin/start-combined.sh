#!/bin/sh
# start-combined.sh — runs API + arq worker in one backend container
set -e

echo "==> Starting Samoo backend (API + worker)..."

.venv/bin/arq src.workers.tasks.WorkerSettings &
WORKER_PID=$!
echo "==> Worker started (PID $WORKER_PID)"

.venv/bin/uvicorn src.main_refactored:app --host 0.0.0.0 --port 8000 &
API_PID=$!
echo "==> API started (PID $API_PID)"

wait -n 2>/dev/null || wait $API_PID
echo "==> A process exited — shutting down"
kill $WORKER_PID $API_PID 2>/dev/null || true
wait
exit 1
