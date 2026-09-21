#!/usr/bin/env bash
# Live scenario: arm a real merge poll (real gh, real merged PR), relaunch the
# task through bin/fm-control.sh on a real Herdr lab pane, then run the real
# watcher and see whether it still runs the poll.
# Usage: live-relaunch-merge-poll.sh <firstmate-root> <label> <trace on|off> <pr-url>
set -u
ROOT=$1 LABEL=$2 TRACE=$3 URL=$4
fail() { printf 'RESULT: FAIL - %s\n' "$1"; exit 1; }
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
SESSION="fm-lab-rlpoll-$LABEL-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() { [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"; herdr_safe_stop_and_delete "$SESSION"; }
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare lab"
echo "lab session: $SESSION (herdr $(herdr --version | head -1))  root: $ROOT"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-rlpoll.XXXXXX"); SCRATCH=$(cd "$SCRATCH" && pwd)
H="$SCRATCH/home"; ID=lt1; mkdir -p "$H/state" "$H/data/$ID"
printf '# Task\n## Captain'"'"'s intent\nLive relaunch check.\n\n## Firstmate spec\nKeep the PR watched.\n' > "$H/data/$ID/brief.md"
PROJ="$SCRATCH/proj"; WT="$SCRATCH/wt"; mkdir -p "$PROJ"
git -C "$PROJ" init -q; echo x > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm init
git -C "$PROJ" worktree add --quiet -b "task-$ID" "$WT"
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr || fail "backend"
CR=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure"
C=${CR%%$'\t'*}; SEED=${CR#*$'\t'}; WS=${C#*:}
read -r TAB PANE <<<"$(fm_backend_herdr_create_task "$C" "fm-$ID" "$WT" "$SEED")" || fail "create_task"
{ echo "window=$SESSION:$PANE"; echo "endpoint_task_id=$ID"; echo "worktree=$WT"; echo "project=$PROJ"
  echo "harness=codex"; echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=off"
  echo "model=default"; echo "effort=default"; echo "backend=herdr"; echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WS"; echo "herdr_tab_id=$TAB"; echo "herdr_pane_id=$PANE"; } > "$H/state/$ID.meta"
# Inert replacement harness on the pane PATH so the relaunch launches nothing real.
FB="$SCRATCH/fakebin"; mkdir -p "$FB"
# The fake harness registers itself in Herdr's agent registry and then execs a
# codex-named long-running process, so the adapter sees a live replacement agent.
AB="$SCRATCH/agentbin"; mkdir -p "$AB"; ln -s "$(command -v sleep)" "$AB/codex"
cat > "$FB/codex" <<SH
#!/usr/bin/env bash
: > $(printf %q "$SCRATCH/codex-launched")
herdr pane report-agent $PANE --source fm-live-rlpoll --agent codex --state idle --session $SESSION >/dev/null 2>&1
exec $(printf %q "$AB/codex") 900
SH
chmod +x "$FB/codex"
fm_backend_herdr_send_text_line "$SESSION:$PANE" "export PATH=$(printf %q "$FB"):\$PATH" || fail "pane PATH"
if [ "$TRACE" = on ]; then echo "$$" > "$H/state/.lock"; echo "$$ on" > "$H/state/.trace-context-effective"; fi
. "$ROOT/bin/fm-pr-lib.sh"
echo; echo "== 1. arm merge poll with real gh: bin/fm-pr-check.sh $ID $URL"
FM_HOME="$H" "$ROOT/bin/fm-pr-check.sh" "$ID" "$URL" 2>&1 || fail "pr-check"
[ ! -e "$H/state/contributions.check.sh" ] || FM_HOME="$H" "$ROOT/bin/fm-check-unregister.sh" contributions >/dev/null
fm_pr_poll_artifacts_valid "$H/state" "$ID" "$ROOT/bin/fm-pr-poll.sh" && echo "poll authenticates before relaunch: yes" || fail "fresh poll invalid"
echo "--- $ID.meta before relaunch:"; cat "$H/state/$ID.meta"
echo; echo "== 2. relaunch on the real Herdr pane: bin/fm-control.sh $ID relaunch --note ... (trace=$TRACE)"
for n in $(seq 1 "${RELAUNCHES:-1}"); do
  rm -f "$SCRATCH/codex-launched"
  env FM_HOME="$H" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$ID" relaunch --note "waiting on review ($n)" 2>&1; echo "relaunch $n exit=$?"
  [ "$n" = "${RELAUNCHES:-1}" ] || for _ in $(seq 1 50); do [ -e "$SCRATCH/codex-launched" ] && break; sleep 0.1; done
done
for _ in $(seq 1 50); do [ -e "$SCRATCH/codex-launched" ] && break; sleep 0.1; done
[ -e "$SCRATCH/codex-launched" ] && echo "replacement harness launched in the Herdr pane: yes" || echo "replacement harness launched: NO"
echo "--- $ID.meta after relaunch:"; cat "$H/state/$ID.meta"
if fm_pr_poll_artifacts_valid "$H/state" "$ID" "$ROOT/bin/fm-pr-poll.sh"; then echo "poll authenticates after relaunch: yes"; else echo "poll authenticates after relaunch: NO"; fi
echo; echo "== 3. one real watcher run: bin/fm-watch.sh"
W=$(perl -e 'my $p=fork; if(!$p){exec @ARGV} $SIG{ALRM}=sub{kill "TERM",$p; waitpid $p,0; exit 124}; alarm 60; waitpid $p,0; exit($?>>8)' \
  env FM_HOME="$H" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=30 FM_POLL=0.2 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
  "$ROOT/bin/fm-watch.sh" 2>&1); echo "watch exit=$?"; printf '%s\n' "$W"
case "$W" in
  *"rejected unauthenticated"*) echo "RESULT: FAIL - watcher rejected the relaunched task's merge poll (monitoring disarmed)";;
  *"$ID.check.sh: merged"*) echo "RESULT: PASS - watcher ran the merge poll after relaunch and reported the merge";;
  *) echo "RESULT: UNKNOWN";;
esac
