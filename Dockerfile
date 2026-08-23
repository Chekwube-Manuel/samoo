# =============================================================================
# SupoClip — Single-container build (Frontend + Backend + Worker)
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

# Copy transitions if present (optional)
COPY backend/transitions/ ./transitions/ 2>/dev/null || true

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

# ── Start script ──────────────────────────────────────────────────────────────
COPY start-all.sh /start-all.sh
RUN chmod +x /start-all.sh

WORKDIR /app

# Render assigns PORT env var — we expose 10000 (Render default) on the outside,
# Next.js listens on 3107 internally, backend on 8000 internally.
# nginx is overkill for one service — we expose Next.js directly on 10000.
EXPOSE 10000

CMD ["/start-all.sh"]
