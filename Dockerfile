# =============================================================================
# Samoo — Single-container build (Frontend + Backend + Worker)
# Runs on ONE Render service, ONE port (3107 proxied to frontend,
# backend API available internally on 8000).
#
# Stages:
#   1. frontend-deps   — install Node deps
#   2. frontend-build  — build Next.js standalone
#   3. app             — Python + Node runtime, copy everything in
# =============================================================================

# ── Stage 1: install frontend Node dependencies ──────────────────────────────
FROM node:22-bookworm-slim AS frontend-deps

ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"

RUN npm install -g pnpm@10.27.0

WORKDIR /frontend

RUN apt-get update && apt-get install -y openssl && rm -rf /var/lib/apt/lists/*

COPY frontend/package.json frontend/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile --ignore-scripts


# ── Stage 2: build Next.js ───────────────────────────────────────────────────
FROM node:22-bookworm-slim AS frontend-build

ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
ENV NEXT_TELEMETRY_DISABLED=1
ENV SKIP_LINT=1

RUN npm install -g pnpm@10.27.0

WORKDIR /frontend

RUN apt-get update && apt-get install -y openssl && rm -rf /var/lib/apt/lists/*

COPY --from=frontend-deps /frontend/node_modules ./node_modules
COPY frontend/ .

RUN pnpm exec prisma generate

# Build-time public vars — baked into the Next.js bundle
ARG NEXT_PUBLIC_API_URL=http://localhost:8000
ARG NEXT_PUBLIC_APP_URL=http://localhost:10000
ARG NEXT_PUBLIC_SELF_HOST=true
ARG NEXT_PUBLIC_PRO_PRICE_MONTHLY=10
ARG NEXT_PUBLIC_SCALE_PRICE_MONTHLY=50
ARG NEXT_PUBLIC_FREE_PLAN_TASK_LIMIT=10
ARG NEXT_PUBLIC_PRO_PLAN_TASK_LIMIT=50
ARG NEXT_PUBLIC_SCALE_PLAN_TASK_LIMIT=300
ARG NEXT_PUBLIC_DATAFAST_WEBSITE_ID=
ARG NEXT_PUBLIC_DATAFAST_DOMAIN=
ARG NEXT_PUBLIC_DATAFAST_ALLOW_LOCALHOST=false

ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL}
ENV NEXT_PUBLIC_APP_URL=${NEXT_PUBLIC_APP_URL}
ENV NEXT_PUBLIC_SELF_HOST=${NEXT_PUBLIC_SELF_HOST}
ENV NEXT_PUBLIC_PRO_PRICE_MONTHLY=${NEXT_PUBLIC_PRO_PRICE_MONTHLY}
ENV NEXT_PUBLIC_SCALE_PRICE_MONTHLY=${NEXT_PUBLIC_SCALE_PRICE_MONTHLY}
ENV NEXT_PUBLIC_FREE_PLAN_TASK_LIMIT=${NEXT_PUBLIC_FREE_PLAN_TASK_LIMIT}
ENV NEXT_PUBLIC_PRO_PLAN_TASK_LIMIT=${NEXT_PUBLIC_PRO_PLAN_TASK_LIMIT}
ENV NEXT_PUBLIC_SCALE_PLAN_TASK_LIMIT=${NEXT_PUBLIC_SCALE_PLAN_TASK_LIMIT}
ENV NEXT_PUBLIC_DATAFAST_WEBSITE_ID=${NEXT_PUBLIC_DATAFAST_WEBSITE_ID}
ENV NEXT_PUBLIC_DATAFAST_DOMAIN=${NEXT_PUBLIC_DATAFAST_DOMAIN}
ENV NEXT_PUBLIC_DATAFAST_ALLOW_LOCALHOST=${NEXT_PUBLIC_DATAFAST_ALLOW_LOCALHOST}

RUN pnpm run build


# ── Stage 3: final runtime image ─────────────────────────────────────────────
FROM python:3.11-slim AS app

# Install system packages needed by both backend and Node
RUN apt-get update && apt-get install -y \
    ffmpeg \
    curl \
    unzip \
    fonts-noto-color-emoji \
    fontconfig \
    openssl \
    # Node.js 22 via NodeSource
    ca-certificates \
    gnupg \
    && fc-cache -f \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install deno (required by yt-dlp for YouTube JS challenge solving)
RUN curl -fsSL https://deno.land/install.sh | sh
ENV DENO_DIR=/root/.deno
ENV PATH="/root/.deno/bin:${PATH}"

# Install uv (Python package manager)
RUN pip install uv

# ── Backend setup ─────────────────────────────────────────────────────────────
WORKDIR /app/backend

COPY backend/pyproject.toml backend/uv.lock* ./
RUN uv venv .venv && uv sync
RUN uv pip install --upgrade --force-reinstall yt-dlp
RUN uv pip install --upgrade --force-reinstall "yt-dlp[default]"

COPY backend/src/ ./src/
COPY backend/fonts/ ./fonts/
COPY backend/bin/ ./bin/

# Create transitions dir (populated at runtime if needed)
RUN mkdir -p ./transitions

RUN mkdir -p /app/uploads /app/clips /app/logs /tmp
ENV PYTHONPATH=/app/backend
ENV PYTHONUNBUFFERED=1
ENV TEMP_DIR=/app/uploads

# ── Frontend setup ────────────────────────────────────────────────────────────
WORKDIR /app/frontend

# Copy the built Next.js standalone output
COPY --from=frontend-build /frontend/.next/standalone ./
COPY --from=frontend-build /frontend/.next/static ./.next/static
COPY --from=frontend-build /frontend/public ./public

# Copy Prisma client and engine
COPY --from=frontend-build /frontend/src/generated/prisma ./src/generated/prisma
COPY --from=frontend-build /frontend/prisma ./prisma
COPY --from=frontend-build \
    /frontend/src/generated/prisma/libquery_engine-debian-openssl-3.0.x.so.node \
    /app/prisma-engine/libquery_engine-debian-openssl-3.0.x.so.node

ENV PRISMA_QUERY_ENGINE_LIBRARY=/app/prisma-engine/libquery_engine-debian-openssl-3.0.x.so.node
ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_ENV=production
ENV PORT=3107
ENV HOSTNAME=0.0.0.0

# ── Start script (written inline to guarantee LF line endings) ───────────────
RUN printf '#!/bin/sh\n\
set -e\n\
export PORT=${PORT:-10000}\n\
echo "==> Starting Samoo (port=$PORT)"\n\
if [ -n "$REDIS_URL" ] && [ -z "$REDIS_HOST" ]; then\n\
    REDIS_HOST=$(echo "$REDIS_URL" | sed "s|redis://[^@]*@||; s|redis://||; s|:.*||")\n\
    REDIS_PORT=$(echo "$REDIS_URL" | sed "s|.*:||; s|/.*||")\n\
    REDIS_PASSWORD=$(echo "$REDIS_URL" | sed "s|redis://:||; s|@.*||")\n\
    export REDIS_HOST REDIS_PORT REDIS_PASSWORD\n\
    echo "==> Redis derived: $REDIS_HOST:$REDIS_PORT"\n\
fi\n\
export BACKEND_INTERNAL_URL="http://localhost:8000"\n\
if [ -n "$FRONTEND_DATABASE_URL" ]; then\n\
    export DATABASE_URL_PRISMA="$FRONTEND_DATABASE_URL"\n\
else\n\
    export DATABASE_URL_PRISMA=$(echo "$DATABASE_URL" | sed "s|postgresql+asyncpg://|postgresql://|")\n\
fi\n\
echo "==> Starting FastAPI backend..."\n\
cd /app/backend\n\
.venv/bin/uvicorn src.main_refactored:app --host 0.0.0.0 --port 8000 &\n\
BACKEND_PID=$!\n\
echo "==> Starting arq worker (retries on Redis failure)..."\n\
(while true; do cd /app/backend; .venv/bin/arq src.workers.tasks.WorkerSettings || true; echo "==> Worker retrying in 10s..."; sleep 10; done) &\n\
WORKER_PID=$!\n\
echo "==> Waiting for backend..."\n\
for i in $(seq 1 30); do\n\
    if curl -sf http://localhost:8000/health > /dev/null 2>&1; then echo "==> Backend ready"; break; fi\n\
    sleep 2\n\
done\n\
echo "==> Starting Next.js on port $PORT..."\n\
cd /app/frontend\n\
DATABASE_URL="$DATABASE_URL_PRISMA" BETTER_AUTH_SECRET="$BETTER_AUTH_SECRET" BETTER_AUTH_URL="$BETTER_AUTH_URL" BACKEND_AUTH_SECRET="$BACKEND_AUTH_SECRET" APP_SETTINGS_ENCRYPTION_KEY="$APP_SETTINGS_ENCRYPTION_KEY" BACKEND_INTERNAL_URL="http://localhost:8000" NEXT_PUBLIC_APP_URL="$NEXT_PUBLIC_APP_URL" SELF_HOST="$SELF_HOST" NODE_ENV=production PORT="$PORT" node server.js &\n\
FRONTEND_PID=$!\n\
echo "==> All up: Backend=$BACKEND_PID Worker=$WORKER_PID Frontend=$FRONTEND_PID"\n\
wait -n 2>/dev/null || wait $FRONTEND_PID\n\
echo "==> A process exited — shutting down"\n\
kill $BACKEND_PID $WORKER_PID $FRONTEND_PID 2>/dev/null || true\n\
wait\n\
exit 1\n\
' > /start-all.sh && chmod +x /start-all.sh

WORKDIR /app

EXPOSE 10000

CMD ["/start-all.sh"]
