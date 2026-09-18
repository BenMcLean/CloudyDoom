// Custom Basic Auth: any username is accepted, but its password must match
// the single shared PASSWORD (env var, passed through by nginx.conf's
// "env PASSWORD;" and read here via process.env). The username itself
// isn't checked against anything - it's only used as the in-game player
// name (see /config.json's "playerName", consumed by app.js's "-pet" arg).
// The "-pet" arg is omitted, falling back to doom-wasm's own random pet
// name generator, whenever USE_LOGIN_NAME (also read from the environment)
// is explicitly "false", or whenever the entered username was left
// blank/whitespace-only.
//
// PASSWORD is optional - leave it unset/blank for a public server (e.g. one
// using a non-commercial IWAD like Freedoom where there's nothing to gate).
// As long as USE_LOGIN_NAME isn't "false", the login prompt still appears
// either way, since it's also how a player picks their in-game name, but
// any password (including none) is accepted once PASSWORD itself is blank.
//
// If PASSWORD is blank AND USE_LOGIN_NAME is "false", there's nothing left
// for the prompt to gate or collect, so auth is skipped entirely - players
// go straight into the game with a random name.
//
// Auth is applied per-location by js_content, since it needs to run before
// static files, /wads/, and the dynamic /config.json are served - see
// nginx.conf.

var MAX_PLAYER_NAME = 29; // MAXPLAYERNAME in net_defs.h is 30, incl. NUL

function useLoginName() {
    return (process.env.USE_LOGIN_NAME || '').toLowerCase() !== 'false';
}

function authRequired() {
    return !!process.env.PASSWORD || useLoginName();
}

function credentials(r) {
    var header = r.headersIn.Authorization;
    if (!header || header.indexOf('Basic ') !== 0) {
        return null;
    }

    var decoded;
    try {
        decoded = Buffer.from(header.slice(6), 'base64').toString();
    } catch (e) {
        return null;
    }

    var sep = decoded.indexOf(':');
    if (sep < 0) {
        return null;
    }

    var user = decoded.slice(0, sep).replace(/[\x00-\x1f\x7f]/g, '').slice(0, MAX_PLAYER_NAME);
    var pass = decoded.slice(sep + 1);

    return { user: user, pass: pass };
}

function isBlank(s) {
    return /^\s*$/.test(s);
}

// Returns { playerName } on success (playerName is null when USE_LOGIN_NAME
// is "false", or when the entered username was blank/whitespace-only - in
// both cases the caller falls back to doom-wasm's own random pet name), or
// null if the request should be rejected.
function authenticate(r) {
    if (!authRequired()) {
        return { playerName: null };
    }

    var creds = credentials(r);
    if (!creds) {
        return null;
    }

    var required = process.env.PASSWORD;
    if (required && creds.pass !== required) {
        return null;
    }

    var playerName = useLoginName() && !isBlank(creds.user) ? creds.user : null;
    return { playerName: playerName };
}

function unauthorized(r) {
    r.headersOut['WWW-Authenticate'] = 'Basic realm="doom.example.com"';
    r.return(401, 'Authorization required\n');
}

// location / - static site assets.
function serve(r) {
    if (!authenticate(r)) {
        unauthorized(r);
        return;
    }
    r.internalRedirect('@content');
}

// location /wads/ - IWAD/PWAD/DEH files on the mounted volume.
function serveWads(r) {
    if (!authenticate(r)) {
        unauthorized(r);
        return;
    }
    r.internalRedirect('@wads');
}

// location = /config.json - regenerated per-request so it can embed the
// requesting client's own player name. The rest of the fields come from
// config.base.json, written once at container start by docker-entrypoint.sh
// (see CONFIG_BASE_PATH there) from the same env vars as before.
function config(r) {
    var auth = authenticate(r);
    if (!auth) {
        unauthorized(r);
        return;
    }

    var fs = require('fs');
    var base;
    try {
        base = JSON.parse(fs.readFileSync('/etc/doom/config.base.json'));
    } catch (e) {
        r.return(500, 'config.base.json missing or invalid: ' + e.message + '\n');
        return;
    }
    if (auth.playerName) {
        base.playerName = auth.playerName;
    }

    r.headersOut['Content-Type'] = 'application/json';
    r.headersOut['Cache-Control'] = 'no-store';
    r.return(200, JSON.stringify(base));
}

export default { serve, serveWads, config };
