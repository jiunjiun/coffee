# Order setup

Run once per computer, in a clone of the repository. It changes nothing in the repository.

1. Check the tools in one command: `for t in bash git jq gh; do command -v "$t" >/dev/null || echo "missing $t"; done`. For each tool that is missing, give the user the install command for their system, for example `brew install gh jq` on macOS, or the package manager of their Linux. Install it only when the user says so. Go on after each tool is there.
2. Check the account: `gh api user --jq .login` prints the login. When it fails, no account is signed in: tell the user to run `gh auth login` in a normal terminal. Never ask for a token, and never read one.
3. Check the repository:
   - `git remote get-url origin` passes: the folder is a clone of a GitHub repository.
   - `T role` prints `mode=shared`. With `mode=none`, the repository has no `.claude/shop.json`: run `git pull`, and run `T role` again. When it still prints `mode=none`, tell the user that the owner must run `/shop setup` first. With `mode=solo`, tell the user that the owner must turn on `shared` mode: the shop takes no orders from requesters.
4. Check that the shop accepts orders from this account: it must be a collaborator. GitHub shows the collaborator list only to an account with push access, so read the access of this account: `gh api "repos/{owner}/{repo}" --jq '"private=\(.private) push=\(.permissions.push)"'`.
   - `private=true`, or `push=true`: the account is a collaborator. Only a collaborator can read a private repository.
   - `private=false push=false`: GitHub gives this account the same access as any account on a public repository. Tell the user that you cannot confirm it, and that the owner can.
   - It fails: tell the user that you cannot confirm it, and that the owner can.
5. Report each check: passed, failed, or not confirmed, and what the user must do for each one that did not pass. When all pass, tell the user to type `/order` to start.
