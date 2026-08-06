# Chatham First Light

The repository contains the static campaign page and a small Go API backed by
SQLite.

## Run the API

Go 1.23 or newer is required.

```sh
go mod download
go run ./cmd/server
```

The server listens on `:8080` and creates `data/signatures.db`. Override these
with `ADDR` and `DB_PATH`.

### Create a signature

```sh
curl -X POST http://localhost:8080/api/signatures \
  -H 'Content-Type: application/json' \
  -d '{"name":"Jane Doe","category":"Individual","town":"Chatham, MA","email":"jane@example.com","reason":"Please restore the light."}'
```

Valid categories are `Individual-Chatham Resident`, `Individual`,
`Organization`, and `Business`. The response contains only the new row ID.

### List public signatures

```sh
curl http://localhost:8080/api/signatures
```

This response deliberately excludes email, phone, and full street address. For
Chatham residents it exposes only the street name; for other signers it exposes
the town.

## Build for ARM Linux

The SQLite driver is implemented in pure Go, so CGO and a cross C compiler are
not needed:

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o chatham-first-light-server ./cmd/server
```

For 32-bit ARM, use `GOARCH=arm GOARM=7`.

## Container deployment over SSH

`deploy.sh` detects the remote CPU architecture, builds a matching Docker image
locally, copies the compressed image over SSH, loads it into remote Docker, and
starts the API. SQLite is stored in the persistent Docker volume
`chatham-first-light-data`, which is retained when the container is replaced.

The default target is the Chatham First Light EC2 instance:

```sh
./deploy.sh
```

Configuration can be overridden with environment variables:

```sh
SSH_TARGET=user@example.com SSH_KEY=/path/to/key PORT=8080 ./deploy.sh
```

The deployment verifies `/healthz` and automatically restores the previous
container image if the new container does not become healthy.

The container publishes the configured port on the host. External access also
requires that port to be allowed by the instance's AWS security group, or a
reverse proxy can forward HTTPS traffic to it.
