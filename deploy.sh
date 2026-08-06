#!/usr/bin/env bash
set -Eeuo pipefail

SSH_TARGET=${SSH_TARGET:-ec2-user@ec2-98-92-193-180.compute-1.amazonaws.com}
SSH_KEY=${SSH_KEY:-"${HOME}/.keys/aws/m1.pem"}
IMAGE_NAME=${IMAGE_NAME:-chatham-first-light-api}
CONTAINER_NAME=${CONTAINER_NAME:-chatham-first-light-api}
VOLUME_NAME=${VOLUME_NAME:-chatham-first-light-data}
PORT=${PORT:-8080}

if [[ ! -r "$SSH_KEY" ]]; then
  echo "SSH key is not readable: $SSH_KEY" >&2
  exit 1
fi
for command_name in docker ssh scp gzip; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is missing: $command_name" >&2
    exit 1
  fi
done
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "PORT must be an integer from 1 through 65535" >&2
  exit 1
fi

ssh_options=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
remote_arch=$(ssh "${ssh_options[@]}" "$SSH_TARGET" 'uname -m')
case "$remote_arch" in
  aarch64|arm64) platform=linux/arm64 ;;
  x86_64|amd64) platform=linux/amd64 ;;
  armv7l|armv7) platform=linux/arm/v7 ;;
  *)
    echo "Unsupported remote architecture: $remote_arch" >&2
    exit 1
    ;;
esac

if ! ssh "${ssh_options[@]}" "$SSH_TARGET" 'docker info >/dev/null 2>&1'; then
  echo "Docker is not installed, running, or accessible to the remote user." >&2
  exit 1
fi

deploy_tag="${IMAGE_NAME}:$(date -u +%Y%m%d%H%M%S)"
archive=$(mktemp "${TMPDIR:-/tmp}/chatham-first-light.XXXXXX.tar.gz")
remote_archive="/tmp/${CONTAINER_NAME}-image-${RANDOM}.tar.gz"
cleanup() {
  rm -f "$archive"
  ssh "${ssh_options[@]}" "$SSH_TARGET" "rm -f '$remote_archive'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Building $deploy_tag for $platform..."
docker build --platform "$platform" --tag "$deploy_tag" .

echo "Saving and copying image to $SSH_TARGET..."
docker save "$deploy_tag" | gzip -1 >"$archive"
scp "${ssh_options[@]}" "$archive" "${SSH_TARGET}:${remote_archive}"

echo "Loading and starting container..."
ssh "${ssh_options[@]}" "$SSH_TARGET" bash -s -- \
  "$remote_archive" "$deploy_tag" "$CONTAINER_NAME" "$VOLUME_NAME" "$PORT" <<'REMOTE_SCRIPT'
set -Eeuo pipefail
archive=$1
image=$2
container=$3
volume=$4
port=$5

docker load --input "$archive"
rm -f "$archive"

old_image_id=''
if docker container inspect "$container" >/dev/null 2>&1; then
  old_image_id=$(docker container inspect --format '{{.Image}}' "$container")
  docker rm --force "$container"
fi

start_container() {
  local selected_image=$1
  docker run --detach \
    --name "$container" \
    --restart unless-stopped \
    --publish "${port}:8080" \
    --mount "type=volume,src=${volume},dst=/data" \
    "$selected_image"
}

start_container "$image"

healthy=false
for _ in $(seq 1 20); do
  if curl --fail --silent --max-time 2 "http://127.0.0.1:${port}/healthz" >/dev/null; then
    healthy=true
    break
  fi
  sleep 1
done

if [[ "$healthy" != true ]]; then
  echo "New container failed its health check." >&2
  docker logs "$container" >&2 || true
  docker rm --force "$container" >/dev/null 2>&1 || true
  if [[ -n "$old_image_id" ]]; then
    echo "Restoring the previous image..." >&2
    start_container "$old_image_id" >/dev/null
  fi
  exit 1
fi

docker container ls --filter "name=^/${container}$" --format 'Deployed {{.Image}} as {{.Names}} ({{.Status}})'
REMOTE_SCRIPT

echo "Deployment healthy; container port 8080 is mapped to host port $PORT."
