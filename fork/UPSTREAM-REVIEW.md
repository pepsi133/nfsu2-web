# How upstream changes reach this fork

This fork tracks `th0mk/nfsu2-web`. The fork's `main` changes only through a pull request that carries a security review. Nobody uses GitHub's "Sync fork" button.

## Rules

1. Never push directly to `main`. Protect `main` in GitHub: Settings, Branches, add a rule for `main`, require a pull request before merge.
2. Keep GitHub Actions disabled on the fork. A sync branch carries unreviewed workflow files, and Actions would run them with the repository token.
3. Deploy only a commit that is on `main`. The GCP build (`fork/gcp/build.sh`) takes a full commit hash.
4. Keep fork-only files under `fork/`. Then upstream merges do not conflict.

## The weekly review

A scheduled Claude task runs once a week. It does these steps:

1. Fetch upstream `main`. If it has no new commits since the fork's `main`, stop and report "no changes".
2. Make the branch `upstream-sync/<YYYY-MM-DD>` from the fork's `main`, then merge upstream `main` into it.
3. Review the diff from the fork's `main` to upstream `main`. Split the work by area, as in `fork/reviews/2026-10-31-upstream-79c80f5/`. Look for malware, obfuscated code, new outbound network calls, new dependencies, build-time downloads, workflow changes, weaker security headers or checks, and changes to the handling of game files and saves.
4. Write the reports to `fork/reviews/<YYYY-MM-DD>-upstream-<short hash>/`, with a `README.md` that gives the verdict and the findings table.
5. Push the branch and open a pull request to `main`. Put the verdict and the findings table in the pull request description.
6. Never merge. The owner reads the review and merges.

If the review finds a Critical or High issue, the pull request title starts with `DO NOT MERGE:`.

## Run a review by hand

Ask Claude in a session on this repository: "Run the upstream review in fork/UPSTREAM-REVIEW.md".
