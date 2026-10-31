# fork/

This folder holds the additions of the pepsi133/nfsu2-web fork. Upstream is th0mk/nfsu2-web.

- Keep every fork-only file in this folder. Do not change upstream files. Then upstream merges stay free of conflicts.
- Change the fork's `main` branch only through reviewed upstream-sync pull requests.
- Read each upstream-sync pull request before you merge it. Look at the workflow files and the deploy files first.

## Contents

- [`gcp/`](gcp/README.md): run the game server privately on Google Cloud. A Google login protects it. The VM stops when nobody plays.
