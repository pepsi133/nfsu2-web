# Upstream review: runtime/, tests/, docs/ and the other paths

Range: `origin/main` (0b7085c) to `upstream/main` (79c80f5), 364 commits (authors: th0mk 236, Thom 104, ereborDeveloper 21, three others with 1 each). The diff was read with `git diff`/`git show` only. The upstream files were exported for reading to `scratchpad/up/`. Nothing in the checkout changed: `git status --porcelain` is empty and HEAD is still 0b7085c.

## Verdict: merge after the listed fixes (none blocks the merge)

I found no malicious code. Every large change matches its commit message. There are no encoded payloads except an RLE alpha bitmap for an icon, which `tools/photoicon.py` generates and which decodes inside fixed bounds. There are no new network endpoints in the runtime, no time bombs, and no outbound data beyond what the features describe. The new peer-facing parsers (MAPD world-map deltas, crew lists in HELLO/PEERS, SAY quick chat, RACEREP/RACERES, N2CS/N2PL) check their lengths, and I found no out-of-bounds read or write in them. This matters more than usual because `roam_core.c` and `roam_game.c` are also compiled into the native Windows ASI plugin (`win/roam_asi/roam_asi.c:36`), where a bug would not be held by a browser sandbox. The one new weakness is in `racenet.c`. Its "direct car states" feature (N2CS) feeds peer bytes into the game's own joiner message handler. The sender check is "is on the creator's list", and the list is built from anyone who touched UDP 3658, so the check is weak. For a friends-only deployment behind Cloudflare Access this is Low: only authenticated friends are on the virtual LAN, and the effect stays inside the player's own tab (spoofed or frozen cars in a LAN race). MP-1 is unchanged, and the new feature uses the same weak "race peer" definition.

## Findings

| ID | Severity (friends-only) | File:line (upstream/main) | Issue | Evidence | Suggested fix |
|---|---|---|---|---|---|
| RN-1 | Low | runtime/racenet.c:382-394, 405-424; runtime/racenet.c:364-379; runtime/web/net_lan.c:501, 1249-1256 | **Direct car states (N2CS) are injected into the game's joiner handler from any host the creator's list names. That list is any vLAN host that sent one UDP datagram to/from port 3658 in the last 5 s.** | `racenet_list` accepts an N2PL if `from` is among `vlan_race_peers(peers, 4, PEER_MS)`. `race_note()` adds any non-broadcast UDP with sport or dport 3658 (net_lan.c:501), so a stranger can become a "race peer" by sending one datagram. The creator's `list_send` also puts every such race peer on the list it sends to all joiners. `racenet_carspam` then copies up to 0x400 attacker bytes to the guest stack (racenet.c:416) and calls `FN_JOIN_MSG` 0x58E900 (racenet.c:422). The checks are: first byte = 2, slot not ours or the creator's. The result is spoofed or frozen cars for other joiners, plus parsing of attacker bytes by the lifted game parser. Before this change the creator's relay already passed joiner bytes unchanged, so participants could already do this. What is new is that non-participants on the same vLAN can too. A malicious creator can also point each joiner's car-state stream (one datagram up to 0x408 bytes per state, to up to 8 addresses) at arbitrary vLAN hosts. | Track the race peers the game itself connected to (the creator's TCP/UDP session), not any 3658 traffic. Require `in_race()` in `racenet_list`. On the creator, build N2PL only from peers the game's lobby lists. Rate-limit N2CS per source. Or set `NFSU2_RACE_DIRECT=0` until fixed. |
| MP-1 | Medium (unchanged rating from the previous audit) | runtime/racehorn.c:112; runtime/racenet.c:524 | N2HN/N2FS relay: every game re-broadcasts an unmarked datagram to all race peers, with no rate limit and no sender check. | `if (!(m[5] & 2)){ m[5] |= 2; send_all(m, from); }` is identical in both places. The only change is that the receive buffer grew to `8 + 0x400` (racehorn.c:126); the relay still sends `MSG_N` bytes. | As before: relay only on the creator (`is_host()`), only from listed race peers, with a per-source token bucket. |
| SMS-1 | Info (unwanted content, not a code risk) | runtime/sms.c:61-67 (and the per-language copies to ~:150) | After two hours of play the game puts an in-game SMS in the career inbox. It asks players to join "our Discord, linked on the homepage" and to donate at `ko-fi.com/nfsu2xyz` (the upstream operator's public deployment). | Static text. The page triggers it (`IEV_SMS`, sms.c:3), or `NFSU2_SMS`. Commit 655e6c8 "In-game text message after two hours of play" says this. | For a private fork, remove or reword the message, or disable the trigger in web/src (out of scope here). |
| RR-1 | Info (new data to the server) | runtime/roam_game.c:4116-4151; runtime/roam_core.c (RC_MSG_RACEREP/RACERES, `rc_send_racerep`/`rc_send_raceres`) | After each free-roam multiplayer race, each game sends the hub a report: lobby, race, its place, car name/type/rating/kW/kg/top speed, time, and every racer's player id, time and distance. The server logs it for anti-cheat and balancing. | Hub only (`s->conf.hub_ip`), fields range-checked on encode and decode (`racerep_ok`/`raceres_ok`). docs/web/VPS.md ("In races") documents it. | None needed. Note it in the friends' privacy expectations if relevant. |
| CR-1 | Info | runtime/roam_core.c:1214-1217 | Crew hashes (FNV-1a of crew names) go to the hub. Without a hub (pure LAN/discovery mode) they also go to peers whose HELLO reads crews. They are never in the broadcast beacon. | `if (crews && (!to || !s->conf.hub_ip))`. With a hub the server sends only per-peer crew bits (PEERS crew marks), so no player learns another's crews. | None. The design is careful; the no-hub mode leaks only short-name hashes to LAN peers. |
| DOC-1 | Low (operator choice) | docs/web/VPS.md:896-986 | New optional deployment "Cloudflare's proxy, straight to the server": no cloudflared tunnel, origin port 28443 open to all Cloudflare IP ranges, authenticated with Cloudflare's **Global** (shared by all accounts) Authenticated Origin Pulls certificate. For an owner who relies on Cloudflare Access, this makes Access-bypass resistance depend on the server's SNI check and on "only Enterprise can set SNI". The doc says so at :983-987. | Text at :915-917 ("shared by every Cloudflare account") and :983-986. The server accepts only Cloudflare's CA (built in), not a zone-level certificate. | Stay on the cloudflared tunnel (the current setup). If switching, ask upstream for zone-level AOP support, or have the server verify the `Cf-Access-Jwt-Assertion` header. |
| DOC-2 | Low (player-side advice) | docs/web/PLAYING.md:693, 695, 697, 698 | Players are told to turn on `chrome://flags/#enable-unsafe-webgpu` (Linux, Windows on ARM, Android) to get past Chrome's WebGPU blocklist. That flag applies to every site. | New rows. `origin/main` had 0 occurrences. | Fine for friends who understand it. Optionally add a note to turn it off again, or to use a separate browser profile. |
| MV-1 | Info | runtime/movie.c:128-145 | New host imports `movie_open/decode/close`. Sizes come from the movie file header (`w`, `h`); `ys * (h + 96)` can wrap for absurd sizes, after which the JS decoder writes planes at computed addresses. | movie.c:133. The input is operator-supplied AV1 movie files from the game folder (tools/movies_av1.py), not peer data. | Clamp `w`, `h` (for example to 4096) before the arithmetic. JS bounds belong to the web/src reviewer. |

Things I verified as safe (no finding):
- **MAPD decode** (roam_core.c:588-603). Each entry's key needs `r_have(len+2)`, the total is capped at 1152 bytes, and `part < nparts ≤ 16`. `map_part` (:1069) copies into `part*1152` and the merge is capped at `RC_MAP_MAX`. MAPD/LOBBIES/PEERS are taken only from the configured hub ip:port (:1324).
- **HELLO and PEERS crew lists.** Counts are checked to be ≤ 4 before use, `hub_crews` is filled by `c < n_mine ≤ 4`, and `rc_decode` memsets the message first (:489).
- **SAY.** Taken only from established peers, the inbox is capped at 16 and source rate limits apply. The phrase number (0-255) is forwarded to the page unchecked, by design.
- **JSON to the page.** `js_val` escapes quotes and backslashes and strips control bytes. The peer names in `say_page`/`js_results` go through it.
- **RACERES/RACEREP decode** (n ≤ 6, ranges checked).
- **Lobby `away_s`** is clamped to 30.
- **Other parsers.** `crews_parse`, `crew_rgb_parse`, `roam_plat_room` (63 bytes plus NUL), the `olfilter.c` stream walker, the `fileio.c` descriptor cache, the `garage.c` GARAGE file (local save, fixed-size reads), `texrep_web.c` pack parsing (local pack with validated counts and offsets), the `radio.c` rings (masked indices, `have` bounded) and the `photo_icon.h` RLE decode (bounded loop).

## MP-1 status

**Unchanged.** racehorn.c:112 and racenet.c:524 still relay any unmarked N2HN/N2FS from any "race peer" to all race peers, with no rate limit and no sender check. Relevant to it: "race peer" (`race_note`, net_lan.c:501) still means "any vLAN host that exchanged a UDP datagram on port 3658 in the last 5 s". The new N2PL/N2CS feature (RN-1) reuses that definition as its trust check, so the same weakness now also controls injection of car-state messages. It is not worse in severity for a friends-only deployment, but the attack surface behind the weak check is larger.

## Other paths outside the excluded list (`git diff --stat`)

- `.gitignore` (+2: ignores `/mw/`): read. Benign.
- `README.md` (+12/-5: languages, credits): read. Benign.
- `web/build.mjs` (+9/-2: `.png` as a data URL loader, copies `src/app/lang/*.json` to `dist/lang` after JSON.parse/stringify): read. Benign.
- `win/roam_asi/NFSU2FreeRoam.ini`, `roam_asi.c`, `roam_fp.h`, `roam_host_win.h`, `roam_libc.c` (crew options, function fingerprints, an added `strstr`): read. Benign. The `strstr` is a correct naive implementation.
- `link.sh` and `web/build.sh` are in the excluded list (root/web shell scripts), so I did not review them.

## Coverage

- **Read every changed line:** runtime/roam_core.c and roam_core.h, runtime/roam_game.c (all 3,525 diff lines), runtime/racenet.c, runtime/racehorn.c, runtime/mprace.c and mprace.h, runtime/web/net_proto.h, runtime/web/roam_web.c, runtime/roam_plat.h, runtime/roam_host.h, runtime/roam.c, runtime/roam_bsd.c, runtime/web/status_web.c and status_proto.h, runtime/web/radio_proto.h, runtime/movie.c (whole file), runtime/olfilter.c (whole file), runtime/fileio.c, runtime/winsock.c, runtime/discord.c, runtime/debug.c, runtime/lifecycle.c, runtime/web/main_web.c, runtime/web/null_platform.c, runtime/carsfx.c, runtime/names.h, plus the other paths listed above.
- **Read in part (the parts that do I/O, take input or parse):**
  - runtime/photo.c (header, page input, gcall)
  - runtime/radio.c (ring and offer handling)
  - runtime/garage.c (GARAGE file read and write, use of its fields)
  - runtime/sms.c (source of the text, trigger)
  - runtime/web/texrep_web.c (pack loading)
  - runtime/web/photo_icon.h (format and its decoder)
  - runtime/win32_ext.c (code lines of the diff)
- **Grep-scanned only:** I searched the whole runtime diff for URLs, `system`/`popen`/`exec`, `fopen`, sockets, `getenv`, base64 and dates, and for new `import_module` imports (the only new ones are the three movie imports). That leaves these changed files without a line-by-line read:
  - overrides.c, language.c, drift.c, framerate.c, dinput_pad.c, com.c, hornmenu.c, menusize.c, optslider.c, powerunits.c, tonemenu.c, tunegraph.c, regional.c, hiddenraces.c, carshadow.c, sndlead.c, watchdog.c, autotest.c, bundle.m, metal.m, gamepad.*, widescreen.c, dinput_kbd.c
  - runtime/web/audio_web.c, gpu_web.c and gpu_proto.h, input_web.c and input_proto.h (only partly read), audio_proto.h
  - None of these parse peer data, as far as the grep and their headers show.
- **tests/:** I grep-scanned all of it for network fetches, process spawning and paths outside the repo. The only URLs are `http://localhost:<port>` in comments describing `web/tools/roam-pair.mjs` runs, and the `--fetch`/`--seed` mentions are arguments to that local tool. `tests/run_suite.sh` only adds four suite rows. I did not read the new C unit tests (objtable_unit.c, radio_unit.c, watchdog_unit.c, roam_unit.c additions) line by line; the grep found no system calls or I/O outside the repo in them.
- **docs/:** I grep-scanned the VPS.md, PLAYING.md and DESIGN.md additions for ports, root, curl/sh, headers, CSP, firewall and Cloudflare, and read VPS.md:896-990 in full. I found no `curl | sh` from new domains and no instruction to disable security headers. VPS.md uses `ssh root@<vps>`/`rsync root@` throughout; this was already the style at `origin/main`.

## Open questions

1. Does the server's virtual LAN switch put all Online/LAN players of the deployment on one network? That decides who can reach UDP 3658 on another player for RN-1 and MP-1. The switch is web/server-rs, another reviewer's scope.
2. Does the switch stamp `src_ip` itself, so a page cannot spoof another vLAN address? RN-1's "only from the creator" check assumes it does. This is also web/server-rs.
3. Does the page (web/src) bound the quick-chat phrase number and the movie decoder's writes into module memory (the `movie_decode` y/u/v pointers and strides)? These are out of my scope, so not verified.
4. `web/build.mjs` is not in the exclusion list, but `web/*.sh` is. I reviewed it anyway; please confirm it was meant to be in my scope.

## Changes outside the scratchpad

None. I wrote only under `/tmp/claude-0/-home-user-nfsu2-web/8bef6790-e6d9-51a2-a8b2-5e37e280d48f/scratchpad/` (this report, the exported upstream files under `scratchpad/up/`, and saved diffs).
