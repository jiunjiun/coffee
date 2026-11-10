# coffee

Claude Code plugins. Say what you want, say go, and take a coffee break while the agents do the work.

For a visual guide to how an order runs, in English and 繁體中文, see the [coffee order flow page](https://claude.ai/artifact/VAnZnEiKqpdeziQvB6Sh3v).

## shop

`shop` is a Claude Code plugin that runs your features through a team of Claude sessions. You talk to one session. It starts other sessions in the background. Each feature gets its own git worktree, its own branch, and its own pull request.

```
you ──▶ main ──┬──▶ lead: csv-export ──┬──▶ helper: research
               │         │             └──▶ helper: verify
               │         └──▶ PR #41
               └──▶ lead: chart-colors ──▶ PR #42

main reads PR #41 and PR #42, merges them, and tells you the result.
```

| Role | Session name | Job |
| --- | --- | --- |
| main | `<prefix>-main` | Talks to you, writes the order, starts leads, merges every PR |
| lead | `<prefix>-<slug>-lead` | Owns one feature: worktree, code, tests, PR, review fixes |
| helper | `<prefix>-<slug>-<job>` | Does one part of a lead's work in parallel: research, a function, a review |
| order | `<prefix>-order` | A requester's session with the `order` plugin: writes orders, and submits each one after the requester's go. See [Orders from your team](#orders-from-your-team) |

The session name sets the role. A session with another name is not in the shop, and works as usual.

## When to use it

Use it when:

- You have several features that do not touch the same files, and you want them built at the same time.
- You want to give the goal, then leave. You come back to merged PRs and a report of what was verified.
- You want each change to go through a PR, CI, and an AI review before it reaches the default branch.
- One feature is large enough to split: for example, one helper reads the old code while another writes the tests.
- You want to direct the work from your phone. Turn on Remote Control in the main session (`/rc`), and talk to main from the Claude app.

Do not use it when:

- The change is small. Main tells you so, and does it itself in one worktree.
- The goal is not clear yet. Talk it through with a normal session first.
- The project is not on GitHub. The flow uses `gh` for PRs, checks, and review threads.
- Your plan has a small usage limit. See [Requirements](#requirements).

## Example scenarios

### Two features at the same time

```
you:  Add CSV export to the reports page. Also, dark mode breaks the chart colors.
main: Order: CSV export (csv-export)
      Background: Users copy the report by hand into a spreadsheet.
      Goal: A button on the reports page downloads the current report as CSV.
      Done when: The file opens in a spreadsheet with the same rows as the page.

      Order: chart colors (chart-colors)
      Background: In dark mode the chart lines have almost no contrast.
      Goal: Chart colors are readable in light and dark mode.
      Done when: The chart lines pass a contrast check in both modes.

      Reply go to start. To start only some, name them: go <slug>. To change something, say it.
you:  go
main: Created #41 CSV export and #42 chart colors. Started ac-web-csv-export-lead and ac-web-chart-colors-lead.
      (later)
      #41 CSV export and #42 chart colors are done. Verified: unit tests, CI, Claude review.
      Not verified: CSV export on Safari.
```

An order has no number before go. At go, main creates a GitHub issue for it, and the issue number is the order number from then on. The lead's PR says `Closes #41`, so the merge closes the issue. An order that you cancel after go has its issue closed as not planned.

To start only the first one, reply `go csv-export`. With a Chinese name, the name works too. To start it and ask about something else in the same message, reply `go csv-export. Also, can the export include the filters?`

### Two features that touch the same files

Main sees the overlap. It starts the first feature, queues the second with `shop.sh queue`, and tells you why. The second feature keeps your go. Main starts it after the first one is merged.

### A resource that only one actor can use

Some projects have one staging database, one device, or one simulator. Main records who has it: `shop.sh hold staging csv-export`, then `shop.sh hold staging free`. The status page shows the holder.

### A session that needs you

A background session can stop at a permission prompt. `shop.sh guard` runs in the background of main. It wakes main when a lead is blocked, or when a lead and its helpers are quiet for 30 minutes. Main tells you. The status page shows the command to open that session: `claude attach <id>`.

## How a feature moves

1. You describe the work to main. Main writes an order and waits.
2. You say go. A hook reads your message and opens the orders that it names. Main can start a lead only for an open order. See [Saying go](#saying-go).
3. Main creates a GitHub issue for each open order, then runs `shop.sh lead`. It creates the worktree `.scratch/<slug>/wt` and the branch `<type>/<slug>` from the default branch. Then it starts the lead in the background with the brief.
4. The lead comments on the issue that it started, with its plan. It plans the work, starts helpers if parts can run in parallel, verifies, commits, pushes, and opens the PR. The PR's `Closes #<issue>` links it to the issue.
5. CI runs the Claude review and the Claude security review. The lead fixes each real finding and answers each wrong one. After 3 rounds with problems left, it tells main.
6. The lead reports the PR as ready, to main and on the issue. Main reads the PR, the comments, and the checks, then squash-merges it. The merge closes the issue.
7. Main closes the lead. This removes the worktrees, and the branch when its work is merged. Main reports what now works, what was not verified, and the decisions that the lead made alone, to you and on the issue.

The issue gets a comment only at these points, and when the lead's plan changes. The status page shows each step. The sessions comment with your GitHub account, so GitHub does not notify you: open the issue to read them.

## Saying go

A hook reads each message that you send to main. It uses fixed rules, not a model, so a session cannot say go for you. The order session of a requester uses the same hook and the same rules: there, a go submits the order.

A message is a go when it has the word `go` at the start, after punctuation, after a number, after a Chinese character, or after a word like `ok`, `yes`, or `then`. The hook then opens:

- The orders that the message names, by slug (`go csv-export`), or by name when the name has a Chinese character (`go 匯出報表`).
- With no slug and no name: the orders that main showed since your last go. An older order stays closed until you name it.

The rest of the message goes to main as usual. Main starts only the open orders. If main thinks that you did not mean to start them, it asks you first.

With the orders csv-export (named 匯出報表) and chart-colors just shown:

| You say | Main can start |
| --- | --- |
| `go` | both |
| `go csv-export`, `go 匯出報表`, `匯出報表 go` | csv-export |
| `ok, go csv-export and chart-colors` | both |
| `go. Also, can the export include the filters?` | both. The question is a new request. |
| `go?`, `don't go yet`, `go to the reports page`, `a go-live plan` | Nothing: these are not a go. |

When main changes an order before go, it needs a new go.

## Orders from your team

In `shared` mode, other people on your team send orders too. Each requester talks to their own Claude Code session with the `order` plugin, and that session writes one complete order as a GitHub issue. Main watches the issues, reviews each order, and starts a lead for it. You still talk to main as before.

```
requester ──▶ /order session ──▶ GitHub issue ──▶ guard ──▶ main reviews ──▶ lead ──▶ PR
you ──────────────────────────▶ main (as before, with go)
```

1. Set `"mode": "shared"` in `.claude/shop.json`. `/shop setup` asks for it.
2. Each requester installs the `order` plugin once, as in [Install](#install), and types `/order` in their clone of the repo. A hook names that session `<prefix>-order`. The requester needs bash, git, jq, and `gh` (signed in), and no Claude Max plan. `/order setup` checks the tools, the account, and the access to the repo. To install the plugin:

   ```
   /plugin marketplace add jiunjiun/coffee
   /plugin install order@coffee
   ```

3. The requester discusses the request. The session looks for the same request in old issues and PRs, reads the code, and shows the order. When the requester says go, it creates the issue. The go follows the same rules as a go to main, see [Saying go](#saying-go): with no go, `shop.sh submit` refuses to create the issue. The first line of the body is a mark that GitHub does not show: `<!-- shop-order -->`.
4. Main starts the guard as soon as main starts, also with no lead. Every 2 minutes, the guard reads the open issues. An issue is an order only when it has the mark and comes from a collaborator of the repo, and not from your own account: main opens your issues after your go. Other issues, for example bug reports, stay as they are. Orders sent while main is off are picked up when main starts.
5. Main reviews only what the requester's session cannot see. It looks for a missing field, a thing that only you can do, a thing outside the repo, a change to CI, or a conflict with running work. It asks you when in doubt. For a missing field, main comments on the issue and closes it, and the requester submits a new one.
6. An order that passes starts with no go from you. The lead gets the order as main reviewed it: an edit of the issue after main read it stops the start, and main reads it again. The PR says `Closes #<n>` and `Requested by @<login>`, so GitHub tells the requester. The PR comes from your account, because the leads run on your computer.
7. Main checks the PR as usual. Then the workflow `shop-merge.yml` merges it and closes the issue, so the PR shows `github-actions[bot]` as the account that merged it, not you. GitHub does not close the issue of a PR that a bot merges, so the workflow does it. `shop.sh ci install` adds the workflow, and only your account can run it. To find who asked for a change later, follow the commit to its PR, `Closes #<n>`, and the author of that issue.
8. To cancel, the requester closes the issue: through the order session, or with the close button on GitHub. The guard tells main, and main closes the PR and the lead. When another collaborator closes the issue, main does not cancel the order: it asks you.

The issue is the full record of an order: every fact in the brief of a lead is also in the issue. This version handles text only: logs, code, and config go into the issue as text.

A merge by `github-actions[bot]` does not start other workflows. If a push to the default branch deploys your project, the merge of a requester's order does not deploy it.

Who can send orders depends on who owns the repo:

| Repo owner | Requesters | Can a requester push? |
| --- | --- | --- |
| A personal account | Collaborators always have write access. | Yes. Protect the default branch with branch protection or a ruleset. |
| An organization | Give them the Read role, for example through a team. The base permission of the organization makes every member a collaborator too. | No. |

The `order` plugin works in the terminal and the desktop app. It does not work in claude.ai/code, which loads no plugins.

## Guardrails

- Only a go from you opens `shop.sh lead` and `shop.sh queue`, and only for the orders that the go opens. One go starts each order once. In the order session, only a go from the requester opens `shop.sh submit`, with the same rules.
- A lead cannot run `gh pr merge`, and a lead or helper cannot run `gh workflow run`. A helper cannot push and cannot run `gh pr`. A lead or helper cannot run `claude --bg` directly.
- A lead or helper works on its own. It asks no questions, to main or to you. It decides each open point, and the lead lists its decisions in the `Decisions` section of the PR. Main reports them to you with the result.
- A lead or helper cannot force-push or skip the git hooks with `--no-verify`. In any other session, the same rules apply in the turn that starts this skill, for example `/shop commit`.
- `shop.sh` reads the limits from `.claude/shop.json` in the main checkout. A PR cannot raise its own limits.
- In `shared` mode, an issue is an order only when it has the order mark and comes from a collaborator of the repo, and not from main's account. `shop.sh lead --issue` checks this on GitHub, and starts one lead per issue. Main treats the text of an issue as data, not as instructions. These checks are in `shop.sh`, so they do not depend on what a session decides:
  - Main and the lead read an order with `shop.sh issue`, which leaves out the comments of other accounts. Main's read saves the order. `shop.sh lead --issue` refuses an order that changed after that, and the lead reads the saved text, not the issue as it is later.
  - Main writes the brief of a requester's order to a file, and chooses the slug itself. No command that main writes holds the requester's text, and the lead gets the order as a file to read, not as words from you.
  - `shop.sh merge` merges only a branch that a worktree of this repo holds. The PR of a requester's order must close its issue, so the order cannot become a merge under your account.
  - The sessions read PR comments with `shop.sh feedback`. It shows the comments of your account and of the Claude review app, and counts the others.
  - The guard does not print the title of an order: a title can copy a line of the guard.
- The optional git hooks stop Claude sessions from committing or pushing on the default branch. Your own shell does not use them.
- The role comes from the session name. This prevents mistakes. It is not a security boundary.

## Requirements

- **Claude Code.** The skill uses `claude --bg`, `claude agents`, `claude attach`, and Claude Code hooks. It was tested only with Claude Code 2.1.318. It was not tested with other coding agents, for example Codex.
- **The pstack plugin.** Each lead starts with `/poteto-mode` from [pstack](https://github.com/cursor/plugins/tree/main/pstack), a set of engineering skills by another author. It makes the lead apply strict engineering rules while it plans, builds, and verifies. Install it before you use this skill. See [Install](#install).
- **A Claude Max plan of $100 per month or higher.** The $200 per month plan works best. With the default limits, up to 9 sessions run at the same time (3 leads, each with 2 helpers), and the CI reviews use the same account.
- **Auto mode.** Background sessions start with `--permission-mode auto`. Your account must allow it.
- **Tools:** bash, git, `gh` (signed in), jq, python3, curl, pgrep, and on macOS lsof. The tests also need yq. `/shop commit` scans for secrets with [gitleaks](https://github.com/gitleaks/gitleaks) when it is installed.
- **A GitHub repository** with a remote named `origin`.
- Tested on macOS. On Linux, one end-to-end run passed.

## Install

1. Install the pstack plugin. In Claude Code, type:

   ```
   /plugin marketplace add cursor/plugins
   /plugin install pstack@cursor-plugins
   ```

2. Add this marketplace, and install the `shop` plugin:

   ```
   /plugin marketplace add jiunjiun/coffee
   /plugin install shop@coffee
   ```

   The plugin adds three hooks. The SessionStart hook tells a main session its role. The UserPromptSubmit hook names a session main on `/shop main`, and records your `go`. It exits at once for every other prompt. The Stop hook stops main from ending a turn while the guard has work and does not run. The `order` plugin runs the same script from the same SessionStart and UserPromptSubmit hooks: a change to the go rules changes both plugins. It adds a PreToolUse hook: the order session cannot use the Edit, Write, and NotebookEdit tools, so it writes orders and does not change the requester's clone.

3. Open Claude Code in your project root, and type `/shop setup`. Claude does these steps with you:
   - Picks a session name prefix, for example `ac-web`, and writes `.claude/shop.json`.
   - Makes sure that pstack is on.
   - Confirms that the tools are there, `gh` works, `.scratch/` is git-ignored, the folder is trusted, and `origin/HEAD` points to the default branch.
   - Offers the git hooks that keep Claude sessions off the default branch.
   - Asks which commit skill the leads use, when your machine has another one.
   - Offers the two review workflows, and tells you how to store the `CLAUDE_CODE_OAUTH_TOKEN` secret.
   - Adds a short shop section to the project's `CLAUDE.md`.

## Use

- Start main: type `/shop main` in a session of the project, or run `claude -n <prefix>-main`.
- Tell main what you want. Reply `go` to the order.
- Open the status page: type `/shop web`. It runs on `http://localhost:8766`, or on the next free port up to 8775. It shows each feature, its step, its PR, its CI, and what needs you.
- See the sessions and worktrees: ask main. It runs `shop.sh status`.
- Commit and push in any session: type `/shop commit`. See [Commits](#commits).

## Configuration

`.claude/shop.json` in the project root. Only `prefix` is required:

```json
{ "prefix": "ac-web", "mode": "solo", "max_leads": 3, "max_helpers": 2, "lead_skill": "/poteto-mode", "commit_skill": "/shop commit" }
```

| Key | Default | Meaning |
| --- | --- | --- |
| `prefix` | none | The first part of each session name. It must not match the sessions of another project. |
| `mode` | `solo` | `solo`: only you start orders. `shared`: requesters also send orders as GitHub issues. See [Orders from your team](#orders-from-your-team). |
| `max_leads` | 3 | Leads that run at the same time. |
| `max_helpers` | 2 | Helpers for each lead. |
| `lead_skill` | `/poteto-mode` | The skill that each lead runs first. |
| `commit_skill` | `"/shop commit"` | The skill that each lead commits and pushes with, for example your own `/commit`. |

The project's `CLAUDE.md` decides how to verify a change, which resources take one actor at a time, and which PRs the owner merges.

### Commits

A lead commits and pushes with `/shop commit`, unless `commit_skill` names another skill. You can also type `/shop commit` in any session. It does not ask questions. It runs these steps, and then reports what it did:

1. Plans the commits by concern. It leaves out secrets and files over 5 MB.
2. Asks a subagent which changed files must not be committed now.
3. Runs a security review, `/simplify`, and `/code-review`. On a branch, it skips each review that a CI workflow runs on the PR.
4. Runs the project's linter and tests.
5. Scans the staged files for secrets with gitleaks, when gitleaks is installed.
6. Commits. It follows the commit message rules in the project's `CLAUDE.md`. With no rules, it uses conventional commits in English, with a short body in [ASD-STE100](https://www.asd-ste100.org/) style: short sentences, active voice, simple words.
7. Pushes. When the remote has new commits, it rebases and pushes again. It never force-pushes.

The full steps are in [references/commit.md](plugins/shop/references/commit.md).

## Commands

The sessions run these. You seldom need them.

| Command | Who | What it does |
| --- | --- | --- |
| `shop.sh order <slug> <name>` | main, order | Records an order. It has no number until its GitHub issue at go. |
| `shop.sh submit <slug> <title>` | order | Creates the GitHub issue of an order, with the order mark, from the order text on stdin. It needs the requester's go for that order. |
| `shop.sh lead [--issue <n>] <type> <slug> <goal> [brief]` | main | Creates the worktree and branch, and starts a lead. `type` is feat, fix, chore, docs, refactor, or test. It needs your go for that order, or with `--issue`, an open order from a collaborator with no lead yet, unchanged since main read it. With `--issue`, it reads the brief from `.scratch/shop/brief-<n>.md`. |
| `shop.sh queue [--issue <n>] <slug> <goal>` | main | Keeps your go, or an order from a requester, for a feature that must wait. |
| `shop.sh issue <n>` | main, lead | Shows an issue with only the comments of its author and of main's account. Main's read saves the order. A lead of a requester's order gets the text that main read. |
| `shop.sh feedback <pr>` | main, lead | Shows the PR comments of main's account and of the Claude review app, and counts the comments of other accounts. |
| `shop.sh merge <pr> <sha>` | main | Squash-merges the PR at the commit that main checked. In `shared` mode, only a branch that a worktree of this repo holds, and the PR of a requester's order must close its issue. For the order of a requester, the workflow `shop-merge.yml` merges it as `github-actions[bot]`. |
| `shop.sh helper <job> [goal]` | lead | Starts a helper in its own worktree, at the lead's last commit. |
| `shop.sh close [--discard] <name>` | main, lead | Stops a session and removes its worktree. For a lead, also removes the branch when its work is merged; an unmerged branch stays. It refuses while the PR is open or the worktree has changes. `--discard` is for a cancelled order: it closes the PR, and drops the changes and the branch. |
| `shop.sh guard` | main | Waits in the background. It ends when a session needs main. In `shared` mode, it also ends on an order or a cancel from a requester, and it waits with no session. |
| `shop.sh hold <resource> <slug\|free>` | main | Records who uses a shared resource. |
| `shop.sh note <text>` | any shop session | Shows the current step on the status page. |
| `shop.sh status` | any | Lists the shop sessions and the worktrees. |
| `shop.sh web` | any | Starts the status page and opens it. |
| `shop.sh ci [install]` | any | Reports or adds the review workflows, and in `shared` mode the merge workflow. Reports the token secret. |
| `shop.sh token` | you, in a normal terminal | Creates the OAuth token and stores it as a repo secret. It refuses to run through Claude, so the token stays out of the conversation. |

## Files

| Path | Content |
| --- | --- |
| `.claude/shop.json` | The configuration. Commit it. |
| `.scratch/<slug>/wt` | The worktree of a lead. |
| `.scratch/<slug>/<job>` | The worktree of a helper. |
| `.scratch/shop/events.jsonl` | The event log that the status page reads. |
| `.scratch/shop/approved/` | One file for each order that has a go. A lead start, or a submit in the order session, removes it. |
| `.scratch/shop/orders/` | In `shared` mode, each order as main read it, and as its lead gets it. |
| `.scratch/shop/leads/` | In `shared` mode, the issue of each lead that works on a requester's order, until `shop.sh close`. `shop.sh merge` reads it. |
| `.scratch/shop/brief-<n>.md` | In `shared` mode, the brief that main writes for the lead of issue `<n>`. `shop.sh lead` deletes it when the lead starts. |
| `.scratch/shop/` (other files) | The guard state. |

`.scratch/` must be in `.gitignore`.

## Limits

- The skill reads Claude Code files that are not a public API: `~/.claude/sessions/<pid>.json`, the `CLAUDE_PID` variable, the subagent logs under `~/.claude/projects/`, and the shell snapshot path in the process list. A new Claude Code version can change them. Then every session counts as plain, and `shop.sh` refuses to start sessions.
- The status page and the stall check use the same files. If they change, the page shows no quiet time, and main gets no stall alert.
- The go rules are fixed patterns. A name with a typo matches nothing, so that go opens every order that main showed since your last go. A slug or name anywhere in the message opens its order, also in `go chart-colors, not csv-export yet`. Main starts only the ones that your message means, and tells you which ones it starts.

## Tests

```sh
plugins/shop/scripts/test.sh              # shop.sh and the status page, with fake claude and gh commands
plugins/shop/templates/githooks/test.sh   # the git hooks, in throwaway repos
```

Both print `PASS` when every check passes.

## License

MIT. See [LICENSE](LICENSE).
