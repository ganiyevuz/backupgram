ARG BASETAG=latest

# --- Build the MTProto large-file uploader (static, native cross-compile) ---
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS tgbuilder
WORKDIR /src
COPY tg-upload/go.mod tg-upload/go.sum ./
RUN go mod download
COPY tg-upload/ ./
ARG TARGETOS TARGETARCH TARGETVARIANT
RUN GOARM="$(echo "${TARGETVARIANT}" | sed 's/^v//')" \
    GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" CGO_ENABLED=0 \
    go build -trimpath -ldflags="-s -w" -o /out/tg-upload .

# --- Build the REST API control server (static, native cross-compile) ---
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS apibuilder
WORKDIR /src
COPY rest-api/ ./
ARG TARGETOS TARGETARCH TARGETVARIANT
RUN GOARM="$(echo "${TARGETVARIANT}" | sed 's/^v//')" \
    GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" CGO_ENABLED=0 \
    go build -trimpath -ldflags="-s -w" -o /out/pgbackup-api .

FROM postgres:$BASETAG

ARG GOCRONVER=v0.0.11
ARG TARGETOS
ARG TARGETARCH

# Fix Debian cross-build
ARG DEBIAN_FRONTEND=noninteractive
RUN set -x \
    && ln -sf /usr/bin/dpkg-split /usr/sbin/dpkg-split \
    && ln -sf /usr/bin/dpkg-deb /usr/sbin/dpkg-deb \
    && ln -sf /bin/tar /usr/sbin/tar \
    && ln -sf /bin/rm /usr/sbin/rm \
    && ln -sf /usr/bin/dpkg-split /usr/local/sbin/dpkg-split \
    && ln -sf /usr/bin/dpkg-deb /usr/local/sbin/dpkg-deb \
    && ln -sf /bin/tar /usr/local/sbin/tar \
    && ln -sf /bin/rm /usr/local/sbin/rm

# Install required dependencies and download go-cron
RUN set -x \
    && apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && curl --fail --retry 4 --retry-all-errors -L "https://github.com/prodrigestivill/go-cron/releases/download/${GOCRONVER}/go-cron-${TARGETOS}-${TARGETARCH}.gz" -o /usr/local/bin/go-cron.gz \
    && gunzip /usr/local/bin/go-cron.gz && chmod a+x /usr/local/bin/go-cron

# Environment Variables
ENV POSTGRES_DB="" \
    POSTGRES_DB_FILE="" \
    POSTGRES_HOST="" \
    POSTGRES_PORT=5432 \
    POSTGRES_USER="" \
    POSTGRES_USER_FILE="" \
    POSTGRES_PASSWORD="" \
    POSTGRES_PASSWORD_FILE="" \
    POSTGRES_PASSFILE_STORE="" \
    POSTGRES_EXTRA_OPTS="-Z1" \
    POSTGRES_CLUSTER="FALSE" \
    POSTGRES_DB_AUTODISCOVER="FALSE" \
    POSTGRES_DB_EXCLUDE="" \
    REST_API_ENABLE="FALSE" \
    REST_API_PORT=8081 \
    REST_API_TOKEN="" \
    REST_API_TOKEN_FILE="" \
    SCHEDULE="@daily" \
    VALIDATE_ON_START="TRUE" \
    BACKUP_ON_START="FALSE" \
    BACKUP_DIR="/backups" \
    BACKUP_SUFFIX=".sql.gz" \
    BACKUP_LATEST_TYPE="symlink" \
    BACKUP_KEEP_DAYS=7 \
    BACKUP_KEEP_WEEKS=4 \
    BACKUP_KEEP_MONTHS=6 \
    BACKUP_KEEP_MINS=1440 \
    HEALTHCHECK_PORT=8080 \
    WEBHOOK_URL="" \
    WEBHOOK_ERROR_URL="" \
    WEBHOOK_PRE_BACKUP_URL="" \
    WEBHOOK_POST_BACKUP_URL="" \
    WEBHOOK_EXTRA_ARGS="" \
    TELEGRAM_BOT_TOKEN_FILE="" \
    TELEGRAM_CHAT_ID_FILE="" \
    TELEGRAM_API_ID="" \
    TELEGRAM_API_HASH="" \
    TELEGRAM_API_ID_FILE="" \
    TELEGRAM_API_HASH_FILE="" \
    TELEGRAM_BOT_TOKEN="" \
    TELEGRAM_CHAT_ID="" \
    TELEGRAM_THREAD_ID="" \
    TELEGRAM_API_URL="https://api.telegram.org" \
    TELEGRAM_UPLOAD_METHOD="smart" \
    PROJECT_NAME="" \
    BACKUP_ENCRYPTION_KEY="" \
    BACKUP_MIN_DISK_SPACE=100 \
    TELEGRAM_NOTIFY_ON="all" \
    POSTGRES_EXCLUDE_TABLES="" \
    POSTGRES_CONNECT_TIMEOUT=30 \
    BACKUP_MAX_AGE_HOURS=48

# Vendored MTProto uploader for files >50MB (built in the tgbuilder stage)
COPY --from=tgbuilder /out/tg-upload /usr/local/bin/tg-upload
# REST API control server (built in the apibuilder stage)
COPY --from=apibuilder /out/pgbackup-api /usr/local/bin/pgbackup-api

# Copy scripts and hooks
COPY hooks/ /hooks/
COPY scripts/ /scripts/
RUN ln -s /scripts/backup.sh /backup.sh \
    && ln -s /scripts/restore.sh /restore.sh \
    && ln -s /scripts/list.sh /list.sh \
    && ln -s /scripts/env.sh /env.sh \
    && ln -s /scripts/init.sh /init.sh

# Register CLI commands
RUN ln -s /scripts/backup.sh /usr/local/bin/backup \
    && ln -s /scripts/restore.sh /usr/local/bin/restore \
    && ln -s /scripts/list.sh /usr/local/bin/list \
    && ln -s /scripts/status.sh /usr/local/bin/status \
    && ln -s /scripts/help.sh /usr/local/bin/help

# Declare persistent volume for backups
VOLUME /backups

# Set up entrypoint
ENTRYPOINT ["/init.sh"]

EXPOSE 8081

# Healthcheck to monitor container
HEALTHCHECK --interval=5m --timeout=3s \
  CMD /scripts/healthcheck.sh || exit 1
