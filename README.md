# CloudyDoom

Multiplayer Doom, playable straight in the browser, pointed at your own
dedicated server. For the people you invite to play: no client install, no
router config, just a URL and a password. Everything here is open source
and packaged as a docker-compose stack so anyone running a homelab server
can stand up their own copy.

That "no setup" experience is only true for players - **you, running the
server, still need to expose it to the internet**, same as hosting any
other self-hosted service. Exactly what that involves depends on how you
front it: if `nginx` and `gateway` ride an existing reverse proxy setup
(Cloudflare for the website, a local proxy like nginx-proxy-manager for
the gateway - see below), the only genuinely *new* port-forward is likely
`DOOM_SERVER_PORT` (raw UDP), since that one can't go through any reverse
proxy at all - not Cloudflare's, not a local one, none of them. See
[Putting this behind a reverse proxy / TLS](#putting-this-behind-a-reverse-proxy--tls)
for the concrete setup and exactly what that means for your router.

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
credentials in the clear, and browsers flatly refuse to open a plain
`ws://` connection from a page loaded over `https://` ("mixed content"
blocking - not a warning, a hard failure). So for anything beyond local
testing, both `nginx` and `gateway` need to sit behind something that
terminates TLS.

The setup this project was actually designed around uses **two separate
domains**, because the web client and the game traffic have very different
latency requirements:

- **`doom.example.com`** (or whatever hostname you pick) - Cloudflare's
  proxy (orange-cloud DNS) in front, serving the web client and IWAD. This
  is ordinary HTTP(S) traffic with no latency sensitivity, so routing it
  through Cloudflare's remote edge is fine.
- **A second hostname** (e.g. `notproxied.example.com`) - a plain,
  unproxied ("grey-cloud"/DNS-only) A record pointing straight at your home
  IP, for everything latency-sensitive: the gateway's WebSocket traffic and
  `doom-server`'s raw UDP. Routing real-time game traffic through a remote
  CDN edge adds a real round-trip that a direct connection doesn't have -
  worth avoiding even though Cloudflare's proxy is technically capable of
  carrying WebSocket traffic.

That second hostname still needs TLS for the `wss://` requirement above,
without introducing the latency a remote proxy would. If you're already
running **nginx-proxy-manager** (or Caddy, Traefik, etc.) locally on that
same server for your other self-hosted apps, that's the right tool for
this too - it's a local hop (microseconds), nothing like Cloudflare's
geographic round-trip, and it gets you automatic Let's Encrypt certs for
free.

### Configuring nginx-proxy-manager

Add two Proxy Hosts (NPM's "Hosts → Proxy Hosts → Add Proxy Host"):

1. **The website**, if it isn't already behind Cloudflare directly:
   - Domain: `doom.example.com`
   - Forward to: `<your-server's-LAN-IP>:8080` (or the `nginx` container's
     name/port if NPM shares a Docker network with this stack - see note
     below)
   - Request a new SSL certificate, force SSL - standard stuff, same as
     any other app you've already proxied through NPM.

2. **The WebSocket gateway** - this is the one with a step that's easy to
   miss:
   - Domain: `notproxied.example.com`
   - Forward to: `<your-server's-LAN-IP>:8081`
   - On the **Details** tab, enable **"Websockets Support"**. Without this,
     NPM won't forward the `Upgrade`/`Connection` headers the WebSocket
     handshake needs, and every browser client will fail to connect with
     no obvious error pointing at NPM as the cause.
   - Request a new SSL certificate here too, force SSL.

Then set `DOOM_WS_URL=wss://notproxied.example.com` in `.env` (or
Portainer's environment variables) - no custom port needed, since NPM
terminates `443` and forwards internally to `gateway`'s `8081`.

**Docker networking note:** if NPM runs as its own separate compose stack
(as it typically does), it can reach `nginx`/`gateway` simply via your
server's own IP and the ports this project already publishes to the host
(`WEB_HTTP_PORT`/`GATEWAY_WS_PORT`) - no changes needed here. If you'd
rather avoid that host-network hairpin and proxy by container name instead,
join `nginx`/`gateway` to NPM's Docker network in your own compose
override and point NPM at `nginx:8080`/`gateway:8081` directly.

**`DOOM_SERVER_PORT` (raw UDP) can't go through NPM either** - nginx-based
reverse proxies are HTTP(S)/WebSocket-only, the same fundamental
limitation as Cloudflare's standard proxy, just for a config reason rather
than a product-tier one. Forward it straight through your router to
`doom-server`, same as you would for any other UDP game server.

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
