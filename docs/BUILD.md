# Build Instructions

Dockerfiles are located in the [`docker/`](https://github.com/ganiyevuz/docker-postgres-backup-tool/tree/main/docker) directory (`alpine.Dockerfile` and `debian.Dockerfile`).

## Prerequisites

- Docker with [Buildx](https://docs.docker.com/buildx/working-with-buildx/) enabled.
- QEMU registered for cross-platform builds.

### Set up cross-compilation

```sh
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
docker buildx rm multibuilder 2>/dev/null || true
docker buildx create --name multibuilder \
  --platform linux/amd64,linux/arm64 \
  --driver docker-container --use
docker buildx inspect --bootstrap
```

## Build locally

```sh
docker buildx bake --pull
```

Override image name or registry prefix:

```sh
REGISTRY_PREFIX="yourusername/" IMAGE_NAME="postgres-backup-telegram" docker buildx bake --pull
```

## Build and push

```sh
REGISTRY_PREFIX="yourusername/" docker buildx bake --pull --push
```

Optionally tag with the current git revision:

```sh
REGISTRY_PREFIX="yourusername/" BUILD_REVISION=$(git rev-parse --short HEAD) docker buildx bake --pull --push
```
