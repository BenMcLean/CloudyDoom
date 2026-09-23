"use strict";

const dgram = require("dgram");
const { WebSocketServer } = require("ws");

// --- Config, all overridable from docker-compose ---
const WS_PORT = parseInt(process.env.WS_PORT || "2343", 10);
const DOOM_SERVER_HOST = process.env.DOOM_SERVER_HOST;
const DOOM_SERVER_PORT = parseInt(process.env.DOOM_SERVER_PORT || "2342", 10);
// Per-packet traffic logging is off by default - doom's netcode sends
// packets every game tic (35/sec/client), which floods logs with no
// rotation configured. Set DEBUG_PACKETS=true to re-enable for debugging.
const DEBUG_PACKETS = process.env.DEBUG_PACKETS === "true";

if (!DOOM_SERVER_HOST) {
    console.error("DOOM_SERVER_HOST must be set, e.g. doom-server");
    process.exit(1);
}

// doom-wasm's net_websockets.c wire format (see src/net_websockets.c and
// src/d_loop.c in the vendored doom-wasm subtree):
//
//   browser -> gateway (outbound, what NET_Websockets_SendPacket writes):
//     [to:uint32 LE][from:uint32 LE][doom netcode payload]
//
//   gateway -> browser (inbound, what WebSocketMessage reads):
//     [from:uint32 LE][doom netcode payload]        (note: no "to" field)
//
// A "-connect" client (every browser client in this stack - there is no
// browser-hosted "-server" mode here) always addresses "to" as the literal
// id 1, and picks itself a random "from" instanceUID (see d_loop.c:440).
// The real dedicated server has no notion of this framing at all - it's a
// stock Chocolate Doom UDP netcode server - so every packet forwarded to it
// must have the 8-byte header stripped, and every reply must have a 4-byte
// header re-added with from=1 (the id the browser client already resolved
// as "the server" - see NET_Websockets_ResolveAddress in net_websockets.c).
const HEADER_OUT_LEN = 8; // to(4) + from(4)
const HEADER_IN_LEN = 4; // from(4)
const SERVER_ID = 1;

const wss = new WebSocketServer({ port: WS_PORT });
console.log(`doom gateway: listening for websockets on :${WS_PORT}, forwarding to ${DOOM_SERVER_HOST}:${DOOM_SERVER_PORT}/udp`);

let nextClientId = 1;

wss.on("connection", (ws, req) => {
    const clientId = nextClientId++;
    const remote = req.socket.remoteAddress;
    let instanceUID = null;

    // Chocolate Doom's dedicated server tells clients apart by UDP source
    // (ip, port) - exactly like it would for real UDP clients - so each
    // browser client gets its own dedicated UDP socket for the lifetime of
    // its websocket connection.
    const udpSocket = dgram.createSocket("udp4");

    udpSocket.on("message", (payload) => {
        if (DEBUG_PACKETS) console.log(`doom gateway: udp -> ws, client ${clientId} (uid=${instanceUID}), ${payload.length} bytes, readyState=${ws.readyState}`);
        if (ws.readyState !== ws.OPEN) return;
        const frame = Buffer.allocUnsafe(HEADER_IN_LEN + payload.length);
        frame.writeUInt32LE(SERVER_ID, 0);
        payload.copy(frame, HEADER_IN_LEN);
        ws.send(frame);
    });

    udpSocket.on("error", (err) => {
        console.error(`doom gateway: udp socket error for client ${clientId} (uid=${instanceUID}):`, err.message);
        ws.close();
    });

    ws.on("message", (data) => {
        if (!Buffer.isBuffer(data) || data.length < HEADER_OUT_LEN) {
            return; // malformed frame, drop it
        }

        if (instanceUID === null) {
            instanceUID = data.readUInt32LE(4);
            console.log(`doom gateway: client ${clientId} (uid=${instanceUID}) from ${remote} connected`);
        }

        const payload = data.subarray(HEADER_OUT_LEN);
        if (DEBUG_PACKETS) console.log(`doom gateway: ws -> udp, client ${clientId} (uid=${instanceUID}), ${payload.length} bytes`);
        udpSocket.send(payload, DOOM_SERVER_PORT, DOOM_SERVER_HOST, (err) => {
            if (err) console.error(`doom gateway: udp send error for client ${clientId} (uid=${instanceUID}):`, err.message);
        });
    });

    ws.on("close", () => {
        console.log(`doom gateway: client ${clientId} (uid=${instanceUID}) disconnected`);
        udpSocket.close();
    });

    ws.on("error", (err) => {
        console.error(`doom gateway: websocket error for client ${clientId} (uid=${instanceUID}):`, err.message);
        udpSocket.close();
    });
});

function shutdown() {
    console.log("doom gateway: shutting down");
    wss.close(() => process.exit(0));
    for (const ws of wss.clients) ws.terminate();
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
