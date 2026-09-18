# Ubuntu 20.04's universe repo only ever ships chocolate-doom 3.0.0-5, which
# predates chocolate-doom's own -netlog debug tracing and various net_server.c
# fixes. We build chocolate-server from source at a specific upstream tag
# instead, so we're not stuck on whatever a distro happens to package.
#
# This is safe to bump independently of doom-wasm/ (the browser client,
# forked from chocolate-doom 3.0.0's netcode): NET_MAGIC_NUMBER - the wire
# protocol's compatibility marker - and the SYN/accept/reject handshake in
# net_server.c are unchanged all the way from 3.0.0 to current upstream
# master, so a newer chocolate-server still talks to the pinned 3.0.0-fork
# client. Verify that still holds (diff net_defs.h's NET_MAGIC_NUMBER and
# net_server.c's handshake code against doom-wasm/src/) before bumping
# CHOCOLATE_DOOM_REF to something further out.
FROM ubuntu:24.04 AS builder

ARG CHOCOLATE_DOOM_REF=chocolate-doom-3.1.1

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git \
        build-essential autoconf automake libtool pkg-config python3 \
        libsdl2-dev libsdl2-net-dev libsdl2-mixer-dev libpng-dev \
        libsamplerate0-dev libfluidsynth-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "$CHOCOLATE_DOOM_REF" \
        https://github.com/chocolate-doom/chocolate-doom.git /src

# Only chocolate-server is built (not the full chocolate-doom/heretic/hexen/
# strife/setup suite) - it's the only binary this image ships. Per
# src/Makefile.am, chocolate-server_LDADD is just SDLNET_LIBS, so it only
# links SDL2_net at runtime even though the top-level ./configure still needs
# the full SDL2/SDL2_mixer/libpng/etc dev stack present to succeed.
WORKDIR /src
RUN ./autogen.sh && make -C src chocolate-server

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        libsdl2-net-2.0-0 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/src/chocolate-server /usr/games/chocolate-server

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# 2342/udp is Chocolate Doom's default port (net_sdl.c DEFAULT_PORT); actual
# published port is controlled entirely by docker-compose's port mapping.
EXPOSE 2342/udp

ENTRYPOINT ["/docker-entrypoint.sh"]
