#!/bin/bash
# Runs shop.sh in a throwaway repo with fake claude and gh commands. Usage: scripts/test.sh
shop=$(cd "$(dirname "$0")" && pwd)/shop.sh
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'pkill -f "watch.py $tmp/repo"; rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$tmp/bin" "$tmp/.claude/sessions"
cat >"$tmp/bin/claude" <<STUB
#!/bin/bash
case \$1 in
  agents) cat "$tmp/agents.json" ;;
  stop|rm) echo "\$*" >>"$tmp/closed.log" ;;
  *)
    printf '%s\n' "\$@" >"$tmp/spawn.log"
    [[ -f $tmp/untrusted ]] && { echo "Workspace not trusted"; exit 1; }
    echo "backgrounded · abc"
    ;;
esac
STUB
cat >"$tmp/bin/gh" <<STUB
#!/bin/bash
[[ \$1 == secret ]] && { cat "$tmp/secrets" 2>/dev/null; exit; }
[[ \$1 == api ]] && { echo '{"data":{"repository":{"pullRequests":{"nodes":[{"number":7,"reviewThreads":{"nodes":[{"isResolved":false},{"isResolved":true}]}}]}}}}'; exit; }
[[ \$* == *--limit* ]] && { cat "$tmp/prs.json" 2>/dev/null || echo '[]'; exit; }
[[ \$* == *"--state merged"* ]] && { cat "$tmp/merged-pr" 2>/dev/null; exit; }
cat "$tmp/open-pr" 2>/dev/null
STUB
cat >"$tmp/bin/open" <<STUB
#!/bin/bash
echo "\$1" >>"$tmp/opened.log"
STUB
chmod +x "$tmp/bin/claude" "$tmp/bin/gh" "$tmp/bin/open"
export PATH="$tmp/bin:$PATH" HOME="$tmp" CLAUDE_PID=1
unset CLAUDE_CODE_BRIDGE_SESSION_ID
echo '[]' >"$tmp/agents.json"
git init -q --bare -b main "$tmp/origin.git"
git init -q -b main "$tmp/repo"
cd "$tmp/repo" || exit 1
git remote add origin "$tmp/origin.git"
mkdir .claude
echo '{"prefix":"ac-web","max_leads":1,"max_helpers":1}' >.claude/shop.json
printf '.scratch/\n' >.gitignore
git add . && git commit -q -m first && git push -q origin main

failed=0
as() { echo "{\"name\":\"$1\"}" >"$tmp/.claude/sessions/1.json"; }
want() {  # expected text, label, actual
  [[ $3 == *"$1"* ]] || { echo "FAIL $2: wanted '$1', got: $3"; failed=1; }
}
run() { "$shop" "$@" 2>&1; }
agents_are() { echo "$1" >"$tmp/agents.json"; }
bg() { echo "{\"name\":\"$1\",\"kind\":\"background\",\"id\":\"$1\"}"; }

as ac-web-main; want role=main "main name" "$(run role)"
as ac-web-dark-mode-lead; want role=lead "lead name" "$(run role)"
as ac-web-dark-mode-verify; want role=helper "helper name" "$(run role)"
as web-app-main; want role=plain "other project name" "$(run role)"
as ""; want role=plain "no name" "$(run role)"
as ac-webx-main; want role=plain "longer prefix" "$(run role)"

as ac-web-main; want "Shop role: main" "hook main" "$(echo '{}' | "$shop" hook)"
for n in web-app-main ac-web-a-lead ac-web-a-verify; do
  as "$n"; [[ -z $(echo '{}' | "$shop" hook) ]] || { echo "FAIL hook prints nothing for $n"; failed=1; }
done

typed() { jq -n --arg p "$1" '{prompt: $p}' | "$shop" prompt; }
as web-app-main; want '"sessionTitle": "ac-web-main"' "/shop main names the session" "$(typed '/shop main')"
want '"sessionTitle": "ac-web-main"' "/shop:shop main names the session" "$(typed '/shop:shop main')"
for p in 'hello' '/shop setup' 'please run /shop main' '/shop main now'; do
  [[ -z $(typed "$p") ]] || { echo "FAIL prompt hook stays silent for: $p"; failed=1; }
done
[[ $(typed '/shop main') == *'/rc'* ]] || { echo "FAIL remote control off gets a reminder"; failed=1; }
[[ $(CLAUDE_CODE_BRIDGE_SESSION_ID=s typed '/shop main') != *'/rc'* ]] || { echo "FAIL remote control on gets no reminder"; failed=1; }
agents_are "[$(bg ac-web-main)]"
want "already running" "a second main keeps its name" "$(typed '/shop main')"
[[ $(typed '/shop main') != *sessionTitle* ]] || { echo "FAIL a second main gets no new name"; failed=1; }
as ac-web-main; want '"sessionTitle": "ac-web-main"' "main can repeat the command" "$(typed '/shop main')"
agents_are '[]'

as plain-name; want "needs a main session" "plain cannot start a lead" "$(run lead fix a g)"
as ac-web-a-lead; want "needs a main session" "lead cannot start a lead" "$(run lead fix a g)"
as ac-web-a-verify; want "needs a lead session" "helper cannot start a helper" "$(run helper research)"
as ac-web-main; want "needs a lead session" "main cannot start a helper" "$(run helper research)"
want "slug must" "bad slug" "$(run lead fix Bad_Slug g)"
want "slug must" "slug main" "$(run lead fix main g)"
want "slug must" "slug shop is the state folder" "$(run lead fix shop g)"
want "slug must" "an order checks its slug" "$(run order Dark_Mode g)"
want "slug must" "an order slug is not a path" "$(run order ../events.jsonl g)"
want "slug must" "a queue checks its slug" "$(run queue ../events.jsonl g)"
want "type must" "bad type" "$(run lead wip a g)"

want "has not said go for nogo" "no go, no lead" "$(run lead fix nogo g)"
want "has not said go for nogo" "no go, no queue" "$(run queue nogo g)"
want "order slug=alpha name=匯出報表" "an order gets a name, not a number" "$(run order alpha '匯出報表')"
want "order slug=beta name=深色模式" "a second order" "$(run order beta '深色模式')"
want "order slug=alpha name=匯出 CSV 報表" "an order written again" "$(run order alpha '匯出 CSV 報表')"
approved_list() { ls .scratch/shop/approved 2>/dev/null | sort | paste -sd' ' -; }
said() {  # expected approved orders, prompt
  local out
  out=$(typed "$2")
  [[ $(approved_list) == "$1" ]] || { echo "FAIL go '$2': wanted '$1', got '$(approved_list)'"; failed=1; }
  rm -rf .scratch/shop/approved
  [[ -z $1 || $out == *"open for these orders only"* ]] || { echo "FAIL go '$2' tells main"; failed=1; }
}
as plain-name; said '' go; as ac-web-main
for p in 'goal' 'good' 'go?' 'let us go' 'we need a go-live plan' 'go to the reports page and add a button' '先不要 go，我再想想' "don't go yet" 'cargo build'; do
  said '' "$p"
  [[ -z $(typed "$p") ]] || { echo "FAIL the hook stays silent for: $p"; failed=1; }
done
for p in 'go alpha' 'GO alpha' 'go 匯出 CSV 報表' '匯出 csv 報表 go' 'go匯出 CSV 報表' 'go alpha. Also, can the export include the filters?'; do said alpha "$p"; done
for p in 'go alpha beta' '那就先 go 匯出 CSV 報表、深色模式' 'ok, go alpha and 深色模式'; do said 'alpha beta' "$p"; done
said beta 'go 深色模式，另一張先等等'
said '' 'go 匯出報表'
said '' go
want "no open order matches" "a plain go does not open an older order" "$(typed go)"
run order new0 g >/dev/null
said new0 'go new0'
fresh=0
for p in 'go' 'Go' 'go ' 'go
' 'go 另外我還想到一個問題，有辦法解決嗎' '好，go' 'ok go' 'Go ahead' '那就 go' 'go. Also, can the export include the filters?'; do
  fresh=$((fresh + 1))
  run order "new$fresh" g >/dev/null
  said "new$fresh" "$p"
done
typed 'go alpha' >/dev/null
run order alpha '匯出 CSV 報表，加篩選' >/dev/null
want "has not said go for alpha" "a changed order needs a new go" "$(run lead fix alpha g)"
for s in failed failed2 dark-mode second later; do run order "$s" g >/dev/null; done
typed 'go failed failed2 dark-mode second later' >/dev/null
[[ $(approved_list) == "dark-mode failed failed2 later second" ]] || { echo "FAIL go with slugs: $(approved_list)"; failed=1; }
touch "$tmp/untrusted"
want "cannot start" "failed start reports" "$(run lead fix failed g)"
want "Workspace not trusted" "failed start shows why" "$(run lead fix failed2 g)"
[[ ! -e $tmp/repo/.scratch/failed/wt ]] || { echo "FAIL failed start leaves a worktree"; failed=1; }
[[ -z $(git branch --list 'fix/failed*') ]] || { echo "FAIL failed start leaves a branch"; failed=1; }
rm "$tmp/untrusted"

want "a lead needs a goal" "no goal" "$(run lead fix nogoal)"
want "session=ac-web-dark-mode-lead" "start lead" "$(run lead fix dark-mode 'fix dark' 'the full brief')"
want "/poteto-mode Brief from ac-web-main:" "lead starts with poteto-mode and the brief" "$(cat "$tmp/spawn.log")"
want "the full brief" "lead gets the brief" "$(cat "$tmp/spawn.log")"
[[ $(sed -n 1p "$tmp/spawn.log") == --bg ]] || { echo "FAIL --bg comes first"; failed=1; }
want "Bash(gh pr merge:*)" "lead cannot merge" "$(cat "$tmp/spawn.log")"
want "Commit and push with /shop commit." "lead commits with /shop commit by default" "$(cat "$tmp/spawn.log")"
want "Bash(git push *--force*)" "lead cannot force push" "$(cat "$tmp/spawn.log")"
want "Bash(git commit *--no-verify*)" "lead cannot skip the git hooks" "$(cat "$tmp/spawn.log")"
want "AskUserQuestion" "lead cannot ask the user" "$(cat "$tmp/spawn.log")"
want "ask no questions" "lead works on its own" "$(cat "$tmp/spawn.log")"
want "Bash(claude --bg:*)" "lead cannot call claude --bg" "$(cat "$tmp/spawn.log")"
want "EnterWorktree" "lead cannot enter another worktree" "$(cat "$tmp/spawn.log")"
want "fix/dark-mode" "lead branch" "$(git -C .scratch/dark-mode/wt branch --show-current)"
agents_are "[$(bg ac-web-dark-mode-lead),{\"name\":\"chat-1\",\"kind\":\"interactive\"},{\"kind\":\"background\",\"id\":\"x\",\"name\":null}]"
want "1 of 1 leads" "lead limit" "$(run lead fix second g)"

run queue later 'later goal' >/dev/null
agents_are '[]'
want "session=ac-web-later-lead" "a queued feature keeps its go" "$(run lead fix later 'later goal')"
want "has not said go for later" "a go works once" "$(run lead fix later 'later goal')"
git -C .scratch/later/wt commit -q --allow-empty -m wip
want "Kept fix/later: its work is not merged" "close keeps an unmerged branch" "$(run close ac-web-later-lead)"
[[ -n $(git branch --list fix/later) ]] || { echo "FAIL close keeps an unmerged branch"; failed=1; }
run lead fix second g >/dev/null
want ", fix/second" "close removes a branch with no commit of its own" "$(run close ac-web-second-lead)"
agents_are "[$(bg ac-web-dark-mode-lead)]"
cd .scratch/dark-mode/wt || exit 1
echo '{"prefix":"ac-web","max_helpers":9}' >.claude/shop.json
as ac-web-dark-mode-lead; want "session=ac-web-dark-mode-verify" "start helper" "$(run helper verify)"
git checkout -q .claude/shop.json
want "Bash(gh pr:*)" "helper has no PR commands" "$(cat "$tmp/spawn.log")"
want "Bash(git push:*)" "helper has no push" "$(cat "$tmp/spawn.log")"
want "AskUserQuestion" "helper cannot ask the user" "$(cat "$tmp/spawn.log")"
want "ask no questions" "helper works on its own" "$(cat "$tmp/spawn.log")"
want "Bash(claude --bg:*)" "helper cannot call claude --bg" "$(cat "$tmp/spawn.log")"
[[ -d $tmp/repo/.scratch/dark-mode/verify ]] || { echo "FAIL helper has its own worktree"; failed=1; }
[[ $(cat "$tmp/spawn.log") != */poteto-mode* ]] || { echo "FAIL a helper does not start poteto-mode"; failed=1; }
agents_are "[$(bg ac-web-dark-mode-lead),$(bg ac-web-dark-mode-verify)]"
echo '{"prefix":"ac-web","max_helpers":9}' >.claude/shop.json
want "1 of 1 helpers" "a worktree copy cannot raise the limit" "$(run helper research)"
git checkout -q .claude/shop.json
want "closes only its own" "lead cannot close another helper" "$(run close ac-web-other-verify)"
want "closes only its own" "lead cannot close itself" "$(run close ac-web-dark-mode-lead)"
as ac-web-dark-lead
want "closes only its own" "a shorter slug cannot close a lead" "$(run close ac-web-dark-mode-lead)"
want "closes only its own" "a shorter slug cannot close a helper" "$(run close ac-web-dark-mode-verify)"
as ac-web-dark-mode-lead; want "closed ac-web-dark-mode-verify" "lead closes its helper" "$(run close ac-web-dark-mode-verify)"
[[ ! -e $tmp/repo/.scratch/dark-mode/verify ]] || { echo "FAIL close removes the helper worktree"; failed=1; }

cd "$tmp/repo" || exit 1
as plain-name; want "needs a shop session" "plain cannot write a note" "$(run note hello)"
as ac-web-main; run hold staging dark-mode >/dev/null
run order export-csv 'second goal' >/dev/null; typed 'go export-csv' >/dev/null; run queue export-csv 'second goal' >/dev/null
as ac-web-dark-mode-lead; run note 'waiting for CI' >/dev/null
as ac-web-main
agents_are "[$(bg ac-web-dark-mode-lead),{\"name\":\"ac-web-main\",\"kind\":\"interactive\",\"status\":\"busy\",\"startedAt\":1793345898380},{\"name\":\"chat-2\",\"kind\":\"interactive\",\"cwd\":\"$tmp/repo\"},{\"name\":\"chat-3\",\"kind\":\"interactive\",\"cwd\":\"/elsewhere\"}]"
echo '[{"number":7,"title":"x","state":"OPEN","headRefName":"fix/dark-mode","url":"u","createdAt":"2026-10-31T10:00:00Z","mergedAt":null,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"IN_PROGRESS"},{"status":"COMPLETED","conclusion":"FAILURE"}]}]' >"$tmp/prs.json"
page=$(python3 -I "$(dirname "$shop")/watch.py" "$tmp/repo" --once)
want_json() { [[ $(jq -r "$2" <<<"$page") == "$1" ]] || { echo "FAIL watch $2: wanted $1, got $(jq -c "$2" <<<"$page")"; failed=1; }; }
want_json ac-web-dark-mode-lead '.leads[0].name'
want_json 'waiting for CI' '.leads[0].note'
want_json 7 '.leads[0].pr.number'
want_json '1 1 1 1' '.leads[0].pr | "\(.pass) \(.wait) \(.fail) \(.openThreads)"'
want_json busy '.main.state'
want_json dark-mode '.holds.staging'
want_json export-csv '.queue[0].slug'
want_json chat-2 '.others | join(",")'
as ac-web-main; run order order-one 'one goal' >/dev/null; as ac-web-dark-mode-lead; run ready 7 >/dev/null; as ac-web-main
page=$(python3 -I "$(dirname "$shop")/watch.py" "$tmp/repo" --once)
rec0='[.records[] | select(.slug == "dark-mode")][0]'
want_json 'CI failed' "$rec0.status"
want_json 'You said go:done' "$rec0.steps[1] | \"\\(.label):\\(.state)\""
want_json 'Lead started:done' "$rec0.steps[2] | \"\\(.label):\\(.state)\""
want_json 'PR opened:done' "$rec0.steps[3] | \"\\(.label):\\(.state)\""
want_json 'Reported:done' "$rec0.steps[5] | \"\\(.label):\\(.state)\""
want_json '#7' "$rec0.events | map(select(.kind == \"ready\"))[0].text"
grep -q '"kind":"go"' .scratch/shop/events.jsonl || { echo "FAIL go is recorded"; failed=1; }
grep -q '"kind":"order"' .scratch/shop/events.jsonl || { echo "FAIL the order is recorded"; failed=1; }
agents_are '[{"name":"ac-web-dark-mode-lead","kind":"background","id":"e65","status":"waiting","state":"blocked","waitingFor":"permission prompt"}]'
page=$(python3 -I "$(dirname "$shop")/watch.py" "$tmp/repo" --once)
want_json 'blocked permission prompt e65' '.leads[0] | "\(.state) \(.waitingFor) \(.id)"'
want_json act '.attention[0].level'
want_json 'No main session' '.attention[0].title'
want_json 'claude attach e65' '.attention[1].hint'
want_json watch '.attention[2].level'
want_json 'PR #7 has failed checks: 1' '.attention[2].title'
url=$(run web | tail -1)
want "http://localhost:" "web prints the address" "$url"
want "$url" "web opens the page" "$(cat "$tmp/opened.log")"
want "$url" "a second web finds the same page" "$(run watch | tail -1)"
[[ $(pgrep -f "watch.py $tmp/repo" | wc -l | tr -d ' ') == 1 ]] || { echo "FAIL only one server runs"; failed=1; }
[[ $(curl -s -m 2 -o /dev/null -w '%{http_code}' -H 'Host: evil.example' "${url/localhost/127.0.0.1}/state") == 403 ]] || { echo "FAIL another host gets 403"; failed=1; }
want "Shop status" "page loads" "$(curl -s -m 2 -H "Host: ${url#http://}" "${url/localhost/127.0.0.1}/")"
pkill -f "watch.py $tmp/repo" || true
# An update of the skill: the running server starts the new code at the next request.
cp -R "$(dirname "$shop")" "$tmp/copy"
url=$("$tmp/copy/shop.sh" web 2>&1 | tail -1)
sed -i.bak 's/"now": time.time(),/"now": time.time(), "reloaded": True,/' "$tmp/copy/watch.py"
for try in $(seq 20); do
  out=$(curl -s -m 2 -H "Host: ${url#http://}" "${url/localhost/127.0.0.1}/state")
  [[ $(jq -r .reloaded <<<"$out" 2>/dev/null) == true ]] && break
  sleep 0.2
done
want true "a running server starts the new code" "$(jq -r .reloaded <<<"$out" 2>/dev/null)"
pkill -f "watch.py $tmp/repo" || true
as plain-name; want "needs a main or lead" "plain cannot close" "$(run close ac-web-dark-mode-lead)"
as ac-web-main
want "name a lead" "main cannot close main" "$(run close ac-web-main)"
want "not in this shop" "main stays in its shop" "$(run close chat-1)"
echo 12 >"$tmp/open-pr"
want "is open" "an open PR stops close" "$(run close ac-web-dark-mode-lead)"
rm "$tmp/open-pr"
echo x >.scratch/dark-mode/wt/new.txt
want "uncommitted" "uncommitted work stops close" "$(run close ac-web-dark-mode-lead)"
rm .scratch/dark-mode/wt/new.txt
as ac-web-dark-mode-lead; run helper verify >/dev/null
as ac-web-main
agents_are "[$(bg ac-web-dark-mode-lead),$(bg ac-web-dark-mode-verify),$(bg ac-web-dark-mode-lead-old)]"
: >"$tmp/closed.log"
git -C .scratch/dark-mode/wt commit -q --allow-empty -m done
echo 12 >"$tmp/merged-pr"
want "closed ac-web-dark-mode-lead" "main closes a lead" "$(run close ac-web-dark-mode-lead)"
rm "$tmp/merged-pr"
want "stop ac-web-dark-mode-verify" "close stops the helpers too" "$(cat "$tmp/closed.log")"
[[ ! -e .scratch/dark-mode ]] || { echo "FAIL close removes the worktrees"; failed=1; }
agents_are '[]'
page=$(python3 -I "$(dirname "$shop")/watch.py" "$tmp/repo" --once)
rec='[.records[] | select(.slug == "dark-mode")][0]'
want_json false "$rec.exists"
want_json 'fix dark' "$rec.goal"
want_json 'verify' "$rec.helpers[0].job"
want_json false "$rec.helpers[0].exists"
want_json 2 "$rec.helpers | length"
want_json 3 '.totals.leads'
want_json 3 '.totals.deleted'
want_json 2 '.totals.helpers'
[[ $(jq "$rec.events | length" <<<"$page") -gt 2 ]] || { echo "FAIL a deleted lead keeps its events"; failed=1; }
for t in 100 110 200 210; do
  kind=lead; ((t % 100)) && kind=close
  echo "{\"t\":$t,\"kind\":\"$kind\",\"who\":\"ac-web-main\",\"slug\":\"twice\",\"text\":\"$([[ $kind == lead ]] && echo two tries || echo ac-web-twice-lead)\"}" >>.scratch/shop/events.jsonl
done
page=$(python3 -I "$(dirname "$shop")/watch.py" "$tmp/repo" --once)
want_json 1 '[.records[] | select(.slug == "twice")] | length'
want_json 2 '[.records[] | select(.slug == "twice")][0].runs'
want_json 4 '[.records[] | select(.slug == "twice")][0].events | length'
want_json 210 '[.records[] | select(.slug == "twice")][0].closedAt'
[[ $(python3 -I "$(dirname "$shop")/watch.py" "$tmp/repo" --once | jq '.leads | length') == 0 ]] || { echo "FAIL a closed lead leaves the page"; failed=1; }
[[ -z $(git branch --list fix/dark-mode) ]] || { echo "FAIL close removes the branch"; failed=1; }

as ac-web-main
agents_are '[]'
echo '{"prefix":"ac-web","lead_skill":"/poteto-mode","commit_skill":"/commit"}' >.claude/shop.json
git commit -q --allow-empty -m trunk && git push -q origin HEAD:trunk && git fetch -q origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
run order skill-start g >/dev/null; typed 'go skill-start' >/dev/null
run lead fix skill-start g brief >/dev/null
want "/poteto-mode Brief from ac-web-main:" "lead_skill starts the lead with that skill" "$(cat "$tmp/spawn.log")"
want "Commit and push with /commit." "commit_skill names the commit skill" "$(cat "$tmp/spawn.log")"
want trunk "a lead starts from the default branch" "$(git -C .scratch/skill-start/wt log -1 --format=%s)"
echo '{"prefix":"ac-web","lead_skill":"/other-skill"}' >.claude/shop.json
run order other-skill g >/dev/null; typed 'go other-skill' >/dev/null; run lead fix other-skill g brief >/dev/null
want "/other-skill Brief from ac-web-main:" "lead_skill replaces poteto-mode" "$(cat "$tmp/spawn.log")"
[[ $(cat "$tmp/spawn.log") != */poteto-mode* ]] || { echo "FAIL lead_skill replaces poteto-mode"; failed=1; }

quiet_dir=$tmp/quiet
mkdir -p "$quiet_dir"
project=$tmp/.claude/projects/${quiet_dir//[^a-zA-Z0-9]/-}/s1/subagents
mkdir -p "$project"
idle_for() { echo "{\"status\":\"idle\",\"statusUpdatedAt\":$((($(date +%s) - $1) * 1000))}" >"$tmp/.claude/sessions/77.json"; }
quiet_lead() { agents_are "[{\"name\":\"ac-web-q-lead\",\"kind\":\"background\",\"pid\":77,\"id\":\"s1\",\"sessionId\":\"s1\",\"cwd\":\"$quiet_dir\",\"status\":\"${1:-idle}\",\"state\":\"${2:-working}\",\"waitingFor\":\"permission prompt\"}]"; }
as ac-web-q-lead; want "needs a main session" "a lead has no guard" "$(run guard)"
want "needs a main session" "a lead has no stalled" "$(run stalled)"
as ac-web-main
rm -f .scratch/shop/events.jsonl
quiet_lead; idle_for 2400
want "idle working, quiet 40 min" "status tells idle from the state" "$(run status)"
want "STALLED ac-web-q-lead: quiet 40 min, status idle, state working" "a quiet lead" "$(run stalled)"
[[ -z $(run stalled) ]] || { echo "FAIL one report per quiet stretch"; failed=1; }
idle_for 2500
want "STALLED ac-web-q-lead" "a new quiet stretch reports again" "$(run stalled)"
idle_for 60
[[ -z $(run stalled) ]] || { echo "FAIL a lead quiet for 1 min is no stall"; failed=1; }
idle_for 2400
quiet_lead busy
[[ -z $(run stalled) ]] || { echo "FAIL a busy lead is no stall"; failed=1; }
want "busy working" "status shows busy" "$(run status)"
quiet_lead; idle_for 2600
touch "$project/agent-a.jsonl"
[[ -z $(run stalled) ]] || { echo "FAIL a working subagent is no stall"; failed=1; }
touch -t 202001010000 "$project/agent-a.jsonl"
want "STALLED ac-web-q-lead" "a stopped subagent is a stall" "$(run stalled)"
idle_for 2700
(cd "$quiet_dir" && exec bash -c 'while :; do sleep 1; done # shell-snapshots') &
job=$!
for try in 1 2 3 4 5 6 7 8 9 10; do [[ -n $(pgrep -f '# shell-snapshots') ]] && break; sleep 0.1; done
[[ -z $(run stalled) ]] || { echo "FAIL a running command is no stall"; failed=1; }
want "command running" "status shows a running command" "$(run status)"
kill "$job"; wait "$job" 2>/dev/null
want "STALLED ac-web-q-lead" "the command ended: a stall" "$(run stalled)"
idle_for 2800
echo '{"t":1,"kind":"ready","who":"ac-web-q-lead","slug":"q","text":"#7"}' >.scratch/shop/events.jsonl
[[ -z $(run stalled) ]] || { echo "FAIL a ready lead is no stall"; failed=1; }
echo '{"t":2,"kind":"note","who":"ac-web-q-lead","slug":"q","text":"update the branch"}' >>.scratch/shop/events.jsonl
want "STALLED ac-web-q-lead" "a ready lead working again counts" "$(run stalled)"
helper_dir=$tmp/quiet-helper
mkdir -p "$helper_dir"
helper_idle() { echo "{\"status\":\"idle\",\"statusUpdatedAt\":$((($(date +%s) - $1) * 1000))}" >"$tmp/.claude/sessions/78.json"; }
with_helper() {  # helper status, helper state
  agents_are "[{\"name\":\"ac-web-q-lead\",\"kind\":\"background\",\"pid\":77,\"sessionId\":\"s1\",\"cwd\":\"$quiet_dir\",\"status\":\"idle\",\"state\":\"working\"},{\"name\":\"ac-web-q-verify\",\"kind\":\"background\",\"pid\":78,\"sessionId\":\"s2\",\"cwd\":\"$helper_dir\",\"status\":\"$1\",\"state\":\"${2:-working}\",\"waitingFor\":\"permission prompt\"}]"
}
idle_for 3000; helper_idle 3000; with_helper busy
[[ -z $(run stalled) ]] || { echo "FAIL a lead that waits for a busy helper is no stall"; failed=1; }
want "ac-web-q-verify background busy" "status lists the helper" "$(run status)"
with_helper idle; helper_idle 60
[[ -z $(run stalled) ]] || { echo "FAIL a helper active 1 min ago keeps its lead from a stall"; failed=1; }
helper_idle 3100
out=$(run stalled)
want "STALLED ac-web-q-lead: quiet 50 min" "a lead and its helper both quiet" "$out"
[[ $out != *"STALLED ac-web-q-verify"* ]] || { echo "FAIL a helper that finished is no stall"; failed=1; }
idle_for 3200; helper_idle 10; with_helper idle blocked
want "BLOCKED ac-web-q-verify: it waits for permission prompt" "a blocked helper" "$(run stalled)"
agents_are "[{\"name\":\"ac-web-q-new\",\"kind\":\"background\",\"pid\":78,\"sessionId\":\"s2\",\"cwd\":\"$helper_dir\",\"status\":\"idle\",\"state\":\"blocked\"}]"
[[ -z $(run stalled) ]] || { echo "FAIL a new helper that waits for its brief is not blocked"; failed=1; }
quiet_lead idle blocked; idle_for 10
want "BLOCKED ac-web-q-lead: it waits for permission prompt" "blocked needs no wait" "$(run stalled)"
quiet_lead; idle_for 2900
out=$(GUARD_POLL=0.05 run guard)
want "STALLED ac-web-q-lead" "guard ends on a stall" "$out"
[[ ! -e .scratch/shop/guard.pid ]] || { echo "FAIL guard removes its pid file"; failed=1; }
agents_are '[]'
want "no shop session left" "guard ends with no session" "$(GUARD_POLL=0.05 run guard)"
sleep 300 &
job=$!
echo "$job" >.scratch/shop/guard.pid
want "guard already runs" "one guard" "$(run guard)"
kill "$job"; wait "$job" 2>/dev/null
rm .scratch/shop/guard.pid

want "missing claude-review.yml" "ci finds no workflow" "$(run ci)"
want "missing CLAUDE_CODE_OAUTH_TOKEN" "ci finds no token" "$(run ci)"
want "added   claude-security-review.yml" "ci install adds a workflow" "$(run ci install)"
want "ok      claude-review.yml" "ci sees the workflow" "$(run ci)"
echo keep >.github/workflows/claude-review.yml
run ci install >/dev/null
[[ $(cat .github/workflows/claude-review.yml) == keep ]] || { echo "FAIL ci install keeps a project's workflow"; failed=1; }
echo CLAUDE_CODE_OAUTH_TOKEN >"$tmp/secrets"
want "ok      CLAUDE_CODE_OAUTH_TOKEN" "ci sees the token" "$(run ci)"
want "normal terminal" "token refuses to run through Claude" "$(run token </dev/null)"
for f in "$(dirname "$shop")"/../templates/workflows/*.yml; do
  yq e . "$f" >/dev/null || { echo "FAIL bad yaml $f"; failed=1; }
done

cd "$tmp" || exit 1
[[ -z $(typed '/shop main') ]] || { echo "FAIL /shop main does nothing outside a shop project"; failed=1; }
want "role=none" "not a repo" "$(run role)"
[[ -z $(echo '{}' | "$shop" hook) ]] || { echo "FAIL hook outside a repo prints nothing"; failed=1; }

[[ $failed == 0 ]] && echo PASS
exit $failed
