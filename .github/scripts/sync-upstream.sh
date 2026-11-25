#!/usr/bin/env bash
set -euo pipefail

# GitHub's published Ed25519 host key for SSH on port 443.
sync_dir=$(mktemp -d)
trap 'rm -rf "$sync_dir"' EXIT
umask 077
printf '%s\n' '[ssh.github.com]:443 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' > "$sync_dir/known_hosts"
test -n "${SYNC_KEY:?The fork deploy key must be configured}"
printf '%s\n' "$SYNC_KEY" > "$sync_dir/key"
unset SYNC_KEY
export GIT_SSH_COMMAND="ssh -p 443 -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$sync_dir/known_hosts -i $sync_dir/key"

git config user.name 'ICICLE upstream sync'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git remote add upstream "$UPSTREAM_URL"
# A fresh fetch prevents a queued run from merging onto its stale event SHA.
fork_url="git@ssh.github.com:${GITHUB_REPOSITORY}.git"
git fetch --no-tags "$fork_url" refs/heads/main
git switch -C main FETCH_HEAD
git fetch --no-tags upstream refs/heads/main
upstream_sha=$(git rev-parse FETCH_HEAD)
if git merge-base --is-ancestor "$upstream_sha" HEAD; then
  echo "Upstream is already included at $upstream_sha"
  exit 0
fi

if ! git merge --no-ff --no-commit "$upstream_sha"; then
  # Only resolve an overlap with the generated README block automatically.
  if [[ "$(git diff --name-only --diff-filter=U)" != README.md ]]; then
    echo "::error::Upstream merge needs manual conflict resolution."
    exit 1
  fi
  git show :1:README.md > "$sync_dir/base"
  git show :2:README.md > "$sync_dir/fork"
  git show :3:README.md > "$sync_dir/upstream"
  python3 - "$sync_dir" <<'PYTHON'
from pathlib import Path
import re
import subprocess
import sys

work = Path(sys.argv[1])
block_pattern = re.compile(r"\n<!-- ICICLE metadata start -->\n.*?\n<!-- ICICLE metadata end -->\n", re.S)
fork = (work / "fork").read_text()
matches = list(block_pattern.finditer(fork))
if len(matches) != 1 or block_pattern.search((work / "upstream").read_text()):
    raise SystemExit("README structure changed. Resolve the README merge manually.")
block = matches[0][0]
(work / "fork").write_text(block_pattern.sub("", fork, count=1))
merged = subprocess.check_output(
    ["git", "merge-file", "-p", work / "fork", work / "base", work / "upstream"],
    text=True,
)
title, newline, body = merged.partition("\n")
if not newline or not title.startswith("# "):
    raise SystemExit("README title changed. Resolve the README merge manually.")
Path("README.md").write_text(title + newline + block + body)
PYTHON
  git add README.md
fi
git commit -m "Merge upstream main at ${upstream_sha:0:12}"
# A repository-scoped SSH key makes this a regular push that triggers CI.
git push "$fork_url" HEAD:refs/heads/main
