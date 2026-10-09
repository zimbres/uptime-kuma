FROM node:24-bookworm-slim AS base
RUN apt update && apt install -y --no-install-recommends \
    sqlite3 ca-certificates iputils-ping util-linux dumb-init curl sudo nscd \
    && rm -rf /var/lib/apt/lists/*

FROM base AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --legacy-peer-deps
COPY . .
RUN npm run build
RUN npm prune --omit=dev --legacy-peer-deps

FROM base AS release
WORKDIR /app
ENV UPTIME_KUMA_IS_CONTAINER=1
COPY --from=builder /app /app
EXPOSE 3001
HEALTHCHECK --interval=60s --timeout=30s --start-period=180s --retries=5 CMD node extra/healthcheck.js
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "server/server.js"]