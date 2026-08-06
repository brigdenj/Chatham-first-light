# Chatham First Light

The repository contains the static campaign page and a small Go API backed by
SQLite.

## Run the complete app locally

Go 1.23 or newer, Python 3, and curl are required. Start the API and static
site together with:

```sh
./dev.sh
```

Then open <http://127.0.0.1:8000>. The launcher serves the site on port 8000,
runs the API on port 8080, and stores test signatures separately in
`data/dev-signatures.db`. Press Ctrl-C to stop both servers. To use another
development database, set `DB_PATH`:

```sh
DB_PATH=/tmp/chatham-signatures.db ./dev.sh
```

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

## Docker Compose deployment over SSH

`deploy.sh` detects the remote CPU architecture, builds and transfers the API
image, copies the Compose configuration, and runs `docker compose up` remotely.
Compose starts the API and nginx, with an opt-in Certbot service for certificate
issuance. SQLite and Let's Encrypt state are kept in named Docker volumes.

The default target is the Chatham First Light EC2 instance:

```sh
./deploy.sh
```

Configuration can be overridden with environment variables:

```sh
SSH_TARGET=user@example.com SSH_KEY=/path/to/key ./deploy.sh
```

The deployment verifies `/healthz` through nginx. Docker and the Docker Compose
plugin are required remotely. Ports 80 and 443 must be open in the instance
firewall/security group. Override them locally with `HTTP_PORT` and `HTTPS_PORT`
if needed.

### Enable HTTPS after DNS is ready

The apex and `www` site remain hosted by GitHub Pages. Create an `A` record for
`api.chathamfirstlight.com` pointing to the API server. Issue the API certificate
with an interactive DNS-01 challenge:

```sh
ISSUE_CERTIFICATE=true CERTBOT_EMAIL=admin@example.com ./deploy.sh
```

Certbot prints a TXT value for `_acme-challenge.api.chathamfirstlight.com` and
waits while you add it to DNS. Confirm only after the TXT record has propagated.
nginx initially serves HTTP, switches to HTTPS after issuance, and redirects
subsequent HTTP traffic.

Because manual DNS validation has no provider API credentials, it cannot renew
unattended. Before the certificate expires, rerun the same command and replace
the TXT value when prompted. Certificate issuance is deliberately opt-in so
ordinary deployments do not pause waiting for DNS changes.
