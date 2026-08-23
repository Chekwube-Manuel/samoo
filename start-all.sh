#!/bin/sh
# start-all.sh
# Starts all three processes in one container:
#   1. FastAPI backend (port 8000, internal only)
#   2. arq worker (no port, processes video jobs)
#   3. Next.js frontend (port 10000, public)
#
# Next.js proxies API calls to localhost:8000 via BACKEND_INTERNAL_URL.
# Render health checks hit / on port 10000 (Next.js).

set -e

# Render injects PORT=10000 — Next.js must listen on it
export PORT=${PORT:-10000}

echo "==> Starting SupoClip (combined container)"
echo "    Frontend port : $PORT"
echo "    Backend port  : 8000 (internal)"
echo "    DB            : ${DATABASE_URL:-not set}"

# Point frontend at the local backend
export BACKEND_INTERNAL_URL="http://localhost:8000"
export NEXT_PUBLIC_API_URL="http://localhost:8000"

# Prisma uses standard postgresql:// — use FRONTEND_DATABASE_URL if set
if [ -n "$FRONTEND_DATABASE_URL" ]; then
    export DATABASE_URL_PRISMA="$FRONTEND_DATABASE_URL"
else
    # Strip +asyncpg from DATABASE_URL for Prisma if needed
    export DATABASE_URL_PRISMA=$(echo "$DATABASE_URL" | sed 's|postgresql+asyncpg://|postgresql://|')
fi

# Start the FastAPI backend
cd /app/backend
.venv/bin/uvicorn src.main_refactored:app --host 0.0.0.0 --port 8000 &
BACKEND_PID=$!
echo "==> Backend started (PID $BACKEND_PID)"

# Start the arq worker
.venv/bin/arq src.workers.tasks.WorkerSettings &
WORKER_PID=$!
echo "==> Worker started (PID $WORKER_PID)"

# Wait for backend to be ready before starting frontend
echo "==> Waiting for backend..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:8000/health > /dev/null 2>&1; then
        echo "==> Backend ready"
        break
    fi
    sleep 2
done

# Start Next.js frontend (standalone server) on $PORT
cd /app/frontend
DATABASE_URL="$DATABASE_URL_PRISMA" node server.js &
FRONTEND_PID=$!
echo "==> Frontend started (PID $FRONTEND_PID)"

# If any process exits, kill everything and let Render restart
wait -n 2>/dev/null || wait $FRONTEND_PID

echo "==> A process exited — shutting down"
kill $BACKEND_PID $WORKER_PID $FRONTEND_PID 2>/dev/null || true
wait
exit 1
