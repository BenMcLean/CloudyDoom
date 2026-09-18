#!/bin/sh
set -eu

: "${DOOM_WS_URL:?DOOM_WS_URL must be set, e.g. wss://doom.example.com/ws}"

# PASSWORD is intentionally optional and not read anywhere in this script -
# nginx/auth.js reads it straight from the environment at request time (via
# nginx.conf's "env PASSWORD;"). Left unset/blank, any password is accepted,
# which is a valid choice for a public server with nothing to gate (e.g. a
# Freedoom IWAD instead of a commercial one).

# DOOM_IWAD_PATH is the filename inside the /wads volume mount (e.g. a real
# DOOM2.WAD dropped in by whoever runs the compose file) - see the "wads"
# volume + this var in docker-compose.yml. Defaults to the shareware WAD
# name so the stack still boots for anyone who hasn't supplied one yet.
DOOM_IWAD_PATH="${DOOM_IWAD_PATH:-doom1.wad}"
export DOOM_IWAD_URL="wads/${DOOM_IWAD_PATH}"

# DOOM_PWAD_PATH and DOOM_DEH_PATH are filenames inside the same /wads volume
# mount as DOOM_IWAD_PATH above - a PWAD (map/mod add-on, loaded with -file)
# and a DeHackEd (.deh) patch respectively. Both unset by default, meaning
# neither is loaded - config.base.json.template ends up with empty
# pwadUrl/dehUrl, which app.js treats as "don't load one".
export DOOM_PWAD_URL="${DOOM_PWAD_PATH:+wads/${DOOM_PWAD_PATH}}"
export DOOM_DEH_URL="${DOOM_DEH_PATH:+wads/${DOOM_DEH_PATH}}"

# config.base.json holds everything in config.json except "playerName",
# which nginx/auth.js fills in per-request from the client's own Basic Auth
# username - see nginx.conf's "location = /config.json".
envsubst '${DOOM_WS_URL} ${DOOM_IWAD_URL} ${DOOM_PWAD_URL} ${DOOM_DEH_URL}' < /etc/doom/config.base.json.template > /etc/doom/config.base.json

exec nginx -g 'daemon off;'
