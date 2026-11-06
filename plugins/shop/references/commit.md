# Commit

The steps of `/shop commit`. A lead runs them to commit and push its branch, unless `shop.json` names another `commit_skill`. Any session can run them with `/shop commit`.

## Workflow

Complete these steps in order. Do not ask the user any questions. Make each decision yourself and record it in the report (step 8).

### 1. Plan the commits

Read all current changes: staged, unstaged, and untracked.

Leave out secrets and credentials in any form, including private keys and keystores, and large binary files. Find the large files with `find . -type f -size +5M -not -path './.git/*'`.

Group the other files into logical commits by concern. All changes to one file go in one commit.

### 2. Check and stage the files

Invoke the Agent tool with `subagent_type: general-purpose`. Pass only this task, with the absolute repository path:

> Read-only task. Do not change files or git state. In the repository at `<path>`, run `git status --short`, `git diff`, and `git diff --staged`, and read the untracked files. List the files that should NOT be committed now, with a one-line reason for each. Flag secrets or credentials, debug or temporary code, unfinished work, and generated or build output. If every file is fine, answer `NONE`.

For each listed file whose reason holds, fix it or leave it out.

Stage exactly the files in the plan.

### 3. Review

Run the reviews unless the staged change is only documentation, generated code, a version or dependency bump, a rename, or a comment or whitespace change.

On a non-default branch, skip a review when a workflow in `.github/workflows/` runs it on `pull_request`.

A staged file is high-risk when it handles auth, payment, stored data migrations, CI, deploy, or install, or when the project marks its path as protected.

Run these in order:

1. Get the security review from an independent subagent. Invoke the Agent tool with `subagent_type: general-purpose`. Pass only this task, with the absolute repository path:

   > Read-only task. Do not change files or git state. In the repository at `<path>`, run `git diff --staged`. Read the project `CLAUDE.md` and the code around each change. Compare the change with the security patterns that the project already uses. Trace untrusted input to each sensitive operation.
   >
   > Report only vulnerabilities that this change adds. Score each finding from 1 to 10. Report only a score of 8 or higher (at least 80% confident that the issue is real and exploitable). Report a new unsafe function even when no code calls it yet.
   >
   > A change that breaks a security or privacy rule in `CLAUDE.md` is a finding, even when a rule below excludes that type of issue.
   >
   > Categories to check:
   > - Input validation: SQL, command, XXE, template, and NoSQL injection, path traversal, SSRF
   > - Authentication and authorization: auth bypass, privilege escalation, session and JWT flaws, broken access control, missing object ownership checks
   > - Crypto and secrets: hard-coded production keys, passwords, or tokens; weak algorithms; improper key storage; weak randomness; certificate validation bypass; sensitive data sent over plain HTTP
   > - Injection and code execution: unsafe deserialization, `eval` injection, XSS, untrusted input in CI scripts
   > - Data exposure: sensitive data in logs, PII handling violations, data sent to a new host, API data leakage, debug information exposure
   > - Supply chain: a new dependency with a misspelled or unfamiliar name, or a new install script
   >
   > Always report a hard-coded production secret. Do not report a test fixture value.
   >
   > Do not report:
   > - Denial of service or resource exhaustion
   > - Rate limiting concerns
   > - Memory safety issues in memory-safe languages
   > - Findings only in test files
   > - Log spoofing, or missing hardening without a concrete vulnerability
   > - Theoretical issues, outdated dependencies, or findings in documentation files
   > - Attacks that require control of environment variables or CLI flags
   >
   > For each finding, record the file, the line, the category, the severity, the score, the exploit scenario, and the fix. If there are none, answer `NONE`.

2. Invoke the `/simplify` skill via the Skill tool.
3. Invoke the `/code-review` skill via the Skill tool with args `medium --fix`, or `high --fix` when a staged file is high-risk.

Run each review once. Fix each real finding. Write each false positive and its reason in the report.

After the reviews, stage each file that the reviews changed or created, except a file that you left out of the plan.

### 4. Lint and verify

Run the project's linter on the staged files.

Skip the tests when the staged change is only documentation, comments, or whitespace.

Run the test, build, or type-check command in the project `CLAUDE.md`, or detect it from the project files. When CI runs the full tests on the pull request, run only the tests for the staged files. Do not run a command that changes a device or a remote system. Use a Bash timeout of 600000 ms.

If the command times out, rerun it with `run_in_background`. If the project has no check command, write `Not verified` and the reason in the report.

### 5. Scan for secrets

When `gitleaks` is installed, run `gitleaks git --pre-commit --staged --redact --no-banner -v .`. When it is not installed, write `Secret scan: skipped, gitleaks is not installed` in the report.

If the scan finds a secret, fix it and report it, then run the check and the scan again. If you cannot fix it, unstage the file, and list the file, the line, and the `RuleID` in the report.

### 6. Commit

Create each planned commit on the current branch, with only the files of that commit. Do not create a new branch, even on the default branch.

Follow the commit message rules in the project's `CLAUDE.md`. With no rules, use this format:
- Conventional commit type
- English only, for the title and the body
- **Title**: imperative mood, under 72 characters
- **Body**: 1–3 sentences on why the change was made. The diff already shows what changed. Follow ASD-STE100: short sentences, active voice, simple words.

### 7. Push

Skip this step when the repository has no remote or when HEAD is detached.

Run `git push`, with `-u origin HEAD` when the branch has no upstream.

If the remote rejects the push because it has new commits, run `git pull --rebase --autostash`, resolve conflicts, and continue with `git -c core.editor=true rebase --continue`. Run the step 4 check again, then push again. Repeat until the push passes. If the Fix Rule stops you during a rebase, run `git rebase --abort`.

### 8. Report

Run `git log --oneline -<N>`, where N is the number of new commits. When a pull request replaces a local review, report whether that pull request is open. Report in the user's language. Leave out empty sections:

```
Created 2 commits:
- a1b2c3d feat: add user login (3 files)
- d4e5f6a docs: update setup guide (1 file)

Review: ran (3 .rb files); /code-review runs on the pull request
Findings: 3 total, 2 fixed, 1 not fixed
- app/models/user.rb:42: false positive, the caller already checks for nil
Files changed by the review: app/models/user.rb
Verification: bin/rails test (212 runs, 0 failures)
Secret scan: no findings
Risk: high (.github/workflows/deploy.yml)
Not committed:
- tmp/try.rb: the subagent marked it as an unfinished experiment
- .env: sensitive file
Push: pushed to origin/feature/login
PR: no open pull request, the review has not run
Undo: git revert a1b2c3d d4e5f6a
```

## Fix Rule

Fix the root cause of each lint, check, hook, or push failure. Stage the fix, commit it when the commit already exists, and run the failed command again until it passes.

- If a project dependency is missing, install it with the project's package manager, then continue. If a system tool is missing, do not install it: write the tool and the step that needs it in the report.
- Never delete, skip, or weaken a test, a lint rule, a git hook, or a secret scan to get a pass. Never force push. Never use `--no-verify`.
- Stop only when a permission check blocks the action, when an outside system is down, when a command hangs, or when the fix needs something that only the user can give, for example an account, a password, or a physical device. Do not commit. Write the cause and the action that the user must take in the report.
