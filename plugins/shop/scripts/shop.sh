#!/bin/bash
# Session roles and session control for the shop skill.
# Usage: shop.sh role | hook | prompt | status | stalled | guard | watch | web | lead <type> <slug> <goal> [brief] | helper <job> [goal]
#        | close <session name> | note <text> | order <slug> <name> | ready <pr> | queue <slug> <goal> | hold <resource> <slug|free> | ci [install] | token
# The session name is the switch: only <prefix>-main starts leads, and only a lead starts helpers.
# hook and prompt are Claude Code hooks: SessionStart and UserPromptSubmit.
set -u

die() { echo "shop: $1" >&2; exit 1; }

load() {
  prefix=; name=; role=none; conf=; main_root=; scratch=
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  main_root=$(dirname "$common")
  scratch=$main_root/.scratch/shop
  # Main's copy: a PR must not change its own limits.
  conf=$main_root/.claude/shop.json
  [[ -f $conf ]] || return 0
  prefix=$(jq -r .prefix "$conf")
  # ponytail: Claude Code's session file. If its format changes, every session becomes plain and the script refuses.
  name=$(jq -r '.name // ""' "$HOME/.claude/sessions/${CLAUDE_PID:-none}.json" 2>/dev/null)
  case $name in
    "$prefix-main") role=main ;;
    "$prefix"-*-lead) role=lead ;;
    "$prefix"-*) role=helper ;;
    *) role=plain ;;
  esac
}

need() { [[ $role == "$1" ]] || die "$cmd needs a $1 session. This session is '${name:-unnamed}' (role $role)."; }
limit() { jq -r --arg k "$1" --argjson d "$2" '.[$k] // $d' "$conf"; }
agents() { claude agents --json 2>/dev/null; }
count() { agents | jq --arg re "$1" '[.[] | select((.name // "") | test($re))] | length'; }
names() { agents | jq -r --arg re "$1" '.[] | select((.name // "") | test($re)) | .name'; }
helpers_re() { echo "^$1-(?!lead\$)[a-z0-9]+\$"; }

STALL_MIN=${STALL_MIN:-30}    # minutes with nothing happening; the tests set it
GUARD_POLL=${GUARD_POLL:-120} # seconds

# One tab-separated line per session of this shop. An empty value is "-": read skips an empty field.
shop_rows() {
  agents | jq -r --arg p "$prefix-" '.[] | select((.name // "") | startswith($p)) |
    [.name, .kind // "-", .status // "-", .state // "-", .pid // "-", .sessionId // "-", .cwd // "-", .waitingFor // "-"] | @tsv'
}

# The folders of the Bash tool commands that run now, in the foreground or the background.
# ponytail: finds them by Claude Code's shell snapshot in the command line. If that changes, a long test looks quiet,
# and main gets a false alarm, not a missed one.
command_dirs() {
  local pids
  pids=$(pgrep -f shell-snapshots | paste -sd, -)
  [[ -n $pids ]] && lsof -a -p "$pids" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
}

# When a session last did anything, in epoch seconds: its last status change, or the last write of a subagent, which
# works while the session itself is idle. Prints nothing with no session file.
# ponytail: Claude Code's files. If they change, status shows no age and stalled finds nothing.
last_active() {  # pid, session id, directory
  local since sub t
  since=$(jq -r '(.statusUpdatedAt // empty) / 1000 | floor' "$HOME/.claude/sessions/$1.json" 2>/dev/null)
  [[ -n $since ]] || return 0
  sub=$(ls -t "$HOME/.claude/projects/${3//[^a-zA-Z0-9]/-}/$2/subagents"/*.jsonl 2>/dev/null | head -1)
  if [[ -n $sub ]]; then
    t=$(stat -f %m "$sub" 2>/dev/null || stat -c %Y "$sub")
    ((t > since)) && since=$t
  fi
  echo "$since"
}

last_event() { jq -rs --arg w "$1" 'map(select(.who == $w)) | last | .kind // ""' "$scratch/events.jsonl" 2>/dev/null; }

# watch.py reads this log for the goals, the notes, and the timeline.
event() {  # kind, slug, text
  mkdir -p "$scratch"
  jq -cn --argjson t "$(date +%s)" --arg kind "$1" --arg who "$name" --arg slug "$2" --arg text "${3:-}" \
    '{t: $t, kind: $kind, who: $who, slug: $slug, text: $text}' >>"$scratch/events.jsonl"
}

# ponytail: a file in approved/ marks the user's go for one order. It stops a mistake: a session that means harm
# can touch it.
approved() { [[ -f $scratch/approved/$1 ]]; }

# The orders that a prompt says go for, as JSON: {go: true or false, orders: [{slug, name}]}.
# ponytail: fixed rules, not a model. They can open more orders than the prompt means: main starts only the ones it
# means, and reports what it starts.
go_scope() {  # prompt
  cat "$scratch/events.jsonl" 2>/dev/null | jq -s --arg p "$1" '
    ($p | ascii_downcase) as $text
    # A command go: at the start, after punctuation, a digit, a Han character, or a word like ok. Not "go?",
    # "go-live", "go to", or a go after a no.
    | ($text | test("(^|[,.;:!，。；：！、0-9\\p{Han}]|\\b(ok|okay|yes|yeah|then|so|now|let.?s|please|sure|alright))\\s*go(?![a-z?？-])(?!\\s+(to|back|through|into|over|out|up|down|home|away|around)\\b)")
       and ($text | test("((不|別|沒)[要用有]?|\\b(don.?t|do not|not|never|no))\\s*go(?![a-z])") | not)) as $go
    # The place in the log, not the time: two events can come in the same second.
    | (to_entries | map(.value + {i: .key})) as $log
    | ($log | map(select(.kind == "go")) | last | .i // -1) as $last_go
    | (reduce ($log[] | select(.kind == "lead")) as $e ({}; .[$e.slug] = $e.i)) as $started
    | [$log | group_by(.slug)[] | map(select(.kind == "order")) | last // empty | select(.i > ($started[.slug] // -1))] as $open
    # An order has no number before go: its GitHub issue gives it one at go. The user names it by its slug, or by
    # its name when the name has a Han character (an English name can be a word of any sentence).
    | [$open[] | . as $o | select(($text | test("(^|[^a-z0-9-])" + $o.slug + "([^a-z0-9-]|$)"))
        or (($o.text // "") | test("\\p{Han}")) and ($text | contains($o.text | ascii_downcase)))] as $named
    # ponytail: a name with a typo matches nothing, so the go opens every order that main showed since the last
    # go. Main starts only the ones that the message means.
    | {go: $go, orders: (if ($go | not) then [] elif ($named | length) > 0 then $named
        else [$open[] | select(.i > $last_go)] end | map({slug, name: .text}))}'
}

own_slug() { local base=${name%-lead}; [[ $role == helper ]] && base=${base%-*}; base=${base#"$prefix"-}; [[ $role == main ]] || echo "$base"; }

start() {  # session, directory, system prompt, first prompt, extra denied tools
  local session=$1 dir=$2 prompt=$3 first=() out
  [[ -n $4 ]] && first=("$4")
  shift 4
  # The first prompt counts as typed by the user, so a skill that only a user can start runs. It goes before the
  # flags: --disallowedTools takes every word after it. EnterWorktree asks for a permission, and no one answers in a
  # background session: the session starts in its worktree, so it needs none. No one answers AskUserQuestion either:
  # a session sends its question up. The git rules are the limits of the commit steps.
  out=$(cd "$dir" && claude --bg ${first[@]+"${first[@]}"} -n "$session" --permission-mode auto --disallowedTools 'Bash(claude --bg:*)' EnterWorktree ExitWorktree AskUserQuestion \
    'Bash(git push *--force*)' 'Bash(git push -f*)' 'Bash(git push * -f*)' 'Bash(git push *--no-verify*)' 'Bash(git commit *--no-verify*)' \
    "$@" --append-system-prompt "$prompt" 2>&1 </dev/null)
  [[ $out == *backgrounded* ]] && return 0
  echo "$out" >&2
  return 1
}

stop_session() {
  local id
  id=$(agents | jq -r --arg n "$1" 'first(.[] | select(.name == $n and .kind == "background") | .id) // ""')
  [[ -n $id ]] || return 0
  claude stop "$id" >/dev/null 2>&1
  claude rm "$id" >/dev/null 2>&1
}

# A slug names a folder in .scratch and goes into the go rules as a pattern. .scratch/shop holds the shop's own files.
check_slug() { [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ && $1 != main && $1 != shop ]] || die "slug must use lowercase letters, digits, and hyphens, and must not be main or shop."; }

# The default branch. With no origin/HEAD (setup sets it), main.
default_branch() { git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main; }

cmd_lead() {
  local type=${1:-} slug=${2:-} goal=${3:-} brief=${4:-${3:-}} skill commit from
  need main
  [[ $type =~ ^(feat|fix|chore|docs|refactor|test)$ ]] || die "type must be feat, fix, chore, docs, refactor, or test."
  check_slug "$slug"
  [[ -n $goal ]] || die "a lead needs a goal."
  approved "$slug" || die "the user has not said go for $slug. Show the order and wait."
  local max running session=$prefix-$slug-lead wt=$main_root/.scratch/$slug/wt
  max=$(limit max_leads 3)
  running=$(count "^$prefix-.+-lead\$")
  ((running < max)) || die "$running of $max leads are running. Queue this feature."
  from=$(default_branch)
  git fetch -q origin "${from#origin/}" || die "git fetch failed."
  git worktree add -q -b "$type/$slug" "$wt" "$from" || die "cannot create the worktree."
  # The pstack plugin gives /poteto-mode. Setup makes sure that it is on.
  skill=$(jq -r 'if has("lead_skill") then .lead_skill else "/poteto-mode" end' "$conf")
  commit=$(jq -r '.commit_skill // "/shop commit"' "$conf")
  if ! start "$session" "$wt" "You are $session, a lead. Main is $prefix-main. Load the shop skill: its Lead section decides the PR flow, who merges, and whom you report to, ahead of any other playbook. Work on your own: ask no questions, and decide each open point yourself. Commit and push with $commit. You are already in your worktree: stay in it, and commit there. This overrides any other worktree rule." \
    "${skill:+$skill }Brief from $prefix-main:

$brief" 'Bash(gh pr merge:*)'; then
    git worktree remove "$wt"
    git branch -qD "$type/$slug"
    die "cannot start $session."
  fi
  rm -f "$scratch/approved/$slug"
  event lead "$slug" "$goal"
  echo "session=$session worktree=$wt branch=$type/$slug"
}

cmd_helper() {
  local job=${1:-} goal=${2:-}
  need lead
  [[ $job =~ ^[a-z0-9]+$ && $job != lead && $job != main ]] || die "job must be one lowercase word, for example research or verify."
  local base=${name%-lead} max running
  local session=$base-$job wt=$main_root/.scratch/${base#"$prefix"-}/$job
  max=$(limit max_helpers 2)
  running=$(count "$(helpers_re "$base")")
  ((running < max)) || die "$running of $max helpers are running for $name."
  git worktree add -q --detach "$wt" HEAD || die "cannot create the worktree."
  if ! start "$session" "$wt" "You are $session, a helper for $name. Load the shop skill and follow its Helper section. Work on your own: ask no questions." "" 'Bash(gh pr:*)' 'Bash(git push:*)'; then
    git worktree remove "$wt"
    die "cannot start $session."
  fi
  event helper "$(own_slug)" "$job${goal:+: $goal}"
  echo "session=$session worktree=$wt"
}

close_helper() {  # helper session name
  local rest=${1#"$prefix"-} slug job=${1##*-}
  slug=${rest%-"$job"}
  stop_session "$1"
  git worktree remove --force "$main_root/.scratch/$slug/$job" 2>/dev/null
  event close "$slug" "$1"
  echo "closed $1"
}

close_lead() {  # lead session name
  local base=${1%-lead} slug wt branch helper
  slug=${base#"$prefix"-}
  wt=$main_root/.scratch/$slug/wt
  [[ -d $wt ]] || die "no worktree at $wt."
  branch=$(git -C "$wt" branch --show-current)
  [[ -z $(git -C "$wt" status --porcelain) ]] || die "$wt has uncommitted changes."
  [[ -z $(gh pr list --head "$branch" --state open --json number --jq '.[].number') ]] || die "the PR of $branch is open. Merge or close it first."
  for helper in $(names "$(helpers_re "$base")"); do close_helper "$helper"; done
  stop_session "$1"
  git worktree remove "$wt" || die "cannot remove $wt."
  rmdir "$main_root/.scratch/$slug" 2>/dev/null
  event close "$slug" "$1"
  # Delete the branch only when its work is on the default branch: a merged PR, or no commit of its own.
  if [[ -n $(gh pr list --head "$branch" --state merged --json number --jq '.[].number') ]] ||
    git merge-base --is-ancestor "$branch" "$(default_branch)"; then
    git branch -qD "$branch"
    git push -q origin --delete "$branch" 2>/dev/null
    echo "closed $1, $wt, $branch"
  else
    echo "closed $1 and $wt. Kept $branch: its work is not merged."
  fi
}

cmd_close() {
  local target=${1:-}
  [[ -n $target && $target != "$prefix-main" ]] || die "name a lead or a helper."
  case $role in
    main)
      [[ $target == "$prefix"-* ]] || die "$target is not in this shop."
      if [[ $target == *-lead ]]; then close_lead "$target"; else close_helper "$target"; fi
      ;;
    lead)
      [[ $target != "$name" && $target =~ ^${name%-lead}-[a-z0-9]+$ ]] || die "a lead closes only its own helpers."
      close_helper "$target"
      ;;
    *) die "close needs a main or lead session." ;;
  esac
}

cmd_note() {
  [[ $role =~ ^(main|lead|helper)$ ]] || die "note needs a shop session."
  [[ -n ${1:-} ]] || die "note needs a text."
  event note "$(own_slug)" "$1"
}

cmd_order() {  # slug, name
  need main
  [[ -n ${1:-} ]] || die "order needs a slug."
  check_slug "$1"
  # A changed order needs a new go.
  rm -f "$scratch/approved/$1"
  event order "$1" "${2:-}"
  echo "order slug=$1${2:+ name=$2}"
}

cmd_ready() {
  need lead
  [[ -n ${1:-} ]] || die "ready needs the PR number."
  event ready "$(own_slug)" "#$1"
}

cmd_queue() {
  need main
  [[ -n ${1:-} ]] || die "queue needs a slug."
  check_slug "$1"
  approved "$1" || die "the user has not said go for $1. Show the order and wait."
  event queue "$1" "${2:-}"
}

cmd_hold() {  # resource, slug or free
  need main
  [[ -n ${1:-} && -n ${2:-} ]] || die "hold needs a resource, then a slug or free."
  event hold "$2" "$1"
}

page_root() { curl -s -m 1 "http://127.0.0.1:$1/state" 2>/dev/null | jq -r '.root // ""' 2>/dev/null; }

show() {
  local opener
  opener=$(command -v open || command -v xdg-open) && "$opener" "http://localhost:$1"
  echo "http://localhost:$1"
}

# ponytail: the server stays up until the computer restarts. It does no work unless a page polls it.
cmd_watch() {
  [[ -n $prefix ]] || die "this project has no .claude/shop.json."
  local port root try
  for port in 8766 8767 8768 8769 8770 8771 8772 8773 8774 8775; do
    root=$(page_root "$port")
    if [[ $root == "$main_root" ]]; then show "$port"; return; fi
    [[ -z $root ]] || continue  # another project's page
    nohup python3 -I "$(dirname "$0")/watch.py" "$main_root" "$port" >/dev/null 2>&1 &
    disown
    for try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      sleep 0.2
      if [[ $(page_root "$port") == "$main_root" ]]; then show "$port"; return; fi
    done
  done
  die "cannot start the status page."
}

cmd_ci() {
  local top name dir templates
  top=$(git rev-parse --show-toplevel 2>/dev/null) || die "this folder is not a git repo."
  dir=$top/.github/workflows
  templates=$(dirname "$0")/../templates/workflows
  for name in claude-review.yml claude-security-review.yml; do
    if [[ -f $dir/$name ]]; then
      echo "ok      $name"
    elif [[ ${1:-} == install ]]; then
      mkdir -p "$dir"
      cp "$templates/$name" "$dir/$name"
      echo "added   $name"
    else
      echo "missing $name: run shop.sh ci install"
    fi
  done
  if gh secret list --json name --jq '.[].name' 2>/dev/null | grep -qx CLAUDE_CODE_OAUTH_TOKEN; then
    echo "ok      CLAUDE_CODE_OAUTH_TOKEN"
  else
    echo "missing CLAUDE_CODE_OAUTH_TOKEN: in a normal terminal, in this repo, run $(cd "$(dirname "$0")" && pwd)/shop.sh token"
  fi
}

# Output from a `!` command enters the conversation, so the token must come through a real terminal.
cmd_token() {
  [[ -t 0 && -t 1 ]] || die "run this in a normal terminal, not through Claude: the token must stay out of the conversation."
  git rev-parse --show-toplevel >/dev/null 2>&1 || die "run this inside the repo."
  echo "1. Sign in. Claude Code prints a token."
  claude setup-token
  echo
  echo "2. Copy the token, then paste it here. The screen does not show it."
  gh secret set CLAUDE_CODE_OAUTH_TOKEN
  echo "Done. Clear this terminal's history if other people use this computer."
}

cmd_status() {
  [[ -n $prefix ]] || die "this project has no .claude/shop.json."
  local dirs now n kind status state pid id dir wait since extra
  dirs=$(command_dirs)
  now=$(date +%s)
  echo "sessions:"
  # status is what the session does now. state is the job, and it can say working for hours on an idle session.
  while IFS=$'\t' read -r n kind status state pid id dir wait; do
    extra=
    if [[ $kind == background ]]; then
      if grep -qF -- "$dir" <<<"$dirs"; then
        extra=", command running"
      elif [[ $status != busy ]]; then
        since=$(last_active "$pid" "$id" "$dir")
        [[ -n $since ]] && extra=", quiet $(((now - since) / 60)) min"
      fi
    fi
    echo "  $n $kind $status $state$extra"
  done < <(shop_rows)
  echo "worktrees:"
  git worktree list | sed 's/^/  /'
}

# One line per session that needs main. Once per quiet stretch, so main can go on after it looks.
# A lead answers for its helpers: a helper that sent its result waits for the lead, and a lead that waits for a working
# helper is not stuck. So only a lead counts as stalled, and only when the lead and its helpers are all quiet.
cmd_stalled() {
  need main
  local dirs now rows n kind status state pid id dir wait since told m k s st p i d w t quiet
  dirs=$(command_dirs)
  now=$(date +%s)
  rows=$(shop_rows)
  mkdir -p "$scratch/told"
  while IFS=$'\t' read -r n kind status state pid id dir wait; do
    [[ $kind == background ]] || continue
    since=$(last_active "$pid" "$id" "$dir")
    told=$scratch/told/$n
    # A new helper is blocked with nothing in waitingFor until its brief comes.
    [[ $state == blocked && $n != *-lead && $wait == - ]] && continue
    if [[ $state != blocked ]]; then
      [[ $n == *-lead && $(last_event "$n") != ready && -n $since ]] || continue
      quiet=yes
      while IFS=$'\t' read -r m k s st p i d w; do
        [[ $m =~ ^${n%-lead}-[a-z0-9]+$ ]] || continue
        if [[ $s == busy ]] || grep -qF -- "$d" <<<"$dirs"; then quiet=; fi
        t=$(last_active "$p" "$i" "$d")
        ((${t:-0} > since)) && since=$t
      done <<<"$rows"
      [[ -n $quiet ]] && ((now - since >= STALL_MIN * 60)) || continue
    fi
    [[ $(cat "$told" 2>/dev/null) != "${since:-none}" ]] || continue
    echo "${since:-none}" >"$told"
    if [[ $state == blocked ]]; then
      echo "BLOCKED $n: it waits for ${wait/#-/an answer}. No one in the background can answer."
    else
      echo "STALLED $n: quiet $(((now - since) / 60)) min, status $status, state $state, no command running."
    fi
  done < <(shop_rows)
}

# Run it with run_in_background. It ends when a session needs main, which wakes main, or when no session is left.
cmd_guard() {
  need main
  local pidfile=$scratch/guard.pid out
  mkdir -p "$scratch"
  if [[ -f $pidfile ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "guard already runs"
    return
  fi
  echo $$ >"$pidfile"
  trap "rm -f $(printf %q "$pidfile")" EXIT  # expanded now: a local is gone when the script exits
  # The sleep comes first: a session just started is not in the list yet. Main gone: no one is left to wake.
  while sleep "$GUARD_POLL" && ps -p "${CLAUDE_PID:-1}" >/dev/null; do
    [[ $(count "^$prefix-(?!main\$)") -gt 0 ]] || { echo "no shop session left"; return; }
    out=$(cmd_stalled)
    [[ -z $out ]] || { echo "$out"; return; }
  done
}

cmd_hook() {
  cat >/dev/null
  [[ $role == main ]] || exit 0
  jq -n --arg n "$name" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: "Shop role: main. This session is \($n). Load the shop skill before you act on a request that changes code."}}'
}

# UserPromptSubmit sees only what the user typed, so a session cannot name itself main or say go by accident.
cmd_prompt() {
  local input=$1 text said scope n slug list=
  said=$(jq -r .prompt <<<"$input")
  [[ -n $prefix ]] || exit 0
  if [[ $said =~ ^/(shop:)?shop\ main$ ]]; then
    if [[ $name != "$prefix-main" && $(count "^$prefix-main\$") -gt 0 ]]; then
      text="$prefix-main is already running, so this session keeps the name '$name'. Tell the user."
      jq -n --arg t "$text" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $t}}'
      exit 0
    fi
    # A hook cannot turn on Remote Control, so tell the user when it is off.
    jq -n --arg n "$prefix-main" --arg rc "${CLAUDE_CODE_BRIDGE_SESSION_ID:-}" \
      '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", sessionTitle: $n}} + (if $rc == "" then {systemMessage: "Remote Control is off. To use this session from another device, type /rc."} else {} end)'
    exit 0
  fi
  [[ $role == main ]] || exit 0
  scope=$(go_scope "$said")
  [[ $(jq -r .go <<<"$scope") == true ]] || exit 0
  mkdir -p "$scratch/approved"
  while IFS=$'\t' read -r slug n; do
    touch "$scratch/approved/$slug"
    event go "$slug"
    list+="${list:+, }$slug${n:+ ($n)}"
  done < <(jq -r '.orders[] | [.slug, .name] | @tsv' <<<"$scope")
  if [[ -n $list ]]; then
    text="The user said go for: $list. shop.sh lead and queue are open for these orders only. If the message does not mean to start them, do not start them: ask the user. Before you start or queue each one, create its GitHub issue (the Main section of the shop skill). Treat the rest of the message as a new request."
  else
    # The next go without a name counts the orders from here.
    event go ""
    text="The message has a go, but no open order matches it. If the user means an order, show it again and ask the user to say go with its name."
  fi
  jq -n --arg t "$text" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $t}}'
}

# Runs on every prompt, so leave before git and jq unless the prompt can match.
if [[ ${1:-} == prompt ]]; then
  input=$(cat)
  has_go='(^|[^A-Za-z])[Gg][Oo]([^A-Za-z]|$)'
  [[ $input == *'shop main'* || $input =~ $has_go ]] || exit 0
fi

load
cmd=${1:-}
[[ $# -gt 0 ]] && shift
case $cmd in
  role) echo "role=$role name=${name:-unnamed} prefix=${prefix:-none} remote_control=${CLAUDE_CODE_BRIDGE_SESSION_ID:+on}" ;;
  hook) cmd_hook ;;
  prompt) cmd_prompt "$input" ;;
  status) cmd_status ;;
  stalled) cmd_stalled ;;
  guard) cmd_guard ;;
  watch | web) cmd_watch ;;
  note) cmd_note "$@" ;;
  order) cmd_order "$@" ;;
  ready) cmd_ready "$@" ;;
  queue) cmd_queue "$@" ;;
  hold) cmd_hold "$@" ;;
  ci) cmd_ci "$@" ;;
  token) cmd_token ;;
  lead) cmd_lead "$@" ;;
  helper) cmd_helper "$@" ;;
  close) cmd_close "$@" ;;
  *) die "usage: shop.sh role | status | stalled | guard | watch | web | lead <type> <slug> <goal> [brief] | helper <job> [goal] | close <name> | note <text> | order <slug> <name> | ready <pr> | queue <slug> <goal> | hold <resource> <slug|free> | ci [install] | token" ;;
esac
