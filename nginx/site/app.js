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
    if (text === null || text === undefined) return;
    statusEl.textContent = text;
}

var Module = {
    noInitialRun: true,
    preRun: () => {
        Module.FS.createPreloadedFile("", "doom1.wad", "doom1.wad", true, true);
        Module.FS.createPreloadedFile("", "default.cfg", "default.cfg", true, true);
    },
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

                const args = [
                    "-iwad", "doom1.wad",
                    "-window",
                    "-nogui",
                    "-nomusic",
                    "-config", "default.cfg",
                    "-connect", "1",
                    "-dup", "1",
                    "-wss", config.wsUrl,
                ].concat(Array.isArray(config.extraArgs) ? config.extraArgs : []);

                setStatusText("Connecting...");
                callMain(args);
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
