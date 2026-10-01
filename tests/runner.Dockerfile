# Scenario runner for tests/run-local.sh: the client tools CI installs, on Debian.
ARG PG_MAJOR=18
FROM golang:1.25-alpine AS s3sync
WORKDIR /src
COPY s3-sync/go.mod s3-sync/go.sum ./
RUN go mod download
COPY s3-sync/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/s3-sync .

FROM postgres:${PG_MAJOR}
ARG TARGETARCH
ARG PROMETHEUS_VERSION=3.5.0
ARG GOCRONVER=v0.0.11
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg faketime jq util-linux tini \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-${TARGETARCH}.tar.gz" \
       | tar -xz -C /usr/local/bin --strip-components=1 "prometheus-${PROMETHEUS_VERSION}.linux-${TARGETARCH}/promtool" \
    && curl -fsSL "https://github.com/prodrigestivill/go-cron/releases/download/${GOCRONVER}/go-cron-linux-${TARGETARCH}.gz" \
       | gunzip > /usr/local/bin/go-cron \
    && chmod a+x /usr/local/bin/go-cron
COPY --from=s3sync /out/s3-sync /usr/local/bin/s3-sync
WORKDIR /work
ENTRYPOINT []
CMD ["sleep", "infinity"]
