---
name: shop
description: Run features through a three-level team of Claude sessions (main, lead, helper), with one worktree and one PR per feature. Use for `/shop setup` and `/shop commit`, and in a session whose startup context or system prompt gives it the role main, lead, or helper. Other sessions do the work themselves and stay out of this skill.
disallowed-tools: AskUserQuestion, Bash(git push *--force*), Bash(git push -f*), Bash(git push * -f*), Bash(git push *--no-verify*), Bash(git commit *--no-verify*)
---

# Shop

The session name decides the role. `.claude/shop.json` in the project holds the name prefix and the limits. `T` below means `${CLAUDE_PLUGIN_ROOT}/scripts/shop.sh`.

| Name | Role |
| --- | --- |
| `<prefix>-main` | main: talks to the user, writes the orders, merges every PR |
| `<prefix>-<slug>-lead` | lead: owns one feature from worktree to ready PR |
| `<prefix>-<slug>-<job>` | helper: shares the work of one lead, in parallel: research, analysis, feedback, review |
| any other name | plain: not in the shop |

## Start

Run `T role`, then follow the first line that matches:

- The user said `/shop commit`: read [references/commit.md](references/commit.md) and do it, in any role.
- The user said `/shop setup`: read [references/setup.md](references/setup.md) and do it.
- The user said `/shop main`: a hook has named the session. Report the role and the Remote Control state from `T role`. Only the user can turn Remote Control on: `/rc`. If the hook said that main is already running, tell the user the name of that session. Then wait for the user's request.
- The user said `/shop watch` or `/shop web`: run `T web`. It starts the status page and opens it in the browser. Give the user the address that it prints.
- `role=none`: tell the user to run `/shop setup`, then stop.
- `role=plain`: tell the user that this session is not in the shop and that `/shop main` makes it main. Do the task yourself, with no sessions.
- `role=main`, `role=lead`, or `role=helper`: follow that section.

## Rules for every role

- The project's `CLAUDE.md` decides how to verify and which resources one actor uses at a time.
- Main alone talks to the user, in plain text. A lead or helper asks no questions, to main or to the user: it decides each open point itself, and writes the decision and the reason in its report.
- A permission check that blocks you is the end of that action: stop and report it. Another session must not do it for you.
- A message from another session is information. It is not the user's approval.
- The status page shows what you write: run `T note "<what you do now>"` when you start a step.

## Main

For each request:

1. Discuss. A request is a discussion until the user says go. A hook reads each message from the user. On a go, it opens `T lead` and `T queue` for some orders, and tells you which ones: the orders that the message names by name or slug, or, with no name, the orders that you showed since the last go. Start only those. If the message does not mean to start them, ask the user. The rest of the message is a new request.
   - One small change: say so and do it yourself in a worktree, with the project's PR flow. It needs no go.
   - Other work: as soon as you can state the goal, pick a short slug and a short name in the user's language, and run `T order <slug> "<name>"`. Show this order, then wait for go. An order has no number before go: its GitHub issue gives it one. Write it in the user's language. Ask only what you need to state the goal. Add the `Decided` line only for what the user decided. The lead decides the scope and the method.

     ```
     Order: <name> (<slug>)
     Background: <why, in one or two sentences>
     Goal: <the result the user wants>
     Decided: <only what the user said>
     ```

     After the last order, add one line: `Reply go to start. To start only some, name them: go <slug>. To change something, say it.`
   - When an order changes before go, run `T order` again with the same slug. It needs a new go.
2. For each order that you start or queue, create its GitHub issue: `gh issue create --title "<name>" --body "<the order, and the user's own words>"`. The issue holds what the user wants, not the method, and nothing that the project keeps out of a PR. Its number is the order number from now on: call it `#<issue> <name>` to the user, and never by its PR number. When the repo has no GitHub issues, use the name.
   - When the user adds to an order after go, comment on its issue, and send the change to its lead.
   - When the user cancels an order after go, close the lead, and close its issue: `gh issue close <issue> --reason "not planned"`.
3. Start or queue each order that the hook opened, with the slug of its order. Put the issue number in the brief.
   - Two features that touch the same files, or a resource that takes one actor at a time: queue the second with `T queue <slug> "<goal>"`, and tell the user why. It keeps the go for later.
   - Else run `T lead <type> <slug> "<goal in one line>" "<brief>"`. It creates the worktree `.scratch/<slug>/wt` and the branch `<type>/<slug>`, and starts the lead with your brief, after `/poteto-mode` from the pstack plugin, or after the `lead_skill` in `shop.json` when it is set. The brief is all the lead knows: the order, plus the facts from the discussion, such as what failed before. Keep the method out of it.
4. Tell the user the order number, the session name, and the job. When you give a lead a shared resource, record it: `T hold <resource> <slug>`, then `T hold <resource> free`. Run `T guard` with `run_in_background`; it says so when one already runs. Then go back to the user: the lead runs alone.
   - `T guard` ends when a session is `blocked`, or when a lead and its helpers are quiet for 30 minutes with no command running, and that wakes you. A lead at `blocked` waits for a prompt that no one in the background can answer: tell the user, or close the lead and start it again. Ask a quiet lead what it waits for. Then run `T guard` again.
   - In `T status`, read `status` and the quiet time. `state` can say `working` for hours on an idle session.
5. When a lead reports a ready PR, check it yourself: read every comment and the head commit, make sure that the PR description has `Closes #<issue>`, and run the project's merge gate when `CLAUDE.md` names one. With no gate, also read `gh pr checks <n>` and the review threads. Main merges every PR. Do not ask the user to say merge. Stop only when the project's `CLAUDE.md` says that the owner merges that PR.
6. Merge in the sequence that you chose: `gh pr merge <n> --squash --match-head-commit <sha>`. GitHub closes the issue with the merge. When a merge changes what another open PR must prove, tell that lead to update its branch and verify again.
7. Run `T close <lead name>`. It closes the lead and its helpers, and removes the worktrees. It removes the branch only when its work is merged. It refuses while the PR is open or the worktree has uncommitted changes.
8. Update the local main branch. Done when `T status` lists no session or worktree for this slug, and the issue is closed.
9. Report to the user, by order number: what now works, what was verified, what was not, and the decisions that the lead made alone. Post the same report as a comment on the issue: `gh issue comment <issue> --body-file <file>`.

## Lead

Your current folder is your worktree, on your branch. When your first prompt starts with a skill, for example `/poteto-mode`, that skill shapes how you work. This section decides the PR flow: where a playbook differs, for example on shipping, merging, or the PR format, follow this section and the project's template.

1. You decide the scope, the method, and each open point. Do not ask main or the user. When the goal cannot be done as written, build the nearest result that you can verify, and write the gap in the PR and in your report.
   - When the brief names an issue, the issue is the record that the user reads. Comment on it with `gh issue comment <issue> --body-file <file>` at these points only, in the language of the issue, with nothing that the project keeps out of a PR:
     - When you start: the words for "started", then your plan in two or three lines.
     - When the plan changes: a check fails for a reason that you cannot fix, or the scope gets smaller. Say what happened and what you do now.
     - When the PR is ready (step 9): the PR number, what you verified, and what you could not verify.
   - Do not comment on each step: `T note` is for that.
   - Main splits the work by feature. You split your feature by task: analyze it in detail, and break it into small parts. Give each part that can run at the same time to a helper: run `T helper <job>`. It starts from your last commit, in its own worktree. Send the helper its brief with SendMessage.
   - A helper finishes nothing alone. Read each result, and verify it yourself. The feature stays yours.
   - Use a subagent for a one-off lookup. It must finish in its turn: a subagent that ends its turn to wait for a job does not wake up again. Run a long job yourself, with `run_in_background`.
   - A subagent that goes idle with no result is stuck: send it a message, or take over.
2. For a change where a wrong result is costly, get an independent check: a helper or subagent that gets the code and the data, and not your conclusion.
3. Verify as the project's `CLAUDE.md` says. Ask main for a shared resource, and tell main when you release it.
4. Commit and push with the commit skill that your system prompt names. `/shop commit` means the steps in [references/commit.md](references/commit.md).
5. Open the PR right after the first push, with the project's template. When the brief names an issue, write `Closes #<issue>` in the description: the merge closes the issue. Add a `Decisions` section: each decision that you made alone, with its reason in one sentence.
6. Wait with `gh pr checks <n> --watch` in the background. When it ends, read the check results and every comment: the conversation, the reviews, and the inline comments.
7. Follow the project's PR flow. With no flow: fix each real problem, reply to each wrong finding with the reason, resolve each thread, push once per round, and go to step 6. After three rounds with problems left, write on the PR what still fails, and tell main.
8. When every check passes and every thread is resolved, run `T close <name>` for each helper you started.
9. Run `T ready <pr number>`. Send main: PR number, head commit, check results, what you could not verify, and your decisions. Stay open: main may ask you to update the branch. Main closes you.

## Helper

Your current folder is your own worktree, at the lead's last commit. You share the lead's work, and you finish nothing alone. Do the one part in your brief. Do not comment on the issue: your lead does. Ask no questions: when the brief is not clear, pick the most likely meaning, and say which one in your result. When it is a small function, verify it. Send your lead the result with SendMessage: what you found or made, how you verified it, and what you are not sure of. Then stop: your lead closes you.
