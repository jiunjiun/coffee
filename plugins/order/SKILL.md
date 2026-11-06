---
name: order
description: Discuss a request with the user, then submit it as one complete order, a GitHub issue that the shop main session of this repository reviews and builds. Use only when the user types /order.
disable-model-invocation: true
disallowed-tools: Edit, Write, NotebookEdit
---

# Order

From now until the session ends, these rules apply to every message:

- You help the user write orders for this repository. You do not build them. The shop main session reads each order as a GitHub issue, reviews it, and gives it to a lead, who builds it and opens a PR.
- Do not change the repository: no edits, no new files, no commits, no branches. Read code only to check what a request needs.
- Each request that the user describes becomes an order draft. The issue is all that the shop knows about the request: put every fact from the discussion in it.
- Create the issue only when the user says to submit it, in any words, for example "submit" or "送出". Creating the issue is the submit.
- After a submit, stay in this mode for the next request.
- Write the content in the user's language. Keep the field names in English.

## The order

```
Order: <name> (<slug>)
Background: <why, in one or two sentences>
Goal: <the result the user wants>
Done when: <how to check that it is done>
Decided: <only what the user said>
Facts: <what was tried, what failed, and the limits>
Materials: <logs, code, and config, as text>
User's words: <the key words of the user, quoted>
```

- Ask only what you need to fill the fields. Do not choose the method: the lead decides the scope and the method.
- `Decided`: write "none" when the user decided nothing.
- `Facts`: a limit can be a deadline, or a system that must not change.
- `Materials`: put each one in a `<details>` block. The body and each comment of an issue take at most 65,536 characters: put the rest in comments after the submit. This version does not handle images or files: describe them in text.
- The slug: lowercase letters, digits, and hyphens. Not `main` or `shop`.

## Before you submit

1. Look for the same request: `gh issue list --state all --search "<key words>"` and `gh pr list --state all --search "<key words>"`. Show the user each close match, and suggest a comment on the old issue instead of a new order.
2. Check that the order can be built: read the related code. Name each thing that only a person can give, for example a key, an account, or access to a system.
3. Check the account: `gh auth status`. The issue goes out under this account, and the shop accepts orders only from the collaborators of the repository.
4. Show the full order. Wait for the user to submit it or change it.

## Submit

1. Create the issue. The first line of the body is `<!-- shop-order -->`: it tells the shop that the issue is an order. GitHub does not show it. Then comes the full order:

   ```bash
   gh issue create --title "<name>" --body-file - <<'EOF'
   <!-- shop-order -->
   <the full order>
   EOF
   ```

2. Put each part of `Materials` that did not fit into a comment: `gh issue comment <n> --body-file -`.
3. Give the user the issue URL, and tell the user:
   - The shop main session reviews the order. When something is missing, main comments on the issue and closes it. Fix the order here, and submit a new one.
   - The PR closes the issue when it merges, and GitHub sends a notification.
   - To cancel the order: `gh issue close <n> --reason "not planned"`.
