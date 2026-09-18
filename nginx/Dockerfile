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

RUN apk add --no-cache apache2-utils gettext

COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/config.json.template /etc/doom/config.json.template
COPY nginx/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

COPY nginx/site/ /usr/share/nginx/html/
COPY doom-wasm/src/default.cfg /usr/share/nginx/html/
COPY --from=wasm-builder /src/src/websockets-doom.js /usr/share/nginx/html/
COPY --from=wasm-builder /src/src/websockets-doom.wasm /usr/share/nginx/html/
COPY --from=wasm-builder /src/src/websockets-doom.wasm.map /usr/share/nginx/html/

# Mount point for the IWAD volume - see DOOM_WAD_PATH in docker-entrypoint.sh.
RUN mkdir -p /wads

EXPOSE 8080

ENTRYPOINT ["/docker-entrypoint.sh"]
