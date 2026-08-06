#!/usr/bin/env bash
set -Eeuo pipefail

SSH_TARGET=${SSH_TARGET:-ec2-user@ec2-98-92-193-180.compute-1.amazonaws.com}
SSH_KEY=${SSH_KEY:-"${HOME}/.keys/aws/m1.pem"}
IMAGE_NAME=${IMAGE_NAME:-chatham-first-light-api}
COMPOSE_PROJECT=${COMPOSE_PROJECT:-chatham-first-light}
REMOTE_DIR=${REMOTE_DIR:-/home/ec2-user/chatham-first-light}
DOMAIN=${DOMAIN:-api.chathamfirstlight.com}
HTTP_PORT=${HTTP_PORT:-80}
HTTPS_PORT=${HTTPS_PORT:-443}
ISSUE_CERTIFICATE=${ISSUE_CERTIFICATE:-false}
CERTBOT_EMAIL=${CERTBOT_EMAIL:-}

if [[ ! -r "$SSH_KEY" ]]; then
  echo "SSH key is not readable: $SSH_KEY" >&2
  exit 1
fi
for command_name in docker ssh scp gzip tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is missing: $command_name" >&2
    exit 1
  fi
done
for port_name in HTTP_PORT HTTPS_PORT; do
  port=${!port_name}
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    echo "$port_name must be an integer from 1 through 65535" >&2
    exit 1
  fi
done
if [[ "$ISSUE_CERTIFICATE" == true && -z "$CERTBOT_EMAIL" ]]; then
  echo "CERTBOT_EMAIL is required when ISSUE_CERTIFICATE=true" >&2
  exit 1
fi
if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "DOMAIN contains invalid characters" >&2
  exit 1
fi
if [[ -n "$CERTBOT_EMAIL" && ! "$CERTBOT_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]; then
  echo "CERTBOT_EMAIL is invalid" >&2
  exit 1
fi

ssh_options=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
remote_arch=$(ssh "${ssh_options[@]}" "$SSH_TARGET" 'uname -m')
case "$remote_arch" in
  aarch64|arm64) platform=linux/arm64 ;;
  x86_64|amd64) platform=linux/amd64 ;;
  armv7l|armv7) platform=linux/arm/v7 ;;
  *) echo "Unsupported remote architecture: $remote_arch" >&2; exit 1 ;;
esac

if ! ssh "${ssh_options[@]}" "$SSH_TARGET" 'docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1'; then
  echo "Docker and the Compose plugin must be installed and accessible remotely." >&2
  exit 1
fi

deploy_tag="${IMAGE_NAME}:$(date -u +%Y%m%d%H%M%S)"
archive=$(mktemp "${TMPDIR:-/tmp}/chatham-first-light.XXXXXX.tar.gz")
remote_archive="/tmp/chatham-first-light-image-${RANDOM}.tar.gz"
cleanup() {
  rm -f "$archive"
  ssh "${ssh_options[@]}" "$SSH_TARGET" "rm -f '$remote_archive'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Building $deploy_tag for $platform..."
docker build --platform "$platform" --tag "$deploy_tag" .
docker save "$deploy_tag" | gzip -1 >"$archive"

echo "Copying the image and Compose configuration to $SSH_TARGET..."
ssh "${ssh_options[@]}" "$SSH_TARGET" "mkdir -p '$REMOTE_DIR/nginx/templates'"
scp "${ssh_options[@]}" "$archive" "${SSH_TARGET}:${remote_archive}"
scp "${ssh_options[@]}" compose.yaml index.html "${SSH_TARGET}:${REMOTE_DIR}/"
scp "${ssh_options[@]}" nginx/40-enable-tls.sh "${SSH_TARGET}:${REMOTE_DIR}/nginx/"
scp "${ssh_options[@]}" nginx/templates/*.template "${SSH_TARGET}:${REMOTE_DIR}/nginx/templates/"

echo "Starting the Compose application..."
ssh "${ssh_options[@]}" "$SSH_TARGET" bash -s -- \
  "$remote_archive" "$REMOTE_DIR" "$COMPOSE_PROJECT" "$deploy_tag" "$DOMAIN" \
  "$HTTP_PORT" "$HTTPS_PORT" "$ISSUE_CERTIFICATE" "$CERTBOT_EMAIL" <<'REMOTE_SCRIPT'
set -Eeuo pipefail
archive=$1 remote_dir=$2 project=$3 image=$4 domain=$5
http_port=$6 https_port=$7 issue_certificate=$8 certbot_email=${9-}

docker load --input "$archive"
rm -f "$archive"
cd "$remote_dir"

compose=(docker compose --project-name "$project")
export API_IMAGE=$image DOMAIN=$domain HTTP_PORT=$http_port HTTPS_PORT=$https_port
docker volume create chatham-first-light-data >/dev/null

# Remove the pre-Compose API container during the one-time migration. Its named
# data volume is retained and mounted by the Compose API service below.
if docker container inspect chatham-first-light-api >/dev/null 2>&1; then
  if [[ "$(docker container inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' chatham-first-light-api 2>/dev/null)" != "$project" ]]; then
    docker rm --force chatham-first-light-api
  fi
fi

"${compose[@]}" up --detach --remove-orphans
"${compose[@]}" restart nginx

healthy=false
for _ in $(seq 1 30); do
  if curl --fail --silent --max-time 2 "http://127.0.0.1:${http_port}/healthz" >/dev/null; then
    healthy=true
    break
  fi
  sleep 1
done
if [[ "$healthy" != true ]]; then
  "${compose[@]}" ps >&2
  "${compose[@]}" logs --tail=100 api nginx >&2 || true
  echo "Compose application failed its health check." >&2
  exit 1
fi

"${compose[@]}" ps
REMOTE_SCRIPT

if [[ "$ISSUE_CERTIFICATE" == true ]]; then
  echo "Starting interactive DNS validation for $DOMAIN..."
  ssh -t "${ssh_options[@]}" "$SSH_TARGET" \
    "cd '$REMOTE_DIR' && docker compose --project-name '$COMPOSE_PROJECT' --profile certbot run --rm certbot certonly --manual --preferred-challenges dns --domain '$DOMAIN' --email '$CERTBOT_EMAIL' --agree-tos --no-eff-email && docker compose --project-name '$COMPOSE_PROJECT' restart nginx"
fi

echo "Deployment healthy at http://${DOMAIN}."
if [[ "$ISSUE_CERTIFICATE" != true ]]; then
  echo "Certificate issuance skipped. Rerun with ISSUE_CERTIFICATE=true CERTBOT_EMAIL=you@example.com for interactive DNS validation."
fi
