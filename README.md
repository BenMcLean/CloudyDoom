# doom.example.com

Multiplayer Doom, playable straight in the browser, pointed at your own
dedicated server - no client install, no port-forwarding a game exe, just a
URL and a password. Everything here is open source and packaged as a
docker-compose stack so anyone running a homelab server can stand up their
own copy.

Native Chocolate Doom clients can also connect directly to the same server
and play alongside the browser players - see [Connecting](#connecting)
below.

## How it works

```
  Browser (WASM Doom)              Native Chocolate Doom client
        |                                     |
        | HTTP                                |
        v                                     |
   +---------+                                |
   |  nginx  |   (Basic Auth; serves the      |
   +---------+    WASM client + IWAD)         |
        |                                     |
        | WS                                  | UDP
        v                                     |
   +-----------+     UDP      +-------------+ |
   |  gateway  | -----------> | doom-server |<+
   +-----------+              +-------------+
   (WS <-> UDP               (real Chocolate Doom
    translator)                dedicated server)
```

Three services, three published ports:

| Service | What it is | Port |
|---|---|---|
| `nginx` | Serves the WASM Doom client (built from [`cloudflare/doom-wasm`](https://github.com/cloudflare/doom-wasm), vendored in `doom-wasm/`) behind HTTP Basic Auth. Also serves the IWAD file, so the auth gate covers commercial WADs too. | `WEB_HTTP_PORT` (default `8080`, tcp) |
| `gateway` | The only genuinely new piece here. Browsers can't open raw UDP sockets, so this translates doom-wasm's WebSocket framing into plain UDP and back, giving each browser client its own UDP socket so the dedicated server can tell them apart exactly like real UDP clients. | `GATEWAY_WS_PORT` (default `8081`, tcp) |
| `doom-server` | A real, unmodified Chocolate Doom dedicated server (`chocolate-server`, from Ubuntu 20.04's package, pinned to exactly match the WASM client's fork version - see [Why 3.0.0 specifically](#why-300-specifically)). It has no idea any of this WebSocket business exists; it just sees UDP clients. | `DOOM_SERVER_PORT` (default `2342`, **udp**) |

Because `doom-server`'s UDP port is published directly (not only reachable
through the gateway), native Chocolate Doom clients connect straight to it
and land in the same game as everyone playing through the browser.

## Quick start

```
git clone --recurse-submodules <this repo's URL>   # or just git clone, doom-wasm/ is a subtree, not a submodule
cd doom
cp .env.example .env
$EDITOR .env   # set DOOM_WS_URL, DOOM_AUTH_USER, DOOM_AUTH_PASS at minimum
mkdir -p wads && cp /path/to/your/DOOM2.WAD wads/   # see "Getting an IWAD" below
docker compose up -d --build
```

Then open `http://<host>:8080` (or whatever `WEB_HTTP_PORT` you set), log in
with the Basic Auth credentials, and play.

`doom-wasm/` is a **git subtree**, not a submodule, so a plain `git clone`
already includes it - no `--recurse-submodules` actually required, that's
just there as a habit-guard in case you're used to submodule-based repos.

### Configuration

Everything is configured via environment variables at container start, not
baked into any image - see `.env.example` for the full list with defaults.
The two you can't skip:

- `DOOM_WS_URL` - the websocket URL browsers will connect to. Has to be
  reachable from wherever your players actually are (not just inside the
  docker network). If you're fronting this with a reverse proxy/TLS
  terminator (recommended - see below), point this at that proxy instead of
  directly at `GATEWAY_WS_PORT`.
- `DOOM_AUTH_USER` / `DOOM_AUTH_PASS` - HTTP Basic Auth credentials gating
  the web client and the IWAD download. This is what keeps a commercial WAD
  from being publicly downloadable, so use a real password.

### Getting an IWAD

You need an IWAD (`DOOM.WAD`, `DOOM2.WAD`, the shareware `doom1.wad`, or a
free one) dropped into `wads/` (or wherever `WAD_DIR` points) before the game
will actually run - `doom-server` itself never touches this file (see
[Why the dedicated server needs no WAD at all](#why-the-dedicated-server-needs-no-wad-at-all)),
only `nginx` serves it to the browser client.

- If you own a copy of Doom/Doom II (Steam, GOG, or the original CD), copy
  `DOOM.WAD`/`DOOM2.WAD` from your install.
- If you don't, [Freedoom](https://freedoom.github.io/) is a completely
  free, open-source IWAD (`apt install freedoom` on Debian/Ubuntu, or
  download from their site) with no licensing concerns at all - this is
  what was used to verify this whole stack actually works end to end.
- The original shareware `doom1.wad` (episode 1 only) has always been
  freely redistributable, if you specifically want the real Doom rather
  than Freedoom's replacement content.

Set `DOOM_WAD_PATH` to the filename you dropped in (defaults to
`doom1.wad`).

## Deploying with Portainer

Since the build contexts (`./gateway`, `./doom-server`, `nginx/Dockerfile`)
need the actual source tree next to the compose file, **use Portainer's
"Repository" stack type**, not the web-editor/paste-YAML method - pasting
just the YAML has no access to the Dockerfiles it references and the build
will fail.

1. Push this repo somewhere Portainer's host can reach (GitHub, a private
   Gitea instance, etc.).
2. **Stacks → Add stack → Repository.**
3. Repository URL: this repo's URL. Compose path: `docker-compose.yml`
   (the default).
4. Under **Environment variables**, add `DOOM_WS_URL`, `DOOM_AUTH_USER`,
   `DOOM_AUTH_PASS`, and any of the optional overrides from
   `.env.example` you want to change - this is Portainer's equivalent of
   the `.env` file.
5. Deploy the stack. Portainer clones the repo and runs
   `docker compose up -d --build` for you.

One homelab-specific gotcha: Portainer's git-based stacks can end up
re-cloned on redeploy, which would wipe a WAD dropped straight into the
cloned `wads/` folder. Point `WAD_DIR` at a stable path outside the stack's
clone instead, e.g. `WAD_DIR=/srv/doom-wads`, and drop your IWAD there once.

## Connecting

- **Browser**: open `http://<host>:<WEB_HTTP_PORT>`, log in, play. Press
  **Alt+Enter** in-game to toggle real browser fullscreen (this is a stock
  Chocolate Doom feature, not something added here - see `i_video.c`'s
  `I_ToggleFullScreen`).
- **Native Chocolate Doom client**: `chocolate-doom -connect <host> -port
  <DOOM_SERVER_PORT>`. Lands in the same game as the browser players, since
  it's talking to the exact same dedicated server - verified with a packet
  capture showing a raw UDP client and a gateway-relayed browser client
  hitting `doom-server` from genuinely distinct sources simultaneously.

## Putting this behind a reverse proxy / TLS

**This compose file does not terminate TLS.** HTTP Basic Auth sends
credentials in the clear, so exposing `WEB_HTTP_PORT`/`GATEWAY_WS_PORT`
directly to the internet means leaking your password to anyone on the
path. For anything beyond local testing, put this behind a TLS-terminating
reverse proxy or tunnel (Caddy, your own nginx, a Cloudflare Tunnel, etc.)
and point `DOOM_WS_URL` at that proxy's `wss://` address instead of the raw
gateway port.

## Troubleshooting

- **Game connects then "Lost connection to server" a few seconds later,
  `doom-server`'s logs are empty**: this bit us during development. C's
  stdout is fully-buffered (not line-buffered) when it isn't a TTY, which is
  always true under Docker, so `chocolate-server`'s own logging silently
  vanishes into a buffer instead of reaching `docker logs`. Already fixed
  here (`doom-server/docker-entrypoint.sh` wraps it in `stdbuf -oL -eL`) -
  if you see this again after modifying that file, that's the first thing
  to check.
- **`NET_CL_ParseSYN: ... mismatch may cause the game to desync` in the
  browser console**: harmless. It's comparing the WASM client's build
  identifier (`Websockets Doom 0.0.1`) against the dedicated server's
  (`Chocolate Doom 3.0.0`) - different strings, but the actual game
  simulation code is identical, and the dedicated server doesn't run any
  game simulation at all (see below), so there's nothing for it to desync
  from. Confirmed by an actual full playthrough.

## Why 3.0.0 specifically

`doom-wasm`'s netcode (packet structs, `NET_MAGIC_NUMBER`) is a straight
fork of Chocolate Doom **3.0.0** with only the transport module swapped
(UDP → WebSockets); nothing else in the game/network logic was changed.
`doom-server/Dockerfile` pins `ubuntu:20.04` specifically because its
`universe` repo ships `chocolate-doom` at exactly `3.0.0-5`, and asserts
that version at build time so a base-image bump can't silently drift the
netcode version out of sync with the WASM client and break the handshake.

## Why the dedicated server needs no WAD at all

`chocolate-server` refuses `-iwad` and every other game/IWAD option
outright (see its own `not_dedicated_options` check) - it's a pure netcode
sequencer, not an authoritative game simulation. Doom's netcode is a
deterministic lockstep model: every client simulates the game itself from
the same synchronized inputs, and the "server" just relays and sequences
those inputs. That's also why the version-mismatch warning above is a
non-issue - there's no simulation running server-side to diverge from in
the first place.

## Credits / license

- [`cloudflare/doom-wasm`](https://github.com/cloudflare/doom-wasm) - the
  Chocolate Doom → WebAssembly port this is built on, vendored in
  `doom-wasm/` as a git subtree.
- [Chocolate Doom](https://www.chocolate-doom.org/) - the underlying source
  port; see `doom-wasm/COPYING.md` for its GPL license text, which also
  covers the compiled client and dedicated server here.
- [Freedoom](https://freedoom.github.io/) - free IWAD used to verify this
  stack, if you don't have a commercial WAD handy.
