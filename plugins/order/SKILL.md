---
name: order
description: Discuss a request with the user, then submit it as one complete order, a GitHub issue that the shop main session of this repository reviews and builds. Use only when the user types /order.
disable-model-invocation: true
disallowed-tools: Edit, Write, NotebookEdit
---

# Order

`T` below means `${CLAUDE_PLUGIN_ROOT}/scripts/shop.sh`, the script of the shop plugin. The order session and the shop main session use the same go.

## Start

The user typed `/order`: a hook has named the session. Run `T role`, then follow the first line that matches:

- The hook said that this session keeps its name, or that the order session is already running: tell the user what it said, then stop.
- `role=none`: tell the user that this repository has no shop, because `.claude/shop.json` is missing. Then stop.
- `mode=solo`: tell the user that this shop takes no orders from requesters, because its mode is solo. Then stop.
- `role=order`: follow the rules below.
- Any other role: tell the user what `T role` printed, and that the session did not get the order name. Then stop.

From now until the session ends, these rules apply to every message:

- You help the user write orders for this repository. You do not build them. The shop main session reads each order as a GitHub issue, reviews it, and gives it to a lead, who builds it and opens a PR.
- Do not change the repository: no edits, no new files, no commits, no branches. Read code only to check what a request needs.
- Each request that the user describes becomes an order draft. The issue is all that the shop knows about the request: put every fact from the discussion in it.
- A hook reads each message from the user. On a go, it opens `T submit` for some orders, and tells you which ones: the orders that the message names by name or slug, or, with no name, the orders that you showed since the last go. Submit only those. If the message does not mean to submit them, ask the user. The rest of the message is a new request.
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
4. Record each order with `T order <slug> "<name>"`, then show the full order. After the last order, add one line: `Reply go to submit. To submit only some, name them: go <slug>. To change something, say it.` When you change an order, record it again: it needs a new go.

## Submit

1. Submit each order that the go opened. `T submit` adds `<!-- shop-order -->` as the first line of the body: it tells the shop that the issue is an order, and GitHub does not show it. It creates the issue and prints its URL. It refuses an order with no go:

   ```bash
   T submit <slug> "<name>" <<'SHOP_ORDER_END'
   <the full order>
   SHOP_ORDER_END
   ```

   The order can hold code with its own `EOF` line: keep this end word, so that such a line does not end the text early.

2. Put each part of `Materials` that did not fit into a comment: `gh issue comment <n> --body-file -`.
3. Give the user the issue URL, and tell the user:
   - The shop main session reviews the order. When something is missing, main comments on the issue and closes it. Fix the order here, and submit a new one.
   - The PR closes the issue when it merges, and GitHub sends a notification.
   - To cancel the order: `gh issue close <n> --reason "not planned"`.
