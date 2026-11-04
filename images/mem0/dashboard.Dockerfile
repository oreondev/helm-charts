# Mem0 dashboard (Next.js), built from a pinned upstream release.
#   docker build -f dashboard.Dockerfile --build-arg UPSTREAM_VERSION=2.2.1 -t mem0-dashboard .
# Upstream bakes NEXT_PUBLIC_* placeholders into .next and rewrites them in place with sed on every
# start, which needs a writable image. Here the built .next is kept read-only in /app/.next.dist and the
# entrypoint writes the substituted copy into /app/.next (an emptyDir in the chart), so the root
# filesystem can stay read-only.
ARG NODE_IMAGE=node:20-alpine

FROM ${NODE_IMAGE} AS source
ARG UPSTREAM_VERSION=2.2.1
ADD https://github.com/mem0ai/mem0/archive/refs/tags/v${UPSTREAM_VERSION}.tar.gz /tmp/mem0.tar.gz
RUN mkdir /src && tar -xzf /tmp/mem0.tar.gz -C /src --strip-components=1

FROM ${NODE_IMAGE} AS builder
RUN apk add --no-cache libc6-compat
WORKDIR /app
COPY --from=source /src/server/dashboard/ ./
RUN if [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm i --frozen-lockfile; \
    elif [ -f yarn.lock ]; then yarn --frozen-lockfile --network-timeout 600000; \
    else npm ci; fi
ENV NEXT_TELEMETRY_DISABLED=1 \
    NEXT_PUBLIC_API_URL=NEXT_PUBLIC_API_URL \
    NEXT_PUBLIC_INSTANCE_NAME=NEXT_PUBLIC_INSTANCE_NAME
RUN npm run build

FROM ${NODE_IMAGE}
ARG UPSTREAM_VERSION=2.2.1
LABEL org.opencontainers.image.title="mem0-dashboard" \
      org.opencontainers.image.version="${UPSTREAM_VERSION}" \
      org.opencontainers.image.source="https://github.com/oreondev/helm-charts" \
      org.opencontainers.image.description="Mem0 dashboard (upstream release, rebuilt for a read-only root filesystem)" \
      org.opencontainers.image.licenses="Apache-2.0"
WORKDIR /app
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=3000 HOSTNAME=0.0.0.0
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
RUN mv .next .next.dist && mkdir .next && chown 10001:0 .next
COPY dashboard-entrypoint.sh /usr/local/bin/dashboard-entrypoint.sh
USER 10001
EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/dashboard-entrypoint.sh"]
CMD ["node", "server.js"]
