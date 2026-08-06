#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")" && pwd)
api_binary=$(mktemp "${TMPDIR:-/tmp}/chatham-first-light-api.XXXXXX")
api_pid=""

cleanup() {
  if [[ -n "$api_pid" ]] && kill -0 "$api_pid" 2>/dev/null; then
    kill "$api_pid" 2>/dev/null || true
    wait "$api_pid" 2>/dev/null || true
  fi
  rm -f "$api_binary"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

for command_name in go python3 curl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
done

echo "Building local API..."
go build -o "$api_binary" ./cmd/server

dev_db_path=${DB_PATH:-"$project_dir/data/dev-signatures.db"}
ADDR=:8080 DB_PATH="$dev_db_path" "$api_binary" &
api_pid=$!

for _ in {1..50}; do
  if curl --fail --silent http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$api_pid" 2>/dev/null; then
    echo "The local API stopped before becoming ready." >&2
    exit 1
  fi
  sleep 0.1
done

if ! curl --fail --silent http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
  echo "The local API did not become ready at http://127.0.0.1:8080." >&2
  exit 1
fi

echo ""
echo "Local app: http://127.0.0.1:8000"
echo "Local API: http://127.0.0.1:8080"
echo "Database:  $dev_db_path"
echo "Press Ctrl-C to stop."
echo ""

python3 -m http.server 8000 --bind 127.0.0.1 --directory "$project_dir"
