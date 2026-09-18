# Pinned to 20.04 specifically because its universe repo ships chocolate-doom
# 3.0.0-5 - the exact version doom-wasm/ (the browser client) is forked from.
# Chocolate Doom's netcode is version-sensitive (NET_MAGIC_NUMBER + packet
# structs baked in at compile time); a newer Ubuntu release would pull a
# newer chocolate-doom and silently break the handshake with the WASM
# client. Do not change this without re-verifying the client/server versions
# still match.
FROM ubuntu:20.04

RUN apt-get update && apt-get install -y --no-install-recommends chocolate-doom \
    && dpkg -s chocolate-doom | grep -q '^Version: 3\.0\.0' \
    && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# 2342/udp is Chocolate Doom's default port (net_sdl.c DEFAULT_PORT); actual
# published port is controlled entirely by docker-compose's port mapping.
EXPOSE 2342/udp

ENTRYPOINT ["/docker-entrypoint.sh"]
