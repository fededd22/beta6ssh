# syntax=docker/dockerfile:1

# Cloud Run requires the container to listen on a single HTTP port (the
# PORT env var, injected automatically -- usually 8080). This app already
# does that correctly (server.ts reads process.env.PORT and binds
# 0.0.0.0), and all V2Ray/VLESS/VMess/Trojan/SSH traffic is tunneled over
# WebSocket through that same port, so no extra exposed ports are needed.

# Node.js version: 22 by default; the code is built for Node >= 18 (esbuild target).
# Change it with: docker build --build-arg NODE_VERSION=20 .
ARG NODE_VERSION=22
FROM node:${NODE_VERSION}-slim AS base
WORKDIR /app

# ---- install ALL deps (incl. devDependencies, needed to run esbuild) ----
FROM base AS deps
# build-essential/python3 are a safety net in case any native addon
# (e.g. ssh2's optional cpu-features) has no prebuilt binary for this
# platform and falls back to compiling from source.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
COPY package.json ./
RUN npm install

# ---- bundle server.ts -> dist/server.cjs ----
FROM deps AS build
COPY server.ts tsconfig.json ./
RUN npm run build

# ---- production-only node_modules (no devDependencies) ----
FROM base AS prod-deps
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
COPY package.json ./
RUN npm install --omit=dev

# ---- final runtime image ----
FROM base AS runtime
ENV NODE_ENV=production
# `upgrade` reduces the vulnerabilities reported by Choreo's Trivy image scan.
RUN apt-get update && apt-get -y upgrade && rm -rf /var/lib/apt/lists/*
COPY --from=prod-deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
# Choreo endpoint config: the entrypoint / server read the port declared here
# when the platform does not inject PORT (Choreo does not).
COPY .choreo ./.choreo
COPY docker-entrypoint.sh ./

# Choreo requires a NUMERIC non-root user with UID between 10000 and 20000.
# /app stays world-writable so other platforms that force an arbitrary UID also work.
RUN useradd --uid 10014 --user-group --no-create-home --home-dir /app/data --shell /usr/sbin/nologin choreo \
    && chmod +x docker-entrypoint.sh \
    && mkdir -p /app/data \
    && chown -R 10014:10014 /app \
    && chmod -R a+rwX /app
ENV DATA_DIR=/app/data HOME=/app/data
USER 10014

# Documentation only. Real port = PORT env, else .choreo/component.yaml, else 3000.
# The app also listens on 8080/8000/5000/9090 (EXTRA_PORTS) as a safety net.
EXPOSE 3000 8080

ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["node", "dist/server.cjs"]
