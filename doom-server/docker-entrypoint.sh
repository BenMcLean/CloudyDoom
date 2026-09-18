#!/bin/sh
set -eu

# chocolate-server is a pure netcode sequencer: it refuses any game/IWAD
# option (see its own not_dedicated_options check) and exposes almost
# nothing to configure - port is the one thing worth exposing here.
DOOM_SERVER_PORT="${DOOM_SERVER_PORT:-2342}"

# chocolate-server's stdout is fully-buffered when it isn't a TTY (which it
# never is under Docker), so its printf logging would otherwise sit in a
# buffer and never reach `docker logs` at all. stdbuf forces line buffering.
exec stdbuf -oL -eL /usr/games/chocolate-server -port "$DOOM_SERVER_PORT"
