# Upstream review: server, supply chain, CI, deploy, discord-bot

Range: origin/main 0b7085c .. upstream/main 79c80f5 (364 commits, fast-forward: origin/main is an ancestor of upstream/main).
Scope: web/server-rs/**, .github/**, web/deploy/**, Dockerfiles and .dockerignore files, discord-bot/**, package.json, package-lock.json, Cargo.lock and requirements.txt changes, root and web/*.sh shell scripts, tools/**.

## Verdict: merge after listed fixes (none blocking; all are deployment-config choices)

I found no malware, backdoor, obfuscated code, hard-coded credential, telemetry to third parties or route that skips authentication in the scoped changes. The server's only new outbound connection is the opt-in Cloudflare Turnstile siteverify call. It is off unless both NFSU2_TURNSTILE_SITE and NFSU2_TURNSTILE_SECRET are set, and it sends only the secret and the widget's token. Game data is still served only to the client that asks for it. The new code keeps brotli-compressed copies of game blocks in the private /state volume. The new admin interface (kick/ban/who) is a 0600 Unix socket in the state folder, not an HTTP route. The two new public routes (/names, /seen) are rate-limited or harmless and hand out no game data. The new dependency set is small: one crate from crates.io and three npm packages from the npm registry, plus their transitive dependencies. None comes from git or a URL, and none has an install script. Workspace-wide, cargo audit and npm audit report nothing new. Before merging and deploying, apply the Low items below: don't set `--http-socket` to a file path (or use the abstract name), consider dropping `cgroup: host`, and disable or SHA-pin the new image-bot workflow. SC-1 (Actions not SHA-pinned) and the unchecked Zig download remain open from the previous audit.

## Findings

| ID | Severity | file:line (upstream/main) | Issue | Evidence | Suggested fix |
|---|---|---|---|---|---|
| U-1 | Low | web/server-rs/src/app/run.rs:87-101, :454; crates/http/src/lib.rs:535 | New `--http-socket` / `NFSU2_HTTP_SOCKET` listener: every connection on it counts as coming from 127.0.0.1, a trusted proxy. So whoever can connect can set CF-Connecting-IP / X-Forwarded-For, and the server uses that header for rate limits and bans. A socket given as a file path is chmod 0666 (run.rs:99), so any local user or container sharing that path can do this. The abstract name `@nfsu2-http` (compose.tunnel.yml:54) reaches only processes in the container's network namespace, the same exposure 127.0.0.1:8080 already had. | `serve_unix(listener, ([127, 0, 0, 1], 0).into(), ...)`; `set_permissions(at, from_mode(0o666))` | Off by default except in compose.tunnel.yml. If you use it, use the abstract `@name` form, or remove NFSU2_HTTP_SOCKET if you use plain TCP. Cloudflare Access does not affect this: it is a local-host trust issue. |
| U-2 | Low | web/deploy/compose.yml:67 | `cgroup: host` puts the server container in the host's cgroup namespace (read-only view), so it can read the host's whole cgroup tree (other services' names and usage). This loosens container isolation a little. It is used only to read the slice's CPU quota (crates/util/src/cpu.rs QuotaBusy). | `cgroup: host` | Remove the line for a small friends-only VM. The hub then falls back to its workers' busy time (run.rs logs "CPU quota" lines only when one is found). |
| U-3 | Low (continues SC-1) | .github/workflows/image-bot.yml:20-35 | New workflow with tag-pinned third-party actions (`docker/*@v3/v5/v6`, `actions/checkout@v5`) and `packages: write`. It runs on push to main touching discord-bot/** and on workflow_dispatch. Triggers are safe: no pull_request_target, no secrets beyond GITHUB_TOKEN. In the fork it would build and publish `ghcr.io/<fork>-bot`. | lines 4-11 (triggers, permissions), 20-43 | Disable the workflow in the fork (you don't run the bot), or SHA-pin the actions as SC-1 asks for the others. |
| U-4 | Low (pre-existing) | web/server-rs/Dockerfile:39 | Zig is still downloaded with curl and no checksum. Unchanged by this range, still open. | `curl -sSfL "https://ziglang.org/download/$ZIG/..." \| tar -xJ` | Same as before: check its sha256 or minisign signature. |
| U-5 | Info | discord-bot/Dockerfile:4; discord-bot/compose.yml:5 | New separate bot image: `node:22-alpine` with no digest, and compose pulls upstream's `ghcr.io/th0mk/nfsu2-web-bot:latest`, a tag upstream can change. It is not part of the game-server image or web/deploy compose files. | `FROM node:22-alpine`, `image: ghcr.io/th0mk/nfsu2-web-bot:latest` | Don't deploy it. If you ever do, build it yourself and pin the digest. |
| U-6 | Info | web/server-rs/src/app/turnstile.rs:16, :34, :75 | The only new runtime outbound connection: an HTTPS POST to challenges.cloudflare.com/turnstile/v0/siteverify with `secret` and the widget's response. It verifies against built-in webpki roots, reads at most 64 KB and gives up after 10 s. NFSU2_TURNSTILE_VERIFY can point it at another URL, so whoever controls the environment controls where the secret goes. When enabled, the CSP adds challenges.cloudflare.com to script-src and frame-src only (crates/headers/src/lib.rs CSP_TURNSTILE; mod.rs:300). | `VERIFY`, `from_env()`, `TcpStream::connect((host, port))` | Leave NFSU2_TURNSTILE_* unset (default: off, compose.yml passes empty values). |
| U-7 | Info | web/server-rs/src/app/mod.rs:725-737; src/app/days.rs:1-12 | New `/seen?at=page\|play&id=` counter, unauthenticated and not rate-limited. It stores only 64-bit HMACs of page ids under a fresh random key each day, in a set capped at 1,000,000 per kind (about 8 MB each). Nothing leaves the server. A script could inflate the counts or fill the cap. | `self.days.seen(&id, what, now_ms())`; `MAX_A_DAY` | Acceptable behind Cloudflare Access. |
| U-8 | Info | web/server-rs/src/app/names.rs:88-93 | New `/names` (claimed names) route. It exists only with vault on, refuses a foreign Origin (`own_page`) or a cross-site Sec-Fetch-Site, needs a vault bearer token to POST, and is rate-limited (READ 120/2s, CLAIM 10 a day). No auth bypass found. | `if !self.own_page(q) \|\| !site_ok { 403 }` | None. |
| U-9 | Info | web/server-rs/src/app/control.rs:1-24, :75-90; web/deploy/nfsu2 | New operator control socket `control.sock` in the state folder, chmod 0600, reachable only via `docker compose exec ... nfsu2-server ctl`. It can list players (virtual address, name), kick, ban, unclaim. It is not on the network. | `set_permissions(&path, from_mode(0o600))` | None. |
| U-10 | Info | crates/util/src/logfile.rs:1-5, :40-50 | Console lines now also go to /state/logs/<day>.log (0600, 0700 directory), gzipped and kept 30 days. They hold player names, virtual addresses and cheat/ban lines, not real IPs unless `--access-log` is on. `web/deploy/nfsu2 logs` streams them to stdout only. | `mode(0o600)`, `DAYS_KEPT = 30` | Factor this into backups and the privacy note. |
| U-11 | Info | web/server-rs/src/app/kept.rs:1-20, :386-416 | Brotli-11 copies of game-data blocks are now kept in /state/blocks (up to 16 GB, 0700/0600). Game files are opened with O_NOFOLLOW, and copies are served only on /data-blocks/v2 requests for the same file. So copyrighted game data now also sits in the state volume and in any backup of it. | `MAX_BYTES: 16 << 30`, `custom_flags(libc::O_NOFOLLOW)` | Set NFSU2_COMPRESS_THREADS=0 if you don't want copies in /state. |
| U-12 | Info | crates/roam/src/hub.rs:1198-1201 | A client's hello `block` list (≤32 names, printable ASCII, ≤24 chars, crates/lan/src/members.rs) is logged with `{:?}` on every hello, without the per-client log limiter. That is log noise, not injection. | `(self.log)(&format!("[roam] {} blocks {}", ...))` | None needed. |
| U-13 | Info (pre-existing) | web/server-rs/Cargo.lock (zstd 0.13.3, zstd-safe 7.3.0) | cargo audit: 3 vulnerabilities (RUSTSEC-2026-0391, -0398, -0403) and 11 unsound/unmaintained warnings. These are exactly the same IDs as on origin/main. The server only compresses public game data with fresh contexts (blocks.rs:94, kept.rs:398); its only decompression is in tests. | cargo audit output in this folder (cargo-audit-upstream.txt) | Bump zstd to >=0.14.3 (zstd-safe >=8.2) in a separate change. |

Limits that are unchanged or stricter: WS_MAX_PAYLOAD stays 64 KB (mod.rs). The game-file path guard (files.rs) is unchanged. The vault cap is now per-byte instead of per-keyphrase (crates/vault/src/lib.rs:483-499), which is stricter. The new LAN waiting line is capped by `max_waiting` and has a text rate limit (crates/lan/src/queue.rs:145, :323). Raised: max peers 4000 to 7000 (options.rs, Dockerfile ENV), TCP listen backlog 511 to 4096 (crates/http/src/lib.rs:515), Caddy max_conns 55900. These are capacity changes, not weaknesses. The Dockerfile still runs as uid 1000, and compose keeps read_only, cap_drop ALL and no-new-privileges.

## New dependencies

Rust (web/server-rs/Cargo.lock, all from crates.io registry unless path):
- webpki-roots 1.0.11 (crates.io, checksum f5f280bb…; used only by turnstile.rs)
- serde_derive: already in the lock, now also a dependency of serde. Workspace crates gain `serde`/`flate2` (both already present).
- nfsu2-bans 0.1.0, nfsu2-claims 0.1.0 (path crates, crates/bans, crates/claims)
- No new build.rs, no git or URL sources. web/server-rs/Dockerfile still builds with `--locked`.

npm (discord-bot/package-lock.json, new; 64 packages, all `resolved` from https://registry.npmjs.org/, none with `hasInstallScript`):
- Direct: @anthropic-ai/sdk 1.3.0, discord.js 14.27.0, sharp 0.35.5 (prebuilt @img/* binaries)
- Transitive top level: @discordjs/{builders 1.14.1, collection 1.5.3, formatters 0.6.2, rest 2.6.3, util 1.2.0, ws 1.2.3}, @sapphire/{async-queue, shapeshift, snowflake}, discord-api-types 0.38.57, undici 6.29.1, ws 8.22.0, lodash 4.18.1, semver 7.8.5, standardwebhooks 1.1.1, json-schema-to-ts 3.1.1, @opentelemetry/api 1.10.0, others.
- `npm audit --package-lock-only`: found 0 vulnerabilities.
- web/package.json and web/package-lock.json: unchanged in this range. No requirements.txt changes.

## New outbound network destinations

Game server (runtime):
- https://challenges.cloudflare.com/turnstile/v0/siteverify, only with both Turnstile env vars set (turnstile.rs:16). Its browser-side widget script also comes from challenges.cloudflare.com then.

Deploy scripts (operator-run, not the server):
- https://www.cloudflare.com/ips-v4 and ips-v6 (web/deploy/cloudflare-only.sh:20), only for compose.origin.yml's nftables allow-list.
- release.sh: no new destination. It writes module/release.json locally (web/deploy/release.sh:84-93).

discord-bot (separate image, not deployed by web/deploy):
- Discord gateway/API and cdn attachments (discord.js; bot.mjs:914, archive.mjs:76 fetch attachment URLs from messages)
- api.anthropic.com (@anthropic-ai/sdk; key from ANTHROPIC_API_KEY env)
- github.com clone/fetch of BOT_REPO (repo.mjs:54-65; SSH host key pinned in Dockerfile)
- https://nfsu2.xyz/game.json (repo.mjs:93, BOT_LIVE_URL default) for the live version

## discord-bot (criterion 4)

It is a Discord forum helper. It reads forum and general channels, runs LLM "looks" (Claude via @anthropic-ai/sdk) with read-only tools over its own git clone (tools.mjs: git grep/log/show via execFile with argument arrays, path checks against `..`/.git/symlinks at tools.mjs:78-90) and posts replies and staff reports. Secrets: DISCORD_TOKEN (bot.mjs:27, required), ANTHROPIC_API_KEY (SDK default), optionally an SSH deploy key mounted at /keys/deploy_key. It mounts /srv/nfsu2/module read-only to read nfsu2.json/release.json. It is not in the game server image (web/server-rs/Dockerfile copies only web/dist and the binary) and not in any web/deploy compose file. It has its own Dockerfile, compose and image-bot workflow. It never talks to the game server's HTTP routes or state. Its dry run (BOT_DRY_RUN) and budget cap are local. For a friends-only deployment, ignore it and disable image-bot.yml.

## Game data (criterion 5)

/data-blocks now needs the `/v2` prefix (mod.rs:576-580) and can answer from kept brotli copies (blocks.rs send_kept). Responses still go only to the requesting connection. No new code path sends game files or blocks elsewhere. The kept copies are written only under /state/blocks. Turnstile's request body holds only the secret and the token, and the bot reads only nfsu2.json/release.json from the module folder.

## Commit metadata

Authors: th0mk/Thom (upstream owner, 338 commits plus 2 GitHub web commits), ereborDeveloper (21), tacyarg (1), Samet Samyeli (1), Евгений Буйволов (1). The external commits in scope:
- tacyarg 8651470 "block players by name": lan/roam/util host.rs. I read it: benign.
- ereborDeveloper: link.sh/web/build.sh source lists only (new C module names).
- Samet: tools/langpacks.py and tools/texpacks.py (offline asset tools, no network).
- Евгений: nothing in scope.
The range has merges (PRs #10, #14, #39).

## Coverage

Every changed line read: .github/workflows/image-bot.yml; web/server-rs/Dockerfile; discord-bot/Dockerfile, .dockerignore, .gitignore, compose.yml, package.json; all Cargo.toml; Cargo.lock diff; all web/deploy/* diffs (cloudflare-only.sh, compose.*.yml, nfsu2, nfsu2-cloudflare-only.service, nfsu2.slice, release.sh); link.sh, web/build.sh, tools/genstamp.sh, web/tools/gencheck.sh, tests/run_suite.sh; src/app/turnstile.rs, names.rs (handler part), control.rs (module doc, socket, command parsing up to ban), ctl.rs, main.rs/options.rs diffs, mod.rs diff (routes, headers, /players, /seen), run.rs diff (first ~400 lines: listeners, logfile, bans, claims, days, sweeps), crates/http/src diff, crates/headers diff, crates/vault/src/lib.rs diff, src/app/vault.rs, url.rs, blocks.rs/manifest.rs/lan.rs diffs (non-comment lines), kept.rs header and I/O lines, days.rs (first 120 lines), crates/util/src/logfile.rs (first 80 lines), tacyarg's commit.

Skimmed by grep (no full read): the rest of the crates diff (lan compact/fpred/queue/members/mix/impair, roam hub/watch/results/wire/jumps, online buddy/lobby/races/stats, names, claims, bans lib.rs, util cpu.rs/counter.rs), grepped for sockets, process spawns, env reads, file modes, unsafe, base64/large blobs, include_bytes, /proc and /sys, and new `const` limits; roamload (a load-testing client, not in the image); discord-bot/*.mjs (grepped for fetch, URLs, env, execFile; read the CFG block, tools.mjs path guard, repo.mjs git calls, archive.mjs download); discord-bot README; tools/*.py (grepped for network, subprocess, eval/pickle: only local ffmpeg/lame calls); tests (grepped for network, binaries, long encoded strings: only 127.0.0.1 test servers and an `#[ignore]` NFSU2_CAPTURE reader; no binary files in the diff).

Not covered: bans/lib.rs and claims/lib.rs logic in detail (only grepped: 0600 files, HMAC under bans.key); online buddy/lobby protocol parsing correctness; the end of run.rs; discord-bot prompt files (system.md, knowledge.md, the LLM prompt-injection surface); markdown docs.

## Tools

- cargo-audit 0.22.2 installed into the scratchpad (cargo install --locked --root ...). It reports the same 3 vulnerabilities and 11 warnings on origin/main and upstream/main; none is new.
- npm audit --package-lock-only on discord-bot/package-lock.json: 0 vulnerabilities. No other package-lock.json changed.

## Open questions

- I checked "trusted proxy and IP handling" only for the new Unix-socket path and the Origin/Host check of /names. Whether `--trusted-proxies cloudflare` plus Authenticated Origin Pulls (compose.origin.yml) fits a Cloudflare Access setup depends on which compose variant you deploy. Which one is it?
- Is the bot ever meant to run for the fork? I assumed not.

## Changes outside the scratchpad

None. No git checkout, switch, reset or merge was run. `git status` is clean and HEAD is 0b7085c. cargo-audit was installed under the scratchpad (cargo-audit-bin); cargo's registry cache in ~/.cargo was populated by that install.
