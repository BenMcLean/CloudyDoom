#!/bin/sh
set -eu

: "${DOOM_WS_URL:?DOOM_WS_URL must be set, e.g. wss://doom.example.com/ws}"
: "${DOOM_AUTH_USER:?DOOM_AUTH_USER must be set}"
: "${DOOM_AUTH_PASS:?DOOM_AUTH_PASS must be set}"

# DOOM_IWAD_PATH is the filename inside the /wads volume mount (e.g. a real
# DOOM2.WAD dropped in by whoever runs the compose file) - see the "wads"
# volume + this var in docker-compose.yml. Defaults to the shareware WAD
# name so the stack still boots for anyone who hasn't supplied one yet.
DOOM_IWAD_PATH="${DOOM_IWAD_PATH:-doom1.wad}"
export DOOM_IWAD_URL="wads/${DOOM_IWAD_PATH}"

# DOOM_PWAD_PATH and DOOM_DEH_PATH are filenames inside the same /wads volume
# mount as DOOM_IWAD_PATH above - a PWAD (map/mod add-on, loaded with -file)
# and a DeHackEd (.deh) patch respectively. Both unset by default, meaning
# neither is loaded - config.json.template ends up with empty pwadUrl/dehUrl,
# which app.js treats as "don't load one".
export DOOM_PWAD_URL="${DOOM_PWAD_PATH:+wads/${DOOM_PWAD_PATH}}"
export DOOM_DEH_URL="${DOOM_DEH_PATH:+wads/${DOOM_DEH_PATH}}"

envsubst '${DOOM_WS_URL} ${DOOM_IWAD_URL} ${DOOM_PWAD_URL} ${DOOM_DEH_URL}' < /etc/doom/config.json.template > /usr/share/nginx/html/config.json

htpasswd -cbB /etc/nginx/.htpasswd "$DOOM_AUTH_USER" "$DOOM_AUTH_PASS"

exec nginx -g 'daemon off;'
