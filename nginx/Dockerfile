# Build context is expected to be the repo root, so this stage can see the
# vendored doom-wasm/ subtree, e.g.:
#   docker build -f nginx/Dockerfile .

# --- Stage 1: compile websockets-doom.{js,wasm,wasm.map} from doom-wasm ---
FROM emscripten/emsdk:2.0.34 AS wasm-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
      automake \
      libsdl2-dev \
      libsdl2-mixer-dev \
      libsdl2-net-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY doom-wasm/ ./
RUN ./scripts/build.sh

# --- Stage 2: serve the compiled client behind Basic Auth ---
FROM nginx:1.27-alpine

RUN apk add --no-cache gettext nginx-mod-http-js

COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/auth.js /etc/nginx/njs/auth.js
COPY nginx/config.base.json.template /etc/doom/config.base.json.template
COPY nginx/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

COPY nginx/site/ /usr/share/nginx/html/
COPY doom-wasm/src/default.cfg /usr/share/nginx/html/
COPY --from=wasm-builder /src/src/websockets-doom.js /usr/share/nginx/html/
COPY --from=wasm-builder /src/src/websockets-doom.wasm /usr/share/nginx/html/
COPY --from=wasm-builder /src/src/websockets-doom.wasm.map /usr/share/nginx/html/

# Mount point for the IWAD volume - see DOOM_IWAD_PATH in docker-entrypoint.sh.
RUN mkdir -p /wads

# The compose file can run this container as an arbitrary PUID/PGID (see
# docker-compose.yml's "user:" and PUID/PGID) so nginx can read a /wads
# volume owned by whatever uid your host uses - not just the default nginx
# user (101). These are the paths that uid needs to be able to write to
# regardless of which one it ends up being: nginx's own runtime files, and
# config.base.json, which the entrypoint generates at container start (see
# CONFIG_BASE_PATH there). None of this is sensitive - it's all
# container-internal generated config, not the /wads mount itself, which
# stays read-only and under your own control on the host.
RUN chmod 777 /var/cache/nginx /run /etc/nginx /etc/doom

EXPOSE 8080

ENTRYPOINT ["/docker-entrypoint.sh"]
