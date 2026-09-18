#!/bin/sh
set -eu

# chocolate-server is a pure netcode sequencer: it refuses any game/IWAD
# option (see its own not_dedicated_options check) and exposes almost
# nothing to configure - port is the one thing worth exposing here.
DOOM_SERVER_PORT="${DOOM_SERVER_PORT:-2342}"

exec /usr/games/chocolate-server -port "$DOOM_SERVER_PORT"
