#!/bin/sh
# start-combined.sh
# Runs the FastAPI backend AND arq worker in the same container.
# Used for single-service Render deployments where both processes need
# access to the same filesystem (uploads/clips).
#
# Both processes write to stdout/stderr which Render captures in logs.
# If either process exits, the container restarts (Render's restart policy).

set -e

echo "Starting SupoClip combined (API + worker)..."

# Start the arq worker in the background
.venv/bin/arq src.workers.tasks.WorkerSettings &
WORKER_PID=$!
echo "Worker started (PID $WORKER_PID)"

# Start uvicorn in the foreground (this keeps the container alive)
# Render health checks hit /health/db so the web service stays healthy
.venv/bin/uvicorn src.main_refactored:app --host 0.0.0.0 --port 8000 &
API_PID=$!
echo "API started (PID $API_PID)"

# Wait for either process to exit, then kill both and exit
wait -n 2>/dev/null || {
    # wait -n not available in all sh versions — fall back to waiting on API
    wait $API_PID
}

echo "A process exited — shutting down both"
kill $WORKER_PID 2>/dev/null || true
kill $API_PID 2>/dev/null || true
wait
exit 1
