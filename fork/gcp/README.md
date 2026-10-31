# The game server on Google Cloud

This runbook puts the game server on one private Compute Engine VM. Cloudflare Tunnel and Cloudflare Access are in front of it. Only the Google accounts on your allowlist can open the game. The VM powers off after 30 minutes without players. You start it again with one command.

What runs where:

| Part | Where |
|---|---|
| The game VM `nfsu2` (e2-medium, no public address) | Compute Engine, europe-central2-a |
| The game folder, the modules, the deploy files, the manifests | the private bucket `gs://<project>-nfsu2` |
| The server images | Artifact Registry `nfsu2`, always pinned by digest |
| The allowlist, the tunnel token, the Cloudflare API token | Secret Manager |
| The login and the allowlist check | Cloudflare Access, Google login only |
| The module and image build | a temporary Spot VM `nfsu2-build`, deleted after each build |

Every script reads `fork/gcp/config.env`. Every script prints its commands without running them when you set `DRY_RUN=1`. Example: `DRY_RUN=1 fork/gcp/00-project.sh`.

## 1. Human steps

1. Create a Google Cloud project at https://console.cloud.google.com/projectcreate.
2. Link a billing account to the project (Billing, Link a billing account).
3. Open Billing, Budgets and alerts. Create a budget for this project.
4. Set alert thresholds at USD 10 and USD 30.
5. Install the Google Cloud CLI from https://cloud.google.com/sdk/docs/install.
6. Run `gcloud auth login` and log in with the project owner account.
7. Make sure that `python3` and `curl` are on your computer. The scripts use them.

## 2. Disable GitHub Actions on the fork

Upstream-sync branches carry upstream workflow files that nobody has reviewed yet. Upstream also adds a second workflow, `image-bot.yml`. The fork builds nothing on GitHub.

1. Open the fork on GitHub.
2. Open Settings, Actions, General.
3. Select "Disable actions".
4. Click Save.

This setting covers every workflow of the fork, `image-bot.yml` included.

## 3. Test Cloudflare WARP first

Do this test before any GCP work. A WARP client enrolled in another Zero Trust organization can apply the Gateway policies of that organization. Then the game can fail for that player.

1. Find any hostname that Cloudflare Access protects. Use a test application of your own if you have one.
2. Ask the owner and the friend to turn on their Cloudflare WARP client.
3. Ask both of them to open that hostname in Chrome.
4. Confirm that the Google login appears for each person.
5. Confirm that the page loads after the login.
6. If one of them fails, solve that first. Turn off WARP for the test or leave the other organization.

## 4. The configuration

1. Copy the example: `cp fork/gcp/config.env.example fork/gcp/config.env`.
2. Set `PROJECT_ID` to the ID of your project.
3. Set `NFSU2_HOST` to the hostname of the game, for example `nfsu2.example.com`. Cloudflare must manage its DNS zone.
4. Keep the other values. Fill in the four `CF_` values later, in step 8.
5. Do not commit `config.env`. The file `fork/gcp/.gitignore` excludes it.

## 5. The project and the network

1. Run `fork/gcp/00-project.sh`. It enables the APIs and creates the service accounts, the bucket, the registry and three empty secrets.
2. If a role binding fails with "does not exist", wait one minute. Then run `00-project.sh` again.
3. Run `fork/gcp/10-network.sh`. It creates Cloud NAT and the firewall rule for SSH through IAP.
4. Answer `y` to each question about the default firewall rules. The VMs need no SSH, RDP or ping from the internet.

## 6. The secrets

The scripts never take a secret value as an argument. Type each value into `gcloud` on standard input.

1. Run `gcloud secrets versions add nfsu2-allowlist --data-file=-`.
2. Type one email address per line. Use the Google accounts of the owner and the friend.
3. Press Enter after the last line. Then press Ctrl-D.

Add the two token values in step 8. Use the same command form with `nfsu2-tunnel-token` and `nfsu2-cloudflare-api-token`.

To change the allowlist later, add a new version with the same command. Then run `fork/gcp/access-sync.sh`.

## 7. Upload the game

1. Run `fork/gcp/upload-game.sh "<your game folder>"`.
2. Wait for the upload. The game takes about 3 GB.

The script checks the SHA-256 of `SPEED2.EXE` first. It uploads only `SPEED2.EXE`, `server.dll`, `server.cfg`, the game's data folders, and `LANGPACKS` if present. It never uploads a `SAVE` folder, an installer log or dot files. The upload keeps the file times with `--preserve-posix`. The VM restores them with the same flag. The ETags use the file times, so a copy with new times makes every browser download the game data again.

Run the script again after a change to the game folder. The VM syncs the folder at its next start.

## 8. Cloudflare

Use the Cloudflare dashboard. Zero Trust is under the account, not under the zone.

### The tunnel

1. Open Zero Trust, Networks, Tunnels. Create a tunnel of type Cloudflared.
2. Select the Docker environment. Copy the token from the command that the dashboard shows.
3. Run `gcloud secrets versions add nfsu2-tunnel-token --data-file=-`. Paste the token. Press Enter and Ctrl-D.
4. Add a public hostname to the tunnel. Use `NFSU2_HOST` as the hostname.
5. Set the service to `http://127.0.0.1:8080`.

### The login

1. Open Zero Trust, Settings, Authentication.
2. Add Google as a login method. Follow the instructions of the dashboard for the Google OAuth client.
3. Copy the ID of the Google login method into `CF_GOOGLE_IDP_ID` in `config.env`.
4. Remove the One-time PIN login method.

### The Access application

1. Open Zero Trust, Access, Applications. Add a self-hosted application.
2. Set its domain to `NFSU2_HOST`.
3. Add an Allow policy. Include one email of the allowlist for now. `access-sync.sh` replaces the list later.
4. Copy the application ID into `CF_ACCESS_APP_ID` and the policy ID into `CF_ACCESS_POLICY_ID`.
5. Copy your account ID into `CF_ACCOUNT_ID`. The dashboard shows it on the account overview.

### The API token for access-sync.sh

1. Open My Profile, API Tokens. Create a custom token.
2. Give it the permission Account, Access: Apps and Policies, Edit. Limit it to your account.
3. Run `gcloud secrets versions add nfsu2-cloudflare-api-token --data-file=-`. Paste the token. Press Enter and Ctrl-D.

### The zone settings

These settings come from `docs/web/VPS.md`, section Cloudflare.

1. Turn off Rocket Loader (Speed, Optimization).
2. Turn off Email Obfuscation (Scrape Shield).
3. Do not turn on Zaraz. Do not turn on the automatic setup of Web Analytics.
4. Open Caching, Cache Rules. Create one rule.
5. Match URI Path wildcard `/data-blocks/*` OR URI Path equals `/game.wasm`. Keep the `*`.
6. Set "Eligible for cache". Set Edge TTL to "Use cache-control header if present, bypass cache if not".
7. Set Browser TTL to "Respect origin TTL". Keep the cache key as it is.
8. Turn on Smart Tiered Caching.
9. Delete any "Bypass cache" rule for the hostname.

Do not set `NFSU2_TURNSTILE_SITE` or `NFSU2_TURNSTILE_SECRET`. Keep them unset behind Cloudflare Access. The scripts never set them.

### Apply the allowlist

1. Run `fork/gcp/access-sync.sh`.
2. Confirm that each line ends with `HTTP 200`.

The script sets the application to Google login only, with an automatic redirect and a 168-hour session. It replaces the policy's include list with the emails of `nfsu2-allowlist`. It prints counts and HTTP status codes only.

## 9. Build, create the VM, release

1. Choose a commit of the fork. Get its full 40-character hash with `git rev-parse <branch>`.
2. Run `fork/gcp/build.sh <commit>`.
3. Wait. The first build takes the longest. The script stops and deletes the build VM after 3 hours at most.
4. Read the manifest that the script prints. It names the image digest and the SHA-256 of `nfsu2.wasm`.
5. Run `fork/gcp/20-vm.sh`. It creates the VM and the weekly snapshot schedule.
6. Run `fork/gcp/release.sh <commit>`.

If the build VM fails to start with a quota error, request more CPU quota for Spot VMs in europe-central2. The build VM uses 8 vCPUs.

If a build fails, the script prints where the log is. Read it with `gcloud storage cat gs://<bucket>/releases/<commit>.log`. Delete the leftovers of the failed build before you build the same commit again. The script prints the command.

The first build stores the SHA-256 of the wasi-sdk download in `gs://<bucket>/pins/`. Every later build fails if the download changes. Node and rustup-init have checksums in the build script, taken from their publishers.

## 10. Verify

1. Open `https://<NFSU2_HOST>/` in a private browser window.
2. Confirm that the Google login appears. Log in with an account of the allowlist.
3. Confirm that the start page of the game loads.
4. Run `curl -sI https://<NFSU2_HOST>/`. Confirm the status 302 and a `location` at `cloudflareaccess.com`.
5. In the browser, open the developer tools, Network. Reload the page and select the first request.
6. Confirm the headers `content-security-policy`, `cross-origin-opener-policy` and `cross-origin-embedder-policy`.
7. Log in with an account that is not on the allowlist. Confirm that Access refuses it.
8. Start a race between the two players. Confirm that both players see each other.

## 11. Daily use

### Start and stop

- Run `fork/gcp/start.sh` to start the VM. The game is up after about 2 minutes.
- Run `fork/gcp/stop.sh` to stop the VM at once.
- Run `fork/gcp/status.sh` to see the VM state, the release and the containers.

The VM powers itself off after 30 minutes without players (`IDLE_MINUTES`). A timer checks every 5 minutes. It asks the server how many players are on the switch. It also counts the connections to the server. If a check fails, the timer counts the VM as busy. Read its log on the VM with `journalctl -u nfsu2-idle`.

### Let a friend start the VM

1. Run `fork/gcp/grant-starter.sh <friend's email>`.
2. Give the friend the start command that the script prints.

The friend needs the Google Cloud CLI. The role lets the friend start the VM and nothing else.

### Rollback

1. Find an older commit with a manifest: `gcloud storage ls gs://<bucket>/releases/`.
2. Run `fork/gcp/release.sh <older commit>`.

### Costs

A stopped VM costs no CPU or memory. These parts cost money also when the VM is stopped:

- the 20 GB boot disk
- the weekly snapshots (4 are kept)
- the bucket (about 3 GB of game files, plus the modules)
- the images in Artifact Registry
- Cloud NAT, for the hours that a VM uses it

Check the GCP pricing calculator at https://cloud.google.com/products/calculator for current prices. The budget alerts of step 1 warn you if the costs grow.

### Logs

- On the VM, run `sudo nfsu2-compose logs -f server` to see the server's console.
- Open SSH with `gcloud compute ssh nfsu2 --zone=europe-central2-a --tunnel-through-iap`.

## 12. What never goes into the repository or the image

- `gen/` (the C translated from `SPEED2.EXE`)
- `out/` (the compiled module and other build output)
- the game folder and everything in it
- any `SAVE` folder
- `config.env` and every secret value

The build VM uploads only `out/web/nfsu2.wasm` and `out/web/nfsu2.json` of `out/`. The image holds the server and the page only. The game stays in the private bucket and on the VM disk.

## Known limits

- The VM keeps the tunnel token only in `/run/nfsu2/tunnel-token`. This folder is in memory, so the token is not on the disk or in the snapshots.
- The file belongs to the cloudflared user (uid 65532) and has the mode 0400. cloudflared reads it with `--token-file`.
- No container gets the token in its environment. `docker inspect` shows `TUNNEL_TOKEN` as empty.
- After you change the token in Secret Manager, run `fork/gcp/release.sh <current commit>` or restart the VM.
- Nobody has run these scripts against a real project or a real Cloudflare account yet. Run each script with `DRY_RUN=1` first.
