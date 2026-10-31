# Upstream review: web client (origin/main 0b7085c..upstream/main 79c80f5)

Scope: `git diff origin/main upstream/main -- web/src web/tools web/test web/index.html web/*.json web/*.ts web/*.mjs`, plus the binary files added anywhere. 364 commits; 159 files in scope, about 35,000 added lines, about 19,000 of them translation JSON. Read-only: I used git diff, show, grep and log only. I extracted the binaries to the scratchpad and looked at them there.

## Verdict: merge after the listed fixes (one config check, one small hardening)

I found no malware, no analytics or ad code, no obfuscated or encoded payloads, and no build-time downloads. Nothing sends plaintext saves or the passphrase off the device. Every `fetch`, WebSocket and worker message still goes to the page's own origin. The one new third-party resource is Cloudflare Turnstile's script (`challenges.cloudflare.com`). The page loads it only when the server hands it a site key, and the server does that only when `NFSU2_TURNSTILE_SITE` and `NFSU2_TURNSTILE_SECRET` are both set. Keep them unset for a friends-only deployment and the page stays same-origin.

What the merge does add is first-party data the server receives:
- a persistent per-browser ID, kept in both localStorage and OPFS, sent for daily counts (`/seen`) and in the `/lan` hello;
- the cloud-save token, now also sent to `/names` and in the `/lan` hello;
- automatic name claims.

All of it goes only to the owner's own server. The passphrase can now be saved in the browser's password manager, but only after the browser's own "Save password?" prompt. Key derivation, the cipher and the keyphrase entropy are unchanged. Cross-player XSS: everything other players send (names, chat, lobby) is written with `textContent`, and translations cannot inject markup.

## Findings

| ID | Severity | File:line (upstream/main) | Issue | Evidence | Suggested fix |
|----|----------|---------------------------|-------|----------|---------------|
| W1 | Low (Info if Turnstile stays off) | web/src/app/claim.ts:120-128; CSP in web/server-rs/crates/headers/src/lib.rs:70-75 (other reviewer's scope, cited for context) | New third-party script: Cloudflare Turnstile. When it is on, the CSP allows `https://challenges.cloudflare.com` in script-src and frame-src. That script runs in the page's origin and could read localStorage, which holds the cloud-save passphrase link in plaintext. | `s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit'`; `load()` is called only from `turnstile()`, which runs only when `/names` returns `captcha` (claim-ui.ts:190-192, 277). Server side: run.rs:214 says "off without its two keys", and turnstile.rs:3-5 says the same. | Leave `NFSU2_TURNSTILE_SITE`/`NFSU2_TURNSTILE_SECRET` unset (behind Cloudflare Access, the check adds nothing). Optional: delete the loader in a fork. |
| W2 | Low (privacy, first-party) | web/src/app/page-id.ts:25-58, 60-74; web/src/net/index.ts:576-578; web/src/app/shell.ts:681 | A persistent 128-bit browser ID is stored in localStorage and in an OPFS file at the origin root ("the harder one to clear alone"). Each store restores the other, so clearing one store does not reset the ID. It is sent as `GET /seen?at=page|play&id=…` on every page load and Play, and as `id`/`was` in the `/lan` WebSocket hello (for bans and daily counts). | `fetch(\`/seen?at=${at}&id=${encodeURIComponent(id)}\`, …keepalive: true)`; `...(this.o.id ? { id: this.o.id } : {}), ...(… { was: this.o.was } …)` | Acceptable for a private server you run yourself. If you don't want per-browser daily counts, drop the `seen()` calls (shell.ts:681 and the `seen('page')` in `boot()`). |
| W3 | Low | web/src/app/vault.ts:358; web/src/app/claim.ts:79-82, 98-103; web/src/net/index.ts:578; web/src/app/claim-ui.ts:259-261, 273-283 | The cloud-save bearer token (the half of the PBKDF2 output that is not the AES key) now also goes as `Authorization: Bearer` to `/names` and as `claim` in the `/lan` hello. Before, only `/vault` received it. With it, the server links a player name to a vault entry. Anyone who captures it can read the ciphertext, overwrite it or delete it, but cannot decrypt it. At Play, a player who has a keyphrase claims a free name without asking (`claimQuietly`). | `async token() { … (await this.keysFor(this.link.phrase)).token }`; `t ? { authorization: \`Bearer ${t}\` } : {}`; `...(this.o.claim ? { claim: this.o.claim } : {})` | Accept: everything stays same-origin and TLS-protected. Make sure server or Cloudflare logs never record request headers or WebSocket payloads (server-rs reviewer). |
| W4 | Low (privacy trade-off, needs user consent) | web/src/app/pwkeep.ts:32-46; web/src/app/vault-ui.ts:274-316 | Commit fd094f5: the passphrase is offered to Chrome or Edge's password manager through `navigator.credentials.store(PasswordCredential)`. The browser's "Save password?" prompt controls this. If accepted, it may sync to the user's Google or Microsoft account. On a fresh browser with no profile, the page asks the browser for the stored credential (the browser's chooser the first time, `silent` after that). It uses the credential only if `readPhrase` accepts it as a valid 8-word phrase, and loads the saves only after a confirmation dialog. Only a 32-bit FNV-1a "mark" of the phrase is kept in localStorage (pwkeep.ts:49-53). That leaks nothing beyond the plaintext link that localStorage already holds. | `navigator.credentials.store(new P({ id: ID, password: phrase }))`; `navigator.credentials.get({ password: true, mediation: ask ? 'optional' : 'silent' })`; vault-ui.ts:284-286 discards anything that isn't a valid phrase. | No change needed. Tell friends that "Save password" stores the cloud-save key in their browser account. |
| W5 | Low (hardening) | web/index.html:202-215; web/src/app/vault-ui.ts:196 | The passphrase box is now a real `<form>` with `name="username"`/`name="password"` fields, a `type="submit"` Load button, and no `action`/`method`. Only the JS `onsubmit` with `preventDefault()` stops a native GET submit. If that handler were ever missing (a script error before `VaultPanel` is built, or a future refactor), Enter or Load would navigate to `/?username=Cloud+saves&password=nfsu2-xyz-…`. That would put the passphrase in the URL, history, and server or Cloudflare logs. Today `#vault` stays `hidden` until `start()`, which runs after the handler is attached, so I did not see this happen. | `<form class="vault-row" id="vault-form">` … `<button type="submit" … id="vault-load">`; `this.$<HTMLFormElement>('#vault-form').onsubmit = e => { e.preventDefault(); … }` | Add `method="post"` to the form. A fallback submit then sends the phrase in a request body, not in a URL. An inline `onsubmit` attribute is not an option: the CSP blocks it. |
| W6 | Info | web/index.html:5 | The viewport now sets `maximum-scale=1, user-scalable=no`, which disables pinch-zoom. This is an accessibility issue, not a security one. | `<meta name="viewport" content="… maximum-scale=1, user-scalable=no …">` | Optional. |
| W7 | Info | web/index.html:13 | The `google-adsense-account` meta tag (ca-pub-5817610257612647) is still there. It loads nothing; it is only an ownership claim for upstream's AdSense account. | `<meta name="google-adsense-account" …>` | Remove in a private fork. |

What I checked and found clean:
- **New `innerHTML` sites** (controls.ts:171, drift.ts:42/51, photo.ts:76, quickchat.ts:242, shell.ts:999, touch.ts:359, wheel-setup.ts:82): all static markup, or `esc()`-escaped translations.
- **Peer data:** player names, chat and lobby data are set with `textContent` (lobby.ts:70, quickchat.ts:243, shell.ts:1001, claim-ui.ts).
- **`data-i18n-html`** (i18n.ts:184-201) rebuilds text nodes and reorders existing elements; it never parses HTML. `data-i18n-attr` only touches aria-label, title and placeholder.
- **BroadcastChannel** (shell.ts:1263-1286) is same-origin and its input is validated (`checkInvite`).
- **Invite links** (invite.ts) only read `#room=`/`#crew=` and ask before joining. There are no new `eval`, `new Function`, string `setTimeout` or `document.write` calls.

## Other checks

- **Cloud saves (vault.ts):** PBKDF2-SHA-256 with 100k rounds, the fixed salt, the AES-256-GCM seal, `newPhrase` (8 words) and `vault-words.ts` are all unchanged (`vault-words.ts` is not in the diff). The changes:
  - fewer files are uploaded: covers, registry.txt, gamefile.bin and the device's own lines of settings.ini are left out;
  - unanswered sends are now retried;
  - conflict "sides" show profile names and money, but only locally;
  - an over-size failure logs file paths to the local log.
  Plaintext never leaves the browser.
- **Service worker (sw.ts):** it now also caches `/lang/<a-z>+.json` (same origin only; `keyOf` rejects other origins). It also dropped `offlineUntil = 0`, so for up to 30 s after a fallback the cached copies keep answering first even when the server answers. That keeps one start on one version; it is not attacker-controllable. Scope is unchanged.
- **Permissions:** there is a new directory picker for the local music folder (radio-folder.ts:54-117). It is read-only, the handle is kept in IndexedDB, and files are decoded locally and never uploaded. The clipboard is now also used for invite links (settings-ui.ts:133) and the new passphrase (shell.ts:417), both on click. `getHighEntropyValues(['architecture'])` (checks.ts:175) goes only into the local log. No camera, mic, notifications, geolocation, WebHID, WebUSB or WebSerial. DeviceOrientation and vibrate existed before.
- **Logs:** the log is never uploaded; it is only downloaded by the user. A new scrubber (privacy.ts) replaces names, IP addresses and the time-zone name in downloads and in the lastgame copy kept in localStorage (lastgame.ts:60-66).
- **Binaries:** there are 4 PNGs, all valid with only IHDR, IDAT and IEND chunks and no trailing data:
  - web/src/app/drift.png, 192x107 gray+alpha;
  - web/src/app/nitro.png, 192x68;
  - web/src/app/status.png, 128x115;
  - docs/web/start-page.png, 1280x800 RGB screenshot.

  The three app icons are inlined as `data:` URLs by build.mjs (`.png: 'dataurl'`). No base64 or hex blobs of 120+ characters appear in added non-translation source. The lang JSON has no `<script>`, `javascript:`, `on*=` or `<img>`/`<iframe>`.
- **web/tools:** nothing downloads or installs at build time. browser.mjs only checks for a local Chrome binary; `npx playwright install` appears in a comment only. Tools and tests spawn only local binaries (server, clang, ffmpeg, bash/python on repo scripts) and contact only 127.0.0.1/localhost. `https://astc.test/` is a Playwright-routed fake. The `import('data:text/javascript;base64,…')` calls in tests load esbuild bundles of the repo's own source. build.mjs now copies `src/app/lang/*.json` to `dist/lang` after re-serialising it with `JSON.parse`.
- **Test-only URL parameters** (`reg`, `script`, `artifacts`) still work only when `/test/dev.json` says `dev: true` (shell.ts:96-101, 1664-1667), as before.

## External origins referenced by the page at upstream/main

| Origin | Where | Loaded or link |
|--------|-------|----------------|
| https://challenges.cloudflare.com | claim.ts:123 | **Loaded** (script + iframe), only when the server sets Turnstile keys |
| https://discord.gg (25zXmQ2Ua9, SSHm5g43gh) | index.html:53, 73, 159 | Link |
| https://ko-fi.com/nfsu2xyz | index.html:158, 361 | Link |
| https://github.com (th0mk/nfsu2-web, TalhaMudo/NFSU2Recomp, hedge-dev/XenonRecomp, N64Recomp/N64Recomp) | index.html:163 | Link (new) |
| https://nfsmods.xyz (mod/4319, 5749, 5286, 1583) | index.html:164, 168, 173; settings-ui.ts:71, 73, 84 | Link (new) |
| https://www.moddb.com | index.html:171 | Link (new) |
| http://www.gamehunter.hu | index.html:172 | Link (new, plain http) |
| mailto:legal@nfsu2.xyz | index.html:159 | Link |
| https://www.eff.org/dice | vault-words.ts:2 | Comment only |
| https://schema.org | index.html:28 | JSON-LD `@context` string, not fetched |
| http://www.w3.org/2000/svg | SVG namespaces | Not fetched |

Same-origin endpoints the page calls (new marked *): `/game.json`, `/game.wasm`, `/data-manifest`, `/data-blocks/v2/…`, `/players` (*now with `?room=`/`?crews=` hashes), `/vault`, `/names`*, `/seen`*, `/lang/*.json`*, the `/lan` WebSocket (*now with `?queue`; hello carries `id`, `was`, `claim`, `block`), and `/test/dev.json`.

## Coverage

- **Read fully:**
  - files at upstream/main: claim.ts, claim-ui.ts, pwkeep.ts, page-id.ts, privacy.ts, logs.ts, devicelog.ts, invite.ts, radio-folder.ts, radio-link.ts, web/tools/browser.mjs;
  - full diffs: vault.ts, sw.ts, build.mjs, dev-server.mjs, run-page.mjs, server-cmd.mjs, gencheck.sh;
  - parts: i18n.ts (fetch and the markup-building code, lines 120-222), players.ts lines 125-184, lastgame.ts (header and write), the shell.ts sections on invite relay, boot/dev gating, session log lines and VaultPanel wiring.
- **Read in part:**
  - vault-ui.ts diff: the password-manager, start and owner section fully, the rest via grep for storage, network, clipboard and DOM sinks;
  - net/index.ts diff: header, NetOptions and the hello in full, the rest by grep;
  - index.html diff: every changed tag carrying src, href, form or meta.
- **Skimmed by targeted grep only** (network, storage, DOM sinks, permissions, URLs, encoded blobs): shell.ts, settings.ts, settings-ui.ts, saves-ui.ts, lobby.ts, quickchat.ts, touch.ts, controls.ts, drift.ts, photo.ts, wheel-setup.ts, checks.ts, the host/* workers, datacache.ts, all of web/test and web/tools, and the 17 lang JSON files.
- **Not reviewed line by line:** gpu/* (astc, encoder, index, wgsl), audio/*, input/* (gamepad, hidpad, wheel), net/proto.ts, host/movie.ts, radio.ts and radio-tags.ts beyond grep, style.css, and test logic. Greps of these showed no network, storage or permission calls beyond the ones listed above.

## Open questions

1. The pathspec `web/*.mjs` also matches `web/server-rs/crates/lan/tests/page.mjs` (git pathspec globs cross `/`). I left it to the server-rs reviewer and did not review it.
2. Whether `/names` claims are enabled by default on the server, and what the server logs or stores for `/seen`, the hello `id`/`claim`, and `Authorization` headers. That is server-side (web/server-rs), not my scope. W2 and W3 depend on it.

## Changes outside the scratchpad

None. I did not run git checkout, switch, reset or merge. Scratch files (vault.diff, vaultui.diff, net.diff, bins/*.png) are only in /tmp/claude-0/-home-user-nfsu2-web/8bef6790-e6d9-51a2-a8b2-5e37e280d48f/scratchpad.
