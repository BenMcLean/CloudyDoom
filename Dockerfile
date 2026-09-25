# Single combined image: nginx (serves the doom-wasm client + gates it with
# Basic Auth), the websocket<->UDP gateway, and chocolate-server (the real
# dedicated game server) all run in one container, supervised by s6-overlay -
# the process supervisor linuxserver.io images use. Previously these were
# three separate containers/images (see git history for nginx/Dockerfile,
# gateway/Dockerfile, doom-server/Dockerfile); one image is simpler to build,
# publish and run for an app this size, at the cost of losing independent
# per-process restarts/scaling.

# --- Stage 1: compile websockets-doom.{js,wasm,wasm.map} from doom-wasm ---
# Fetched from upstream at build time rather than vendored in this repo -
# verified unmodified (byte-for-byte identical to cloudflare/doom-wasm@main,
# modulo line endings) before switching to this, so there was nothing local
# to lose. Pinned to a specific commit, not a floating branch, for the same
# reproducibility reason CHOCOLATE_DOOM_REF below is a tag rather than
# "master" - bump DOOM_WASM_REF deliberately, don't let it drift.
#
# --platform=$BUILDPLATFORM pins this stage to the build host's own
# architecture regardless of which platform(s) the final image targets
# (see docker-publish.yml's PLATFORMS). The output here is WASM bytecode +
# JS glue - architecture-independent - so without this, a multi-platform
# buildx run would QEMU-emulate this whole emscripten compile a second time
# for arm64 to produce byte-identical output. doom-server-builder below
# deliberately has no such pin: it compiles a real native ELF binary, so it
# needs to run once per target platform.
FROM --platform=$BUILDPLATFORM emscripten/emsdk:2.0.34 AS wasm-builder

ARG DOOM_WASM_REF=65e0d3ae2ffa604155eebd96ed40da6567bd08f4

RUN apt-get update && apt-get install -y --no-install-recommends \
      automake \
      git \
      libsdl2-dev \
      libsdl2-mixer-dev \
      libsdl2-net-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone https://github.com/cloudflare/doom-wasm.git . && \
    git checkout "$DOOM_WASM_REF" && \
    rm -rf .git
RUN ./scripts/build.sh

# --- Stage 2: compile chocolate-server from source ---
# Ubuntu 20.04's universe repo only ever ships chocolate-doom 3.0.0-5, which
# predates chocolate-doom's own -netlog debug tracing and various net_server.c
# fixes. We build chocolate-server from source at a specific upstream tag
# instead, so we're not stuck on whatever a distro happens to package.
#
# This is safe to bump independently of DOOM_WASM_REF above (the browser
# client, forked from chocolate-doom 3.0.0's netcode): NET_MAGIC_NUMBER - the
# wire protocol's compatibility marker - and the SYN/accept/reject handshake
# in net_server.c are unchanged all the way from 3.0.0 to current upstream
# master, so a newer chocolate-server still talks to the pinned 3.0.0-fork
# client. Verify that still holds (diff net_defs.h's NET_MAGIC_NUMBER and
# net_server.c's handshake code against cloudflare/doom-wasm's src/) before
# bumping CHOCOLATE_DOOM_REF to something further out.
FROM ubuntu:24.04 AS doom-server-builder

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

# --- Stage 3: final runtime image ---
FROM ubuntu:24.04

ARG S6_OVERLAY_VERSION=3.2.3.2
ARG TARGETARCH

# nodejs/npm: the gateway is plain JS with no native deps (ws's optional
# bufferutil/utf-8-validate addons are skipped without build tools present,
# which is fine - it falls back to its pure-JS implementation).
#
# nginx-core + libnginx-mod-http-js: Ubuntu noble's nginx-core is 1.24.0,
# matching libnginx-mod-http-js's nginx-abi-1.24.0-1 requirement - see
# nginx/nginx.conf's "load_module" for why njs is needed (auth.js).
#
# libsdl2-net-2.0-0: chocolate-server's only runtime dependency (see
# doom-server-builder above).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils gettext-base \
        nodejs npm \
        nginx-core libnginx-mod-http-js \
        libsdl2-net-2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# s6-overlay: the process supervisor. Installed from upstream release
# tarballs (not apt-packaged) per the project's own install instructions.
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) S6_ARCH=x86_64 ;; \
      arm64) S6_ARCH=aarch64 ;; \
      arm) S6_ARCH=arm ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/s6-noarch.tar.xz \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" && \
    curl -fsSL -o /tmp/s6-arch.tar.xz \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" && \
    tar -C / -Jxpf /tmp/s6-noarch.tar.xz && \
    tar -C / -Jxpf /tmp/s6-arch.tar.xz && \
    rm -f /tmp/s6-noarch.tar.xz /tmp/s6-arch.tar.xz

# s6-overlay behaviour: keep the container's own env visible to every
# supervised service (no per-service "with-contenv" wrapping needed), and
# exit the whole container - instead of hanging - if any oneshot/longrun
# fails during startup, so a broken config fails loudly under `docker logs`
# rather than leaving a half-running container.
ENV S6_KEEP_ENV=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    HOME=/tmp

# --- App content ---

COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/auth.js /etc/nginx/njs/auth.js
COPY nginx/config.base.json.template /etc/doom/config.base.json.template
COPY nginx/site/ /usr/share/nginx/html/
COPY --from=wasm-builder /src/src/default.cfg /usr/share/nginx/html/
COPY --from=wasm-builder /src/src/websockets-doom.js /usr/share/nginx/html/
COPY --from=wasm-builder /src/src/websockets-doom.wasm /usr/share/nginx/html/
COPY --from=wasm-builder /src/src/websockets-doom.wasm.map /usr/share/nginx/html/

COPY --from=doom-server-builder /src/src/chocolate-server /usr/games/chocolate-server

WORKDIR /app/gateway
COPY gateway/package.json ./
RUN npm install --omit=dev
COPY gateway/gateway.js ./

# --- s6-overlay service definitions ---
COPY rootfs/ /

# Windows checkouts (this repo's dev machine) can't preserve the executable
# bit these need, so it's set explicitly here rather than relied on from git.
RUN chmod +x \
        /etc/s6-overlay/scripts/prepare-nginx.sh \
        /etc/s6-overlay/s6-rc.d/svc-nginx/run \
        /etc/s6-overlay/s6-rc.d/svc-gateway/run \
        /etc/s6-overlay/s6-rc.d/svc-doom-server/run

# Mount point for the IWAD volume - see DOOM_IWAD_PATH in
# rootfs/etc/s6-overlay/scripts/prepare-nginx.sh.
RUN mkdir -p /wads

# The container can run as an arbitrary PUID/PGID (see docker-compose.yml's
# "user:" and PUID/PGID) so it can read a /wads volume owned by whatever uid
# your host uses - not just root. These are the paths that uid needs to be
# able to write to regardless of which one it ends up being: nginx's own
# runtime files, config.base.json (generated at container start - see
# prepare-nginx.sh), and s6-overlay's own runtime state under /run. None of
# this is sensitive - it's all container-internal generated state, not the
# /wads mount itself, which stays read-only and under your own control on
# the host.
# /var/lib/nginx/{body,proxy,fastcgi,scgi,uwsgi} are Ubuntu's compiled-in
# nginx temp-file paths (see its --http-client-body-temp-path etc. build
# flags) - normally created/chowned by the nginx.deb package's postinst for
# the "nginx" user, which doesn't help when running as an arbitrary uid.
RUN mkdir -p /var/cache/nginx /var/lib/nginx/body /var/lib/nginx/proxy \
        /var/lib/nginx/fastcgi /var/lib/nginx/scgi /var/lib/nginx/uwsgi \
    && chmod -R 777 /var/cache/nginx /var/lib/nginx /run /etc/nginx /etc/doom

# Purely documentation - Docker EXPOSE doesn't actually publish anything
# (docker-compose.yml's port mappings do that), and all three of these are
# runtime-configurable via WEB_HTTP_PORT/GATEWAY_WS_PORT/DOOM_SERVER_PORT
# anyway (see prepare-nginx.sh, svc-gateway/run, svc-doom-server/run). 2344/
# 2343/2342 (nginx/gateway/doom-server) are the defaults, chosen to sit next
# to each other - see the README's port table.
EXPOSE 2344 2343 2342/udp

ENTRYPOINT ["/init"]
