# Shop setup

Run once per project, in the project root.

1. Read `.claude/shop.json` if it exists. If it does, show it and ask what to change.
2. Suggest a prefix from the folder path: a short word for the product, then the platform. `~/git/acme/web` gives `ac-web`, `~/git/acme/api` gives `ac-api`. Check `claude agents --json`: the prefix must not match another project's sessions. Ask the user to confirm it.
3. Tell the user the default limits: 3 leads, and 2 helpers per lead. Ask if the project needs other values.
4. A lead starts with `/poteto-mode` from the pstack plugin. Make sure that pstack is on: `claude plugin list --json` lists `pstack@...` with `"enabled": true`. If it does not, give the user the install commands in README.md, and go on after pstack is on.
5. A lead commits and pushes with `/shop commit`. If the machine has another commit skill, for example `/commit`, ask the user which one the leads use. Set `commit_skill` only when the user picks another skill.
6. Ask for the mode. `solo`, the default: only the user starts orders. `shared`: requesters on the team also send orders as GitHub issues with the `order` plugin, and main watches the issues. For `shared`:
   - Give the user the README section on who can send orders and how requesters install the plugin: https://github.com/jiunjiun/coffee#orders-from-your-team
   - Check that `gh auth status` lists the `repo` and `read:org` scopes: the guard needs them to check collaborators.
7. Write `.claude/shop.json`. Keep only `prefix` and the values that differ from the defaults:

   ```json
   { "prefix": "ac-web" }
   ```

   In `shared` mode, add `"mode": "shared"`.

8. Check these, and report each one that fails:
   - `gh auth status` passes, and the repo has a remote.
   - `git symbolic-ref refs/remotes/origin/HEAD` passes: a lead starts from that branch. If it fails, run `git remote set-head origin --auto`.
   - `.scratch/` is git-ignored: `git check-ignore .scratch/x`.
   - The project folder is trusted: `claude --bg` refuses an untrusted folder.
9. If the project has no hook that keeps Claude sessions off the default branch, offer one: a lead commits and pushes, and nothing else stops a session that commits on the default branch. To add it, copy `templates/githooks/` to `.githooks/`, run `.githooks/test.sh`, and add this to `.claude/settings.json`:

   ```json
   { "env": { "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath", "GIT_CONFIG_VALUE_0": ".githooks" } }
   ```

   The hooks run only for Claude sessions, so the owner's shell does not change.
10. Run `shop.sh ci`. It reports the two review workflows and the token. These workflows review each PR of a lead, so a project with no workflows gets no review.
   - A workflow is missing: ask the user. On a branch, run `shop.sh ci install`. Ask what this project needs its reviewers to watch, and add it to the prompts. Commit and open a PR. The reviews of that PR fail by design: the action skips a PR that changes its own workflow. Merge it after you read it.
   - The token is missing: tell the user the steps below. Never ask for the token, never read it, and never run this for the user.

     1. Install the Claude GitHub App on the repo: https://github.com/apps/claude
     2. In a normal terminal, in the repo, run `T token`, with the full path of `T` from the skill.

     The script refuses to run through Claude, because the output of a `!` command enters the conversation. Run `shop.sh ci` again to confirm.
11. Add a short section to the project's `CLAUDE.md` with what is special to this project: the prefix, who merges what, and each resource that takes one actor at a time. Commit through the project's normal flow.
   - For who merges what, write by default that main merges every PR. If the project has a step that stops a PR for the owner (for example a merge script that hands some PRs to the owner), change that step itself, so that no two rules disagree. End it with:

     ```
     Only `<prefix>-main` goes on: it reads the PR itself and merges it. On an objection or a request to wait, it asks the owner first.
     ```

   - Write another rule only when the user says that the owner merges some PRs. Name those PRs.
12. Tell the user how to start: type `/shop main` in any session of this project, or run `claude -n <prefix>-main`. In `shared` mode, the requesters can send orders now: main picks up each open order when it starts.
