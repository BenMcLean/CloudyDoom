// Loader for websockets-doom.js.
//
// Unlike Cloudflare's original silentspacemarine.com page, this build never
// hosts a game from the browser (-server) and never creates/joins "rooms" via
// a Durable Object API - there is always exactly one already-running native
// dedicated server behind the gateway, so every browser client just connects
// to it directly with "-connect 1".
//
// The websocket URL (and anything else that needs to vary per-deployment) is
// read from config.json, which is generated at container start from
// environment variables - see docker-entrypoint.sh. Nothing here is baked in
// at image build time.

// doom: <code>,<message> - see doom-wasm/README.md "stdout protocol"
const STATUS_MESSAGES = {
    1: "Failed to connect to the game server. Retrying...",
    2: "Connected. Waiting for the game to start...",
    4: "Websocket error. Retrying...",
    5: "Disconnected from the game server.",
    6: "Connection dropped, reconnecting...",
    7: "Failed to connect to the game server. Retrying...",
    9: "Disconnected from the game server.",
    10: null, // game started - clear the status line
    12: null, // another client timed out - not interesting to this player
};

const statusEl = document.getElementById("canvas").nextElementSibling;

function setStatusText(text) {
    if (text === undefined) return;
    statusEl.textContent = text === null ? "" : text;
}

var Module = {
    noInitialRun: true,
    // No preRun here: it fires before config.json has been fetched, so it
    // can't know the WAD's URL yet (DOOM_IWAD_PATH varies per deployment -
    // see docker-entrypoint.sh). The WAD is preloaded explicitly further
    // down, once config.json has resolved, right before callMain().
    canvas: (function () {
        var canvas = document.getElementById("canvas");
        canvas.addEventListener(
            "webglcontextlost",
            function (e) {
                alert("WebGL context lost. You will need to reload the page.");
                e.preventDefault();
            },
            false
        );
        return canvas;
    })(),
    print: (text) => {
        if (typeof text === "string" && text.startsWith("doom: ")) {
            const [code, ...rest] = text.slice(6).split(",");
            const known = STATUS_MESSAGES[parseInt(code, 10)];
            if (known !== undefined) {
                setStatusText(known);
            } else {
                setStatusText(rest.join(",").trim());
            }
        }
        console.log(text);
    },
    printErr: (text) => {
        console.error(text);
    },
    setStatus: (text) => {
        if (text) setStatusText(text);
        console.log(text);
    },
    totalDependencies: 0,
    monitorRunDependencies: function (left) {
        this.totalDependencies = Math.max(this.totalDependencies, left);
        Module.setStatus(left ? "Downloading... (" + (this.totalDependencies - left) + "/" + this.totalDependencies + ")" : "");
    },
    onRuntimeInitialized: () => {
        fetch("config.json", { cache: "no-store" })
            .then((r) => {
                if (!r.ok) throw new Error(`config.json: HTTP ${r.status}`);
                return r.json();
            })
            .then((config) => {
                if (!config.wsUrl) throw new Error("config.json is missing wsUrl");
                if (!config.iwadUrl) throw new Error("config.json is missing iwadUrl");
                // config.playerName is only present when nginx/auth.js's
                // USE_LOGIN_NAME isn't "false" - otherwise the engine falls
                // back to its own random pet name generator, below.

                setStatusText("Downloading IWAD...");

                // The IWAD's virtual filename has to be its real basename (e.g.
                // "DOOM2.WAD"), not an arbitrary/fixed one - d_iwad.c's
                // IdentifyIWADByName() maps well-known IWAD filenames (doom.wad,
                // doom1.wad, doom2.wad, tnt.wad, ...) straight to a gamemission/
                // gamemode, *before* d_main.c's D_IdentifyVersion() ever looks at
                // the WAD's actual lumps. A fixed "doom1.wad" name previously
                // forced every IWAD to be treated as shareware Doom 1 regardless
                // of its real contents (e.g. loading DOOM2.WAD still tried to
                // play E1M1's music and failed with "d_e1m1 not found").
                //
                // The PWAD and DeHackEd patch keep fixed internal names since
                // nothing in the engine identifies them by filename - they're
                // optional and only fetched/loaded if config.pwadUrl/dehUrl is
                // set - see DOOM_PWAD_PATH/DOOM_DEH_PATH in docker-entrypoint.sh.
                const iwadName = config.iwadUrl.split("/").pop();
                const optionalFiles = [
                    config.pwadUrl && { name: "custom.wad", url: config.pwadUrl, args: ["-file", "custom.wad"] },
                    config.dehUrl && { name: "custom.deh", url: config.dehUrl, args: ["-deh", "custom.deh"] },
                ].filter(Boolean);

                let pending = 2 + optionalFiles.length;
                const onOneLoaded = () => {
                    if (--pending > 0) return;

                    // net_client.c only honors -pet if player_name isn't
                    // already set via default.cfg - it isn't, so this is
                    // what ends up on-screen and in netgame chat/kills.
                    // Omitted entirely when there's no playerName, which
                    // leaves the engine to pick its own random pet name.
                    const petArgs = config.playerName ? ["-pet", config.playerName] : [];

                    const args = [
                        "-iwad", iwadName,
                        "-window",
                        "-nogui",
                        "-nomusic",
                        "-config", "default.cfg",
                        "-connect", "1",
                        "-dup", "1",
                        "-wss", config.wsUrl,
                    ].concat(petArgs)
                     .concat(...optionalFiles.map((f) => f.args))
                     .concat(Array.isArray(config.extraArgs) ? config.extraArgs : []);

                    setStatusText("Connecting...");
                    callMain(args);
                };
                const onLoadError = (path) => {
                    setStatusText(`Failed to download ${path}`);
                };

                Module.FS.createPreloadedFile("", iwadName, config.iwadUrl, true, true, onOneLoaded, () => onLoadError(config.iwadUrl));
                Module.FS.createPreloadedFile("", "default.cfg", "default.cfg", true, true, onOneLoaded, () => onLoadError("default.cfg"));
                for (const f of optionalFiles) {
                    Module.FS.createPreloadedFile("", f.name, f.url, true, true, onOneLoaded, () => onLoadError(f.url));
                }
            })
            .catch((err) => {
                console.error(err);
                setStatusText("Failed to load configuration: " + err.message);
            });
    },
};

window.onerror = function () {
    Module.setStatus("Exception thrown, see JavaScript console");
    Module.setStatus = function (text) {
        if (text) Module.printErr("[post-exception status] " + text);
    };
};
