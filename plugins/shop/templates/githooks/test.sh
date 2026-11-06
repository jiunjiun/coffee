#!/bin/bash
# Runs the hooks in throwaway repos. Usage: .githooks/test.sh
hooks=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare -b main "$tmp/origin.git"
git init -q -b main "$tmp/main"
git -C "$tmp/main" remote add origin "$tmp/origin.git"
git -C "$tmp/main" commit -q --allow-empty -m first
git -C "$tmp/main" push -q origin main
git -C "$tmp/main" worktree add -q -b feature "$tmp/feature"

failed=0
check() {  # expected result, directory, git arguments
  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" git -C "$tmp/$2" "${@:3}" 2>&1)
  rc=$?
  if [[ $out == *"A Claude session"* ]]; then got=refused; elif ((rc == 0)); then got=ok; else got="failed: $out"; fi
  [[ $got == "$1" ]] || { echo "FAIL $got, want $1: [$2] git ${*:3}"; failed=1; }
}

check refused main commit --allow-empty -m x
check ok feature commit --allow-empty -m "refuse git push to main"
check ok feature push -u origin HEAD
check ok feature push origin feature:fix/main-card
check refused feature push origin HEAD:main
check refused feature push origin HEAD:refs/heads/main
check refused feature push origin +HEAD:main
check refused feature push origin :main

# A commit the session made before the hooks came, or a merge: pre-commit does not see it, and the push stops it.
git -C "$tmp/main" commit -q --allow-empty -m local
check refused main push origin main

# The owner's shell has no hooks.
git -C "$tmp/main" commit -q --allow-empty -m owner || { echo "FAIL owner commit"; failed=1; }
git -C "$tmp/main" push -q origin main || { echo "FAIL owner push"; failed=1; }

# A repo whose default branch is trunk, not main.
git -C "$tmp/main" push -q origin main:trunk
git -C "$tmp/main" fetch -q origin
git -C "$tmp/main" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
git -C "$tmp/main" switch -q -c trunk origin/trunk
check refused main commit --allow-empty -m x
check refused feature push origin +HEAD:trunk
[[ $failed == 0 ]] && echo PASS
exit $failed
