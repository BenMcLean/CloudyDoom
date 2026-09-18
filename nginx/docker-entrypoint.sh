#!/bin/sh
set -eu

: "${DOOM_WS_URL:?DOOM_WS_URL must be set, e.g. wss://doom.example.com/ws}"
: "${DOOM_AUTH_USER:?DOOM_AUTH_USER must be set}"
: "${DOOM_AUTH_PASS:?DOOM_AUTH_PASS must be set}"

envsubst '${DOOM_WS_URL}' < /etc/doom/config.json.template > /usr/share/nginx/html/config.json

htpasswd -cbB /etc/nginx/.htpasswd "$DOOM_AUTH_USER" "$DOOM_AUTH_PASS"

exec nginx -g 'daemon off;'
