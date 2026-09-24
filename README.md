# CloudyDoom

Multiplayer Doom, playable straight in the browser, pointed at your own
dedicated server. For the people you invite to play: no client install, no
router config, just a URL and a password. Everything here is open source
and ships as a single container image
([`ghcr.io/benmclean/cloudydoom`](https://github.com/BenMcLean/CloudyDoom/pkgs/container/cloudydoom))
plus a docker-compose file, so anyone running a homelab server can stand up
their own copy with `docker compose up -d`.

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

   \_____________________ one container ______________________/
```

Three processes, one container, three published ports - `nginx`, `gateway`
and `doom-server` are supervised together in a single image by
[s6-overlay](https://github.com/just-containers/s6-overlay) (see the root
`Dockerfile` and `rootfs/etc/s6-overlay/`), rather than three separate
containers on a compose network. They still talk to each other exactly as
the diagram shows, just over `localhost` instead of Docker's inter-container
DNS.

| Process | What it is | Port |
|---|---|---|
| `doom-server` | A real, unmodified Chocolate Doom dedicated server (`chocolate-server`, built from source at a pinned upstream tag newer than the WASM client's fork version, since the wire protocol has stayed compatible - see [Why a newer version works](#why-a-newer-version-works)). It has no idea any of this WebSocket business exists; it just sees UDP clients. | `DOOM_SERVER_PORT` (default `2342`, **udp**) |
| `gateway` | The only genuinely new piece here. Browsers can't open raw UDP sockets, so this translates doom-wasm's WebSocket framing into plain UDP and back, giving each browser client its own UDP socket so the dedicated server can tell them apart exactly like real UDP clients. | `GATEWAY_WS_PORT` (default `2343`, tcp) |
| `nginx` | Serves the WASM Doom client (built from [`cloudflare/doom-wasm`](https://github.com/cloudflare/doom-wasm), fetched at a pinned commit during the Docker build - see the Dockerfile) behind HTTP Basic Auth. Also serves the IWAD file, so the auth gate covers commercial WADs too. | `WEB_HTTP_PORT` (default `2344`, tcp) |

The three defaults sit right next to each other (`2342`/`2343`/`2344`) so
they're easy to remember as a group - each is independently overridable if
one of them collides with something else on your server.

Because `doom-server`'s UDP port is published directly (not only reachable
through the gateway), native Chocolate Doom clients connect straight to it
and land in the same game as everyone playing through the browser.

## Quick start

No source checkout needed - this is a published image
([`ghcr.io/benmclean/cloudydoom`](https://github.com/BenMcLean/CloudyDoom/pkgs/container/cloudydoom),
built by this repo's own
[`docker-publish.yml`](.github/workflows/docker-publish.yml) workflow).
Paste this into a `docker-compose.yml` on your server:

```yaml
# The dedicated server's port needs to be set in two places below.
# Defined ONCE here instead, so this is the one number to change, not two.
x-doom-server-port: &doom_server_port 2342

services:
  cloudydoom:
    image: ghcr.io/benmclean/cloudydoom:latest
    ports:
      - target: *doom_server_port
        published: *doom_server_port
        protocol: udp
      - "2343:2343"       # websocket gateway
      - "2344:2344"       # web client (http)
    environment:
      DOOM_SERVER_PORT: *doom_server_port
      # The websocket URL browsers will connect to - has to be reachable
      # from wherever your players are, not just this server. The ":2343"
      # here is only for connecting straight to GATEWAY_WS_PORT with no
      # proxy in front. Behind a reverse proxy (recommended - see "Putting
      # this behind a reverse proxy / TLS" below), drop the port entirely,
      # e.g. "wss://doom.example.com", since your proxy terminates 443 and
      # forwards to 2343 internally. Full details:
      # https://github.com/BenMcLean/CloudyDoom#configuration
      DOOM_WS_URL: wss://doom.example.com
      # Shared login password. Leave blank for a public server with
      # nothing to gate (e.g. a Freedoom IWAD instead of a commercial one).
      PASSWORD: changeme
      DOOM_IWAD_PATH: DOOM2.WAD
      DOOM_PWAD_PATH: dwango5.wad
    volumes:
      # "host:container" - same rule as the ports above: only change the
      # host side (left of the colon, currently "./wads"). Point it at
      # wherever you keep your WAD files, e.g. "/srv/doom-wads:/wads:ro".
      # Leave ":/wads:ro" (right of the colon) exactly as shown.
      - ./wads:/wads:ro
    restart: unless-stopped
```

Then:

```
mkdir -p wads && cp /path/to/your/DOOM2.WAD wads/   # see "Getting an IWAD" below
docker compose up -d
```

Open `http://<host>:2344`, log in with any username and the shared password,
and play - the username you type becomes your in-game player name.

The block above is a trimmed-down starting point. For every optional setting
(PWAD/DeHackEd patches, extra game flags, PUID/PGID, port overrides, ...),
use this repo's own [`docker-compose.yml`](docker-compose.yml) +
[`.env.example`](.env.example) instead, either by cloning the repo or
fetching just those two files:

```
curl -O https://raw.githubusercontent.com/BenMcLean/CloudyDoom/master/docker-compose.yml
curl -O https://raw.githubusercontent.com/BenMcLean/CloudyDoom/master/.env.example
cp .env.example .env
$EDITOR .env   # set DOOM_WS_URL at minimum, and PASSWORD if you're gating a commercial IWAD
mkdir -p wads && cp /path/to/your/DOOM2.WAD wads/
docker compose up -d
```

### Building from source instead of pulling the image

If you're testing a local change, clone the repo instead - `docker-compose.yml`
already has `build: .` alongside `image:`, so `docker compose up -d --build`
builds from your checkout and tags it locally rather than pulling:

```
git clone <this repo's URL>
cd CloudyDoom
cp .env.example .env && $EDITOR .env
docker compose up -d --build
```

No submodules to worry about here, either - `doom-wasm` isn't vendored into
this repo at all. It's fetched fresh from
[`cloudflare/doom-wasm`](https://github.com/cloudflare/doom-wasm) at a
pinned commit inside the Docker build itself (see `DOOM_WASM_REF` in the
Dockerfile's `wasm-builder` stage), which keeps the build reproducible
without keeping a second copy of someone else's source tree in this repo's
history.

### Configuration

Everything is configured via environment variables at container start, not
baked into any image - see `.env.example` for the full list with defaults.
The one you can't skip:

- `DOOM_WS_URL` - the websocket URL browsers will connect to. Has to be
  reachable from wherever your players actually are (not just inside the
  docker network). If you're fronting this with a reverse proxy/TLS
  terminator (recommended - see below), point this at that proxy instead of
  directly at `GATEWAY_WS_PORT`.

And one you should set unless you have a specific reason not to:

- `PASSWORD` - the shared HTTP Basic Auth password gating the web client and
  the IWAD download. This is what keeps a commercial WAD from being publicly
  downloadable, so use a real password. The username is not checked -
  anyone can pick any username, and it becomes their in-game player name
  (see `nginx/auth.js`). Leave it blank/unset only if you're deliberately
  running a public server with nothing to gate (e.g. serving Freedoom
  instead of a commercial IWAD) - the login prompt still appears so players
  can pick a name, but any password is accepted.
- `USE_LOGIN_NAME` - set to `false` to stop using the login username as the
  in-game player name; everyone gets one of doom-wasm's own random pet
  names instead. Combined with a blank `PASSWORD`, setting this to `false`
  too drops the login prompt entirely - players go straight into the game.

`.env.example` opens with a "one with everything" block listing every
supported var in one place - copy that instead of hunting through the rest
of the file for exact names, then delete whatever you don't need:

```sh
DOOM_WS_URL=wss://doom.example.com
PASSWORD=changeme
USE_LOGIN_NAME=true
DOOM_SERVER_PORT=2342
GATEWAY_WS_PORT=2343
WEB_HTTP_PORT=2344
WAD_DIR=./wads
DOOM_IWAD_PATH=DOOM2.WAD
DOOM_PWAD_PATH=MYMAPS.WAD
DOOM_DEH_PATH=PATCH.DEH
DOOM_EXTRA_ARGS=-skill 4 -deathmatch -fast -warp 5 -timer 10
PUID=1000
PGID=1000
```

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

Set `DOOM_IWAD_PATH` to the filename you dropped in (defaults to
`doom1.wad`).

`WAD_DIR` is mounted **read-only** into the container - it can serve from
there, never write to it. On a real Linux host, the container also needs to
actually be able to *read* whatever's in that directory in the first place:
it runs as its own built-in `nginx` user (uid/gid 101) by default, which
won't be able to read a directory owned by, say, a dedicated media/homelab
user on your system. If you hit a permission error here, set `PUID`/`PGID`
in `.env` to match that directory's actual owner - see `.env.example`.

### Using a PWAD or a DeHackEd (.deh) patch

A PWAD (map pack, mod add-on) and a DeHackEd patch (gameplay mod) both work
the same way as the IWAD above: drop the file into `wads/` (or wherever
`WAD_DIR` points) alongside your IWAD, then point one of these at its
filename:

- `DOOM_PWAD_PATH` - loaded on top of the IWAD with `-file`, e.g. a map
  pack's `MYMAPS.WAD`.
- `DOOM_DEH_PATH` - applied with `-deh`, e.g. a gameplay mod's `PATCH.DEH`.

Both are unset by default, meaning neither is loaded and the game runs as
the plain IWAD. Like the IWAD, `doom-server` never touches either file
(chocolate-server refuses all game/IWAD options - see
[Why the dedicated server needs no WAD at all](#why-the-dedicated-server-needs-no-wad-at-all));
they're downloaded and applied client-side by the browser player, the same
way a native `chocolate-doom -file MYMAPS.WAD -deh PATCH.DEH -connect <host>`
client would need the same files to stay in sync with everyone else.

### Extra game settings (skill, starting map, deathmatch, ...)

`DOOM_EXTRA_ARGS` is a space-separated string of any other doom-wasm command
line flags, applied equally to every player - e.g. difficulty, which
episode/map to start on, or deathmatch mode. It's unset by default, so
doom-wasm's own defaults apply (skill 3, episode 1 map 1, cooperative).

This has to be a single shared var rather than a per-player setting: Doom's
netcode requires every connecting client's game settings to match exactly,
or the game desyncs them. Unlike `DOOM_IWAD_PATH`/`DOOM_PWAD_PATH`/
`DOOM_DEH_PATH` above, these flags need no file resolution, so one generic
var covers all of them instead of adding a dedicated env var per flag - see
`nginx/site/app.js`'s `config.extraArgs`.

Some useful flags (full list: `chocolate-doom --help`, or the
[chocolate-doom man page](https://www.chocolate-doom.org/wiki/index.php/Man_pages)):

- `-skill <1-5>` - difficulty, 1 (I'm too young to die) to 5 (Nightmare!).
- `-warp <episode> <map>` (Doom 1/Ultimate Doom/Heretic) or `-warp <map>`
  (Doom II/Final Doom/Hexen) - which level to start on.
- `-deathmatch` / `-altdeath` - deathmatch instead of cooperative.
- `-nomonsters` - no monsters spawn.
- `-fast` - monsters move/attack at Nightmare speed regardless of `-skill`.
- `-respawn` - monsters respawn after being killed.
- `-turbo <10-255>` - player movement speed as a percentage of normal.
- `-timer <minutes>` - deathmatch time limit.

Example, combining several of the above for a fast-paced UV deathmatch
starting on Doom II's MAP05:

```
DOOM_EXTRA_ARGS=-skill 4 -deathmatch -fast -warp 5 -timer 10
```

## Deploying with Portainer

Since the compose file pulls the published `ghcr.io/benmclean/cloudydoom`
image (see [Quick start](#quick-start) above), Portainer's **web-editor
("Web editor") stack type works fine** - paste `docker-compose.yml`'s
contents directly, no repository access to a Dockerfile needed:

1. **Stacks → Add stack → Web editor.**
2. Paste in the contents of `docker-compose.yml`.
3. Under **Environment variables**, add `DOOM_WS_URL`, `PASSWORD`,
   and any of the optional overrides from `.env.example` you want to
   change - this is Portainer's equivalent of the `.env` file.
4. Deploy the stack. Portainer pulls the image and starts the container.

(You can still use Portainer's "Repository" stack type pointed at this repo
if you'd rather build from source than pull the published image - just be
aware that mode rebuilds on every redeploy unless you remove `build: .` from
your copy of the compose file.)

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
  If you've set `DOOM_PWAD_PATH`/`DOOM_DEH_PATH`/`DOOM_EXTRA_ARGS`, the
  native client needs the matching `-file`/`-deh`/flags too, or it'll fail
  Doom's netgame consistency check against the browser players - rather
  than reconstructing that by hand, fetch `config.json` from the running
  server (`curl -u <user>:<pass> https://<host>/config.json`, or just view
  it in a browser tab, once logged in) and copy its `nativeClientCmd`
  field: a ready-to-paste command line with everything already filled in.
  It's there purely for humans to read - the browser client itself never
  looks at it.

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
   - Forward to: `<your-server's-LAN-IP>:2344` (or the `cloudydoom`
     container's name/port if NPM shares a Docker network with this stack -
     see note below)
   - Request a new SSL certificate, force SSL - standard stuff, same as
     any other app you've already proxied through NPM.

2. **The WebSocket gateway** - this is the one with a step that's easy to
   miss:
   - Domain: `notproxied.example.com`
   - Forward to: `<your-server's-LAN-IP>:2343`
   - On the **Details** tab, enable **"Websockets Support"**. Without this,
     NPM won't forward the `Upgrade`/`Connection` headers the WebSocket
     handshake needs, and every browser client will fail to connect with
     no obvious error pointing at NPM as the cause.
   - Request a new SSL certificate here too, force SSL.

Then set `DOOM_WS_URL=wss://notproxied.example.com` in `.env` (or
Portainer's environment variables) - no custom port needed, since NPM
terminates `443` and forwards internally to the gateway's `2343`.

**Docker networking note:** if NPM runs as its own separate compose stack
(as it typically does), it can reach the container simply via your server's
own IP and the ports this project already publishes to the host
(`WEB_HTTP_PORT`/`GATEWAY_WS_PORT`) - no changes needed here. If you'd
rather avoid that host-network hairpin and proxy by container name instead,
join `cloudydoom` to NPM's Docker network in your own compose override and
point NPM at `cloudydoom:2344`/`cloudydoom:2343` directly.

**`DOOM_SERVER_PORT` (raw UDP) can't go through NPM either** - nginx-based
reverse proxies are HTTP(S)/WebSocket-only, the same fundamental
limitation as Cloudflare's standard proxy, just for a config reason rather
than a product-tier one. Forward it straight through your router to
`doom-server`, same as you would for any other UDP game server.

## Updating

`docker-compose.yml` pins `ghcr.io/benmclean/cloudydoom:latest`, which
tracks `master` - `docker compose pull && docker compose up -d` picks up
the newest published image. Pin a specific released version instead
(`ghcr.io/benmclean/cloudydoom:1.2.3`, published whenever this repo tags a
`v1.2.3` release) if you'd rather control upgrades explicitly - see
[Publish Docker image](.github/workflows/docker-publish.yml) for exactly
which tags get pushed and when.

## Troubleshooting

- **Game connects then "Lost connection to server" a few seconds later,
  `doom-server`'s logs are empty**: this bit us during development. C's
  stdout is fully-buffered (not line-buffered) when it isn't a TTY, which is
  always true under Docker, so `chocolate-server`'s own logging silently
  vanishes into a buffer instead of reaching `docker logs`. Already fixed
  here (`rootfs/etc/s6-overlay/s6-rc.d/svc-doom-server/run` wraps it in
  `stdbuf -oL -eL`) - if you see this again after modifying that file,
  that's the first thing to check.
- **`NET_CL_ParseSYN: ... mismatch may cause the game to desync` in the
  browser console**: harmless. It's comparing the WASM client's build
  identifier (`Websockets Doom 0.0.1`) against the dedicated server's
  (e.g. `Chocolate Doom 3.1.1`) - different strings, and the actual game
  simulation code is unaffected by the version gap for the reason below, so
  there's nothing for it to desync from. Confirmed by an actual full
  playthrough.

## Why a newer version works

`doom-wasm`'s netcode is a fork of Chocolate Doom 3.0.0, while
`doom-server` runs a newer version built from source - see the comment above
the `doom-server-builder` stage in the root `Dockerfile` for why that
version gap is safe and what to re-verify before widening it further.

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
  Chocolate Doom → WebAssembly port this is built on, fetched at a pinned
  commit during the Docker build (see `DOOM_WASM_REF` in the Dockerfile),
  not vendored into this repo.
- [Chocolate Doom](https://www.chocolate-doom.org/) - the underlying source
  port; see [`doom-wasm`'s `COPYING.md`](https://github.com/cloudflare/doom-wasm/blob/main/COPYING.md)
  for its GPL license text, which also covers the compiled client and
  dedicated server here.
- [Freedoom](https://freedoom.github.io/) - free IWAD used to verify this
  stack, if you don't have a commercial WAD handy.
