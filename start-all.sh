#!/bin/sh
# start-all.sh — runs frontend + backend + arq worker in one container
set -e

export PORT=${PORT:-10000}

echo "==> Starting Samoo"
echo "    Frontend : port $PORT"
echo "    Backend  : port 8000 (internal)"
echo "    Redis    : ${REDIS_HOST:-not set}"

# Derive Redis host/port/password from REDIS_URL if separate vars not provided
if [ -n "$REDIS_URL" ] && [ -z "$REDIS_HOST" ]; then
    REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://[^@]*@||; s|redis://||; s|:.*||')
    REDIS_PORT=$(echo "$REDIS_URL" | sed 's|.*:||; s|/.*||')
    REDIS_PASSWORD=$(echo "$REDIS_URL" | sed 's|redis://:||; s|@.*||')
    export REDIS_HOST REDIS_PORT REDIS_PASSWORD
    echo "    Derived Redis: $REDIS_HOST:$REDIS_PORT"
fi

export BACKEND_INTERNAL_URL="http://localhost:8000"

# Prisma needs standard postgresql:// not postgresql+asyncpg://
if [ -n "$FRONTEND_DATABASE_URL" ]; then
    export DATABASE_URL_PRISMA="$FRONTEND_DATABASE_URL"
else
    export DATABASE_URL_PRISMA=$(echo "$DATABASE_URL" | sed 's|postgresql+asyncpg://|postgresql://|')
fi

echo "==> Starting FastAPI backend..."
cd /app/backend
.venv/bin/uvicorn src.main_refactored:app --host 0.0.0.0 --port 8000 &
BACKEND_PID=$!

echo "==> Starting arq worker (retries if Redis unavailable)..."
(
    while true; do
        cd /app/backend
        .venv/bin/arq src.workers.tasks.WorkerSettings || true
        echo "==> Worker exited, retrying in 10s..."
        sleep 10
    done
) &
WORKER_PID=$!

echo "==> Waiting for backend..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:8000/health > /dev/null 2>&1; then
        echo "==> Backend ready"
        break
    fi
    sleep 2
done

echo "==> Starting Next.js on port $PORT..."
cd /app/frontend
DATABASE_URL="$DATABASE_URL_PRISMA" \
BETTER_AUTH_SECRET="$BETTER_AUTH_SECRET" \
BETTER_AUTH_URL="$BETTER_AUTH_URL" \
BACKEND_AUTH_SECRET="$BACKEND_AUTH_SECRET" \
APP_SETTINGS_ENCRYPTION_KEY="$APP_SETTINGS_ENCRYPTION_KEY" \
BACKEND_INTERNAL_URL="http://localhost:8000" \
NEXT_PUBLIC_APP_URL="$NEXT_PUBLIC_APP_URL" \
SELF_HOST="$SELF_HOST" \
NODE_ENV=production \
PORT="$PORT" \
node server.js &
FRONTEND_PID=$!

echo "==> All up — Backend=$BACKEND_PID Worker=$WORKER_PID Frontend=$FRONTEND_PID"

wait -n 2>/dev/null || wait $FRONTEND_PID
echo "==> A process exited — shutting down"
kill $BACKEND_PID $WORKER_PID $FRONTEND_PID 2>/dev/null || true
wait
exit 1
