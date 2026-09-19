#!/bin/sh
set -eu
# Install as /etc/letsencrypt/renewal-hooks/deploy/notebook-relay.
# certbot supplies the renewed lineage; never print the private key.
[ "${RENEWED_LINEAGE:-}" = /etc/letsencrypt/live/catocut.com ] || exit 0
install -o root -g notebook-relay -m 640 "$RENEWED_LINEAGE/fullchain.pem" /etc/notebook-relay/fullchain.pem
install -o root -g notebook-relay -m 640 "$RENEWED_LINEAGE/privkey.pem" /etc/notebook-relay/privkey.pem
systemctl reload notebook-relay
