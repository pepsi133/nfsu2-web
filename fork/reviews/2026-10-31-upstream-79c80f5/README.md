# Upstream review: 0b7085c to 79c80f5 (2026-10-31)

Range: fork `main` at `0b7085c` to `th0mk/nfsu2-web` `main` at `79c80f5`. The range has 364 commits, 518 files, +79,101 and -4,483 lines. The fork's `main` is an ancestor of upstream, so the merge is a fast-forward.

Three independent reviewers each took one area and read the diff with `git diff` and `git show` only. Their full reports are in this folder:

- `server-supply.md`: Rust server, CI workflows, deploy files, Dockerfiles, dependency files, build scripts, `tools/`, `discord-bot/`.
- `web-client.md`: `web/src`, `web/tools`, `web/test`, `web/index.html`, added binary files.
- `runtime-rest.md`: `runtime/`, `tests/`, `docs/`, `win/` and the remaining paths.

## Verdict

Merge. No reviewer found malware, a backdoor, obfuscated code, hard-coded credentials, third-party telemetry or an authentication bypass. Game data still goes only to the player who requests it. Each report says "merge after listed fixes", and no listed fix blocks the merge.

## Findings that need action in this fork

| ID | Severity | Action |
|---|---|---|
| U-3 | Low | A new workflow `image-bot.yml` has `packages: write` and tag-pinned actions. Keep GitHub Actions disabled on the fork (see `fork/gcp/README.md`). |
| U-1 | Low | `NFSU2_HTTP_SOCKET` treats each connection as loopback. Use only the abstract `@nfsu2-http` form from `compose.tunnel.yml`. |
| U-2 | Low | `cgroup: host` in `compose.yml`. The GCP deploy overrides it with `cgroup: private`. |
| W1, U-6 | Low | Cloudflare Turnstile loads a third-party script and calls `challenges.cloudflare.com`. Keep `NFSU2_TURNSTILE_SITE` and `NFSU2_TURNSTILE_SECRET` unset. |
| RN-1 | Low | Direct car states (N2CS) accept data from any host on the race creator's list. Among friends this is acceptable. Set `NFSU2_RACE_DIRECT=0` if you invite people that you do not trust. |
| MP-1 | Medium (Low among friends) | Unchanged from the earlier audit. The fix goes upstream as a PR. |
| new `/state` data | Info | Logs (30 days, player names) and compressed game-block copies (up to 16 GB). The GCP deploy sets `NFSU2_COMPRESS_THREADS=0`. |

## Findings to send upstream as small PRs

W5 (`method="post"` on the passphrase form), RN-1 (trust only race-session peers), MP-1, U-4 (Zig checksum), MV-1 (clamp movie sizes), and the zstd bump (the same 3 advisories are present before and after this range). Add these to the "Suggested PR order for upstream" list in the review guide.

## Accepted as is

- W2: a random browser ID goes to your own server (`/seen`, `/lan` hello). The server stores keyed hashes with a new key each day.
- W3: the encrypted-save token is also sent to `/names` and in the `/lan` hello. The token cannot decrypt the save.
- W4: Chrome and Edge can offer to save the passphrase. The browser asks the user first.
- SMS-1: an in-game SMS after 2 hours points to the upstream Discord and Ko-fi page. Change it in the fork if you want.
- DOC-1: the new "Cloudflare without a tunnel" layout is weaker. This fork uses the tunnel.

## Not covered

The detailed logic of the bans and claims crates, the Online protocol parsing, the end of `run.rs`, `gpu/`, `audio/`, `input/`, `net/proto.ts`, and the new C unit tests line by line. Each report lists its coverage.
