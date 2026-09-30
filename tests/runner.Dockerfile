# Scenario runner for tests/run-local.sh: the client tools CI installs, on Debian.
ARG PG_MAJOR=18
FROM postgres:${PG_MAJOR}
ARG TARGETARCH
ARG PROMETHEUS_VERSION=3.5.0
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg faketime jq util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-${TARGETARCH}.tar.gz" \
       | tar -xz -C /usr/local/bin --strip-components=1 "prometheus-${PROMETHEUS_VERSION}.linux-${TARGETARCH}/promtool"
WORKDIR /work
ENTRYPOINT []
CMD ["sleep", "infinity"]
