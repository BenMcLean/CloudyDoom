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

# JSON-escapes a string onto stdout (backslash and double-quote only - the
# inputs here are all plain ASCII command line flags/filenames, never
# arbitrary user text, so no other escaping is needed).
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# DOOM_EXTRA_ARGS is a whitespace-separated string of raw doom-wasm command
# line flags (e.g. "-skill 4 -deathmatch -warp 2 5"), for anything not
# already covered by a dedicated var above. Unlike IWAD/PWAD/DEH, these are
# passed straight through with no file resolution, so a single generic var
# covers all of them instead of adding one env var per flag - see app.js's
# config.extraArgs. It's a JSON array (not a plain string) in config.json
# because it's spliced into callMain()'s args array as-is; word-split here
# with `set -f` to keep glob characters in an arg (e.g. "-file *.wad") literal
# rather than letting the shell expand them against files in the container.
DOOM_EXTRA_ARGS_JSON="["
first=1
set -f
for arg in ${DOOM_EXTRA_ARGS:-}; do
    if [ "$first" -eq 1 ]; then
        first=0
    else
        DOOM_EXTRA_ARGS_JSON="${DOOM_EXTRA_ARGS_JSON},"
    fi
    DOOM_EXTRA_ARGS_JSON="${DOOM_EXTRA_ARGS_JSON}\"$(json_escape "$arg")\""
done
set +f
export DOOM_EXTRA_ARGS_JSON="${DOOM_EXTRA_ARGS_JSON}]"

# nativeClientCmd is a convenience field for humans only - app.js never reads
# it. It's the equivalent native `chocolate-doom` command line a player
# running their own client (not the browser) would need to join this exact
# game in sync - same IWAD/PWAD/DEH/extraArgs as the browser client gets,
# plus -connect/-port pointed at doom-server directly (native clients talk
# raw UDP to it, bypassing nginx/gateway entirely - see the README's
# "Connecting" section). The host is derived from DOOM_WS_URL on the
# assumption its hostname also resolves to doom-server's UDP port, which
# holds for the two-hostname setup the README recommends, but not for every
# possible deployment - it's a starting point to edit, not gospel.
DOOM_WS_HOST=$(printf '%s' "$DOOM_WS_URL" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#[:/].*##')
DOOM_NATIVE_CMD="chocolate-doom -iwad ${DOOM_IWAD_PATH}"
[ -n "${DOOM_PWAD_PATH:-}" ] && DOOM_NATIVE_CMD="${DOOM_NATIVE_CMD} -file ${DOOM_PWAD_PATH}"
[ -n "${DOOM_DEH_PATH:-}" ] && DOOM_NATIVE_CMD="${DOOM_NATIVE_CMD} -deh ${DOOM_DEH_PATH}"
[ -n "${DOOM_EXTRA_ARGS:-}" ] && DOOM_NATIVE_CMD="${DOOM_NATIVE_CMD} ${DOOM_EXTRA_ARGS}"
DOOM_NATIVE_CMD="${DOOM_NATIVE_CMD} -connect ${DOOM_WS_HOST} -port ${DOOM_SERVER_PORT:-2342}"
export DOOM_NATIVE_CMD_JSON=$(json_escape "$DOOM_NATIVE_CMD")

# config.base.json holds everything in config.json except "playerName",
# which nginx/auth.js fills in per-request from the client's own Basic Auth
# username - see nginx.conf's "location = /config.json".
envsubst '${DOOM_WS_URL} ${DOOM_IWAD_URL} ${DOOM_PWAD_URL} ${DOOM_DEH_URL} ${DOOM_EXTRA_ARGS_JSON} ${DOOM_NATIVE_CMD_JSON}' < /etc/doom/config.base.json.template > /etc/doom/config.base.json

exec nginx -g 'daemon off;'
