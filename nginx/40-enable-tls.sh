#!/bin/sh
set -eu

render_config() {
    certificate="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    template=/etc/nginx/custom-templates/http.conf.template
    if [ -s "$certificate" ] && [ -s "$key" ]; then
        template=/etc/nginx/custom-templates/https.conf.template
    fi
    envsubst '${DOMAIN}' < "$template" > /etc/nginx/conf.d/default.conf
}

render_config

# Certbot and nginx share the certificate volume. Detect issuance/renewal,
# render the TLS configuration, and reload without stopping the proxy.
(
    previous=''
    while sleep 60; do
        certificate="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        current=$(stat -c '%Y:%s' "$certificate" 2>/dev/null || true)
        if [ "$current" != "$previous" ]; then
            previous=$current
            render_config
            nginx -t && nginx -s reload
        fi
    done
) &
