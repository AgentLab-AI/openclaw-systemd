#!/bin/sh
# Unit-style tests for the repair lifecycle's maintenance window: marker
# create/remove, stale-owner cleanup, interrupted repairs not looping, the
# watched Doctor's deadlines and heartbeat, readiness-gated removal, and the
# operator retry helper. Doctor, /healthz and /readyz are all simulated; no
# systemd or Docker needed, only sh, curl-less stubs, and the OpenClaw install
# under /app (repair-if-needed reads its version).
#
#   sh tests/maintenance.test.sh                      # from a checkout
#   LIBEXEC=/usr/local/libexec/openclaw-systemd sh /tests/maintenance.test.sh   # in the image
set -eu

# Several cases depend on being an ordinary account: chmod 555 must really
# block writes, and repair-retry's root branch is only checked statically here. Root
# would write through the permission test and use its own passwd home. CI runs
# this as uid 1000 (docker run --user 1000:1000 ...).
if [ "$(id -u)" = 0 ]; then
  echo "tests/maintenance.test.sh must not run as root; run it as an ordinary user (CI: --user 1000:1000)"
  exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
lx=${LIBEXEC:-$root/rootfs/usr/local/libexec/openclaw-systemd}
r=$lx/repair-if-needed
mh=$lx/mark-healthy
rt=$lx/repair-retry
test -f "$lx/maintenance.sh"

t=$(mktemp -d /tmp/maint-test.XXXXXX)
trap 'rm -rf "$t"' EXIT
# repair-retry's start step is neutralised by stubs on PATH, not by an
# environment switch: it must read none.
mkdir -p "$t/rtbin"
for c in openclaw systemctl; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/rtbin.log"\nexit 0\n' "$c" "$t" > "$t/rtbin/$c"
  chmod +x "$t/rtbin/$c"
done
: > "$t/rtbin.log"
H=$t/home
st=$H/.openclaw/state/openclaw-systemd
mk=$H/.openclaw/MAINTENANCE
sb=$t/stub
v=$(/usr/local/bin/node -p 'require("/app/package.json").version')

die() { echo "FAIL: $*"; exit 1; }
fresh() { rm -rf "$H" "$sb"; mkdir -p "$st" "$sb"; echo "$v" > "$st/repaired-version"; }
field() { sed -n "s/^$1=//p" "${2:-$mk}" | head -n 1; }
# rr <simulate> [env assignments...]: one start's ExecStartPre, short timings.
rr() {
  sim=$1; shift
  env HOME="$H" OPENCLAW_SYSTEMD_TEST_SIMULATE="$sim" \
    OPENCLAW_SYSTEMD_TEST_TICK=1 OPENCLAW_SYSTEMD_TEST_HEARTBEAT_SECS=1 \
    "$@" "$r" openclaw-gateway.service
}
# procps may not be in the image: read /proc directly.
# kids <pid>: direct children. cmdmatch <text>: pids whose command line has it.
kids() { for d in /proc/[0-9]*; do
  [ "$(sed 's/^.*) //' "$d/stat" 2>/dev/null | cut -d' ' -f2)" = "$1" ] && echo "${d#/proc/}"; done; return 0; }
cmdmatch() { for d in /proc/[0-9]*; do
  [ "${d#/proc/}" = "$$" ] && continue
  c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
  # The scanner's own pipeline carries the text too; only look at shells and sleep.
  case "$c" in "sh -c "*|sleep*) case "$c" in *"$1"*) echo "${d#/proc/}" ;; esac ;; esac; done; return 0; }
killkids() { for k in $(kids "$1"); do kill -KILL "$k" 2>/dev/null || true; done; }
# Wait up to $2 s for "$1" to exist.
waitfor() { i=0; while [ ! -e "$1" ] && [ "$i" -lt "$(( ${2:-10} * 10 ))" ]; do sleep 0.1; i=$((i + 1)); done; [ -e "$1" ]; }

# A curl stand-in: /healthz and /readyz succeed only while the matching file
# exists in $sb. Mirrors the real calls (curl -sf ... URL).
cat > "$t/curl" <<'EOF'
#!/bin/sh
for a; do u=$a; done
case "$u" in
  */healthz) [ -e "$STUB_DIR/healthz" ] ;;
  */readyz) [ -e "$STUB_DIR/readyz" ] ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$t/curl"

echo "== other units are untouched"
fresh; touch "$st/force-repair"
out=$(HOME=$H "$r" dbus.service); [ -z "$out" ] || die "other unit produced output"
out=$(HOME=$H "$mh" dbus.service); [ -z "$out" ] || die "mark-healthy acted on another unit"
[ -e "$st/force-repair" ] && [ ! -e "$mk" ] || die "other unit changed state"

echo "== marker is created before Doctor, owned, atomic, fully described; force is consumed"
fresh; touch "$st/force-repair"
( rr chatty OPENCLAW_SYSTEMD_TEST_HARD_CAP_SECS=60 INVOCATION_ID=inv-1 >"$t/out" 2>&1 ) &
bg=$!
waitfor "$mk" 10 || die "marker not created"
waitfor "$st/repair-in-progress" 10 || die "in-progress record not created"
[ "$(field owner)" = openclaw-systemd ] || die "owner"
[ "$(field phase)" = repair ] || die "phase"
[ "$(field invocation)" = inv-1 ] || die "invocation"
[ -n "$(field reason)" ] && [ -n "$(field start)" ] && [ -n "$(field pidstart)" ] || die "fields missing"
pid=$(field pid)
kill -0 "$pid" 2>/dev/null || die "owner pid not alive"
[ "$(( $(field deadline) - $(field start) ))" = 60 ] || die "deadline is not start + cap"
[ "$(stat -c %u "$mk")" = "$(id -u)" ] || die "marker owner"
[ ! -e "$mk.tmp" ] || die "temp file left behind"
[ ! -e "$st/force-repair" ] || die "force-repair not consumed into the in-progress record"
[ "$(field pid "$st/repair-in-progress")" = "$pid" ] || die "in-progress pid"
kill "$pid"; wait "$bg" 2>/dev/null || true

echo "== a stop request mid-repair fails closed and cleans up"
[ ! -e "$mk" ] && [ ! -e "$st/repair-in-progress" ] || die "marker/record left after SIGTERM"
grep -q "interrupted by a stop request" "$st/repair-blocked" || die "SIGTERM did not block"
[ -z "$(cmdmatch 'simulated doctor: working')" ] || die "Doctor child survived"

echo "== success: marker is handed to the readiness wait, record gone"
fresh; touch "$st/force-repair"
out=$(rr ok INVOCATION_ID=inv-2) || die "successful repair exited non-zero"
echo "$out" | grep -q 'simulated doctor: ok' || die "Doctor output not forwarded"
[ "$(field phase)" = awaiting-ready ] || die "phase after success"
[ -z "$(field pid)" ] && [ "$(field invocation)" = inv-2 ] || die "handover fields"
[ ! -e "$st/repair-in-progress" ] && [ ! -e "$st/repair-blocked" ] || die "state after success"

echo "== failure (forced/upgrade): fail closed, marker and record removed"
fresh; touch "$st/force-repair"
if rr fail >"$t/out" 2>&1; then die "failed forced repair must exit non-zero"; fi
[ ! -e "$mk" ] && [ ! -e "$st/repair-in-progress" ] || die "marker/record left after failure"
[ ! -e "$st/force-repair" ] || die "force-repair must be consumed, not left to re-trigger"
grep -q "^$v doctor exited 1 (forced" "$st/repair-blocked" || die "blocked reason"

echo "== hard cap kills a Doctor that keeps talking, and fails closed"
fresh; touch "$st/force-repair"
if rr chatty OPENCLAW_SYSTEMD_TEST_HARD_CAP_SECS=3 >"$t/out" 2>&1; then die "hard cap must fail"; fi
grep -q 'hard cap' "$t/out" && grep -q 'hard cap' "$st/repair-blocked" || die "hard cap not reported"
[ ! -e "$mk" ] && [ ! -e "$st/repair-in-progress" ] || die "cleanup after hard cap"
[ -z "$(cmdmatch 'simulated doctor: working')" ] || die "Doctor tree survived the cap"

echo "== progress deadline kills a silent Doctor"
fresh; touch "$st/force-repair"
if rr silent OPENCLAW_SYSTEMD_TEST_PROGRESS_SECS=2 >"$t/out" 2>&1; then die "silent Doctor must fail"; fi
grep -q 'no output for 2s' "$st/repair-blocked" || die "progress deadline not reported"
[ -z "$(cmdmatch 'sleep 3600')" ] || die "silent child survived"

echo "== chatty Doctor within its cap is not killed by the progress deadline; heartbeat refreshes the marker"
fresh; touch "$st/force-repair"
( rr chatty OPENCLAW_SYSTEMD_TEST_PROGRESS_SECS=2 OPENCLAW_SYSTEMD_TEST_HARD_CAP_SECS=6 >"$t/out" 2>&1 ) &
bg=$!
waitfor "$mk" 10 || die "no marker"
touch -d '2000-01-01' "$mk"
sleep 3
[ "$(( $(date +%s) - $(stat -c %Y "$mk") ))" -lt 5 ] || die "heartbeat did not refresh the marker mtime"
wait "$bg" 2>/dev/null || true
grep -q 'hard cap' "$st/repair-blocked" && ! grep -q 'no output' "$st/repair-blocked" || die "chatty Doctor judged silent"

echo "== SIGKILL mid-repair: next start is blocked, Doctor is NOT re-run"
fresh; touch "$st/force-repair"
( rr silent >"$t/out" 2>&1 ) &
waitfor "$st/repair-in-progress" 10 || die "no in-progress record"
pid=$(field pid "$st/repair-in-progress")
# Kill the repair and its Doctor outright, as an OOM kill or node loss would.
killkids "$pid"
kill -KILL "$pid"
wait 2>/dev/null || true
[ -e "$st/repair-in-progress" ] && [ -e "$mk" ] || die "SIGKILL should leave the record and marker behind"
if out=$(rr ok 2>&1); then die "interrupted repair must block the next start"; fi
echo "$out" | grep -q 'interrupted' || die "no interrupted message"
! echo "$out" | grep -q 'running doctor' || die "Doctor ran again after an interruption"
grep -q "^$v interrupted" "$st/repair-blocked" || die "repair-blocked not written"
[ ! -e "$st/repair-in-progress" ] && [ ! -e "$mk" ] || die "stale record/marker not cleaned"
# And it stays blocked: another automatic restart still does not run Doctor.
if out=$(rr ok 2>&1); then die "still blocked"; fi
! echo "$out" | grep -q 'running doctor' || die "Doctor ran on the second restart"

echo "== interrupted upgrade repair (version change) also blocks"
fresh; echo 2026.1.1 > "$st/repaired-version"
( rr silent >"$t/out" 2>&1 ) &
waitfor "$st/repair-in-progress" 10 || die "no in-progress record"
pid=$(field pid "$st/repair-in-progress")
killkids "$pid"; kill -KILL "$pid"; wait 2>/dev/null || true
if out=$(rr ok 2>&1); then die "interrupted upgrade repair must block"; fi
! echo "$out" | grep -q 'running doctor' || die "silent second Doctor after an interrupted upgrade"
[ "$(cat "$st/repaired-version")" = 2026.1.1 ] || die "stamp changed"

# kp <point> <setup>: a forced (or upgrade) repair killed at <point>.
killed_at() { # killed_at <point>; leaves the state a SIGKILL there would
  rc=0; rr ok OPENCLAW_SYSTEMD_TEST_KILL_AT="$1" >"$t/out" 2>&1 || rc=$?
  [ "$rc" = 137 ] || die "kill point $1: expected SIGKILL (137), got $rc"
}
expect_blocked_no_doctor() { # expect_blocked_no_doctor <label>
  if out=$(rr ok 2>&1); then die "$1: next start must be blocked"; fi
  ! echo "$out" | grep -q 'running doctor' || die "$1: Doctor ran again"
  [ -e "$st/repair-blocked" ] || die "$1: no repair-blocked"
  [ ! -e "$st/repair-in-progress" ] || die "$1: record not cleared"
  if out=$(rr ok 2>&1); then die "$1: second restart must stay blocked"; fi
  ! echo "$out" | grep -q 'running doctor' || die "$1: Doctor ran on the second restart"
}
echo "== interrupted failed-start repair also blocks (no second Doctor until repair-retry)"
fresh; echo 0 > "$st/start-pending"
( rr silent >"$t/out" 2>&1 ) &
waitfor "$st/repair-in-progress" 10 || die "no in-progress record"
pid=$(field pid "$st/repair-in-progress")
killkids "$pid"; kill -KILL "$pid"; wait 2>/dev/null || true
[ "$(cat "$st/start-pending")" = 1 ] || die "attempt not counted before Doctor"
expect_blocked_no_doctor "open/killed"

echo "== SIGTERM after Doctor begins blocks in every mode; the next start never runs Doctor"
for kind in forced upgrade open; do
  fresh
  case $kind in
    forced) touch "$st/force-repair" ;;
    upgrade) echo 2026.1.1 > "$st/repaired-version" ;;
    open) echo 0 > "$st/start-pending" ;;
  esac
  ( rc=0; rr chatty >"$t/out" 2>&1 || rc=$?; echo $rc > "$t/term.rc" ) &
  rm -f "$t/term.rc"
  waitfor "$st/repair-in-progress" 10 || die "$kind: no guard"
  waitfor "$st/doctor.log" 10 || die "$kind: Doctor never started"
  sleep 1.5
  pid=$(field pid "$st/repair-in-progress")
  kill -TERM "$pid"
  waitfor "$t/term.rc" 15 || die "$kind: repair did not stop after SIGTERM"
  [ "$(cat "$t/term.rc")" != 0 ] || die "$kind: SIGTERM must exit non-zero"
  [ -f "$st/repair-blocked" ] || die "$kind: SIGTERM did not write the block"
  grep -q 'stop request' "$st/repair-blocked" || die "$kind: block reason"
  [ ! -e "$st/repair-in-progress" ] && [ ! -e "$mk" ] || die "$kind: guard/marker left after a durable block"
  [ -z "$(cmdmatch 'simulated doctor: working')" ] || die "$kind: Doctor survived SIGTERM"
  expect_blocked_no_doctor "term/$kind"
done
# If the block cannot be written, SIGTERM keeps the guard (as fail_closed).
fresh; touch "$st/force-repair"
( rc=0; rr chatty >"$t/out" 2>&1 || rc=$?; echo $rc > "$t/term.rc" ) &
rm -f "$t/term.rc"
waitfor "$st/repair-in-progress" 10 || die "no guard"
sleep 1.5
mkdir "$st/repair-blocked"
kill -TERM "$(field pid "$st/repair-in-progress")"
waitfor "$t/term.rc" 15 || die "did not stop"
[ "$(cat "$t/term.rc")" != 0 ] && [ -e "$st/repair-in-progress" ] || die "guard dropped although the block could not be written"
rm -rf "$st/repair-blocked"
expect_blocked_no_doctor "term/unwritable-block"

echo "== test hooks cannot reach the user manager through the environment file"
hooks="SIMULATE=ok KILL_AT=after-guard HOLD_FILE=/x HARD_CAP_SECS=1 PROGRESS_SECS=1 HEARTBEAT_SECS=1 TICK=1 READY_SECS=1"
envargs=
for h in $hooks; do envargs="$envargs OPENCLAW_SYSTEMD_TEST_$h"; done
# shellcheck disable=SC2086
env -i PATH=/usr/bin:/bin $envargs OPENCLAW_SYSTEMD_HEAP_MIB=8192 KEEP=1 \
  /usr/local/bin/node "$lx/write-env-file.mjs" "$t/envfile"
! grep -q 'OPENCLAW_SYSTEMD_TEST_' "$t/envfile" || die "a test hook was written to the env file"
grep -qx 'KEEP="1"' "$t/envfile" && grep -qx 'OPENCLAW_SYSTEMD_HEAP_MIB="8192"' "$t/envfile" || die "legitimate vars were dropped"
# Every hook the scripts read is covered by that prefix.
for f in repair-if-needed mark-healthy repair-retry maintenance.sh; do
  bad=$(grep -o 'OPENCLAW_SYSTEMD_[A-Z_]*' "$lx/$f" | sort -u | grep -v '^OPENCLAW_SYSTEMD_TEST_' || true)
  [ -z "$bad" ] || die "$f reads a hook outside the OPENCLAW_SYSTEMD_TEST_ prefix: $bad"
done

echo "== stale markers: dead owner, past hard cap; foreign markers are never touched"
fresh
now=$(date +%s)
# The fast path arms start-pending, which would make the next run a
# failed-start repair; each case here starts without it.
mkmarker() { # mkmarker <phase> <pid> <deadline> [owner]
  rm -f "$st/start-pending"
  printf 'owner=%s\nphase=%s\npid=%s\npidstart=\ninvocation=\nreason=t\nstart=%s\ndeadline=%s\n' \
    "${4:-openclaw-systemd}" "$1" "$2" "$now" "$3" > "$mk"
}
deadpid=$( (exit 0) & echo $! ); wait "$deadpid" 2>/dev/null || true
mkmarker repair "$deadpid" $((now + 3600))
out=$(rr fail) || die "fast path exited non-zero"
echo "$out" | grep -q 'removed stale marker' && [ ! -e "$mk" ] || die "dead-owner marker not reaped"
mkmarker repair $$ $((now - 1))
out=$(rr fail) || die "fast path exited non-zero"
echo "$out" | grep -q 'removed stale marker' && [ ! -e "$mk" ] || die "past-cap marker not reaped"
mkmarker repair $$ $((now + 3600))
out=$(rr fail) || die "fast path exited non-zero"
[ -e "$mk" ] || die "a live owner within its cap must not be reaped: $out"
mkmarker awaiting-ready "" $((now + 3600)); sed -i 's/^invocation=.*/invocation=old-run/' "$mk"
out=$(rr fail INVOCATION_ID=other) || die "fast path exited non-zero"
[ ! -e "$mk" ] || die "an awaiting-ready marker from another invocation must be reaped"
# Foreign: no owner fields at all, and a different owner.
printf 'hand made\n' > "$mk"; touch -d '2000-01-01' "$mk"
rr fail >/dev/null
[ "$(cat "$mk")" = 'hand made' ] || die "operator marker rewritten or removed"
mkmarker repair "$deadpid" $((now - 1)) someone-else
rr fail >/dev/null
[ -e "$mk" ] || die "a foreign-owner marker must never be reaped"
# A repair that finds an operator marker runs and leaves it as it was.
printf 'hand made\n' > "$mk"; touch "$st/force-repair"
rr ok >/dev/null
[ "$(cat "$mk")" = 'hand made' ] || die "repair overwrote the operator's marker"

echo "== readiness: marker survives /healthz alone, removed only after /readyz"
fresh
mkmarker awaiting-ready "" $((now + 3600))
echo 0 > "$st/start-pending"
touch "$sb/healthz"
( PATH=$t:$PATH STUB_DIR=$sb HOME=$H OPENCLAW_SYSTEMD_TEST_READY_SECS=30 OPENCLAW_SYSTEMD_TEST_TICK=1 \
    "$mh" openclaw-gateway.service >"$t/mh.out" 2>&1 ) &
bg=$!
sleep 3
[ ! -e "$st/start-pending" ] || die "healthz did not clear start-pending"
[ -e "$mk" ] || die "marker removed before /readyz"
touch "$sb/readyz"
wait "$bg"
[ ! -e "$mk" ] || die "marker not removed once ready"
grep -q 'removed' "$t/mh.out" || die "removal not logged"

echo "== readiness: operator's marker and another run's marker are left"
fresh
printf 'hand made\n' > "$mk"; touch "$sb/healthz" "$sb/readyz"
out=$(PATH=$t:$PATH STUB_DIR=$sb HOME=$H "$mh" openclaw-gateway.service)
[ -e "$mk" ] && echo "$out" | grep -q 'no owner fields' || die "operator marker removed or not logged"
mkmarker repair $$ $((now + 3600))
out=$(PATH=$t:$PATH STUB_DIR=$sb HOME=$H "$mh" openclaw-gateway.service)
[ -e "$mk" ] || die "a live repair-phase marker must not be removed by mark-healthy"
mkmarker awaiting-ready "" $((now + 3600))
sed -i 's/^invocation=.*/invocation=old-run/' "$mk"
out=$(PATH=$t:$PATH STUB_DIR=$sb HOME=$H INVOCATION_ID=new-run "$mh" openclaw-gateway.service)
[ -e "$mk" ] || die "a marker from a different invocation must be left"

echo "== readiness never arrives: the expired marker is released, start-pending kept"
fresh
mkmarker awaiting-ready "" $((now + 3600)); echo 0 > "$st/start-pending"
out=$(PATH=$t:$PATH STUB_DIR=$sb HOME=$H OPENCLAW_SYSTEMD_TEST_READY_SECS=2 OPENCLAW_SYSTEMD_TEST_TICK=1 "$mh" openclaw-gateway.service)
[ ! -e "$mk" ] && [ -e "$st/start-pending" ] || die "expired marker/pending handling"
echo "$out" | grep -q 'not healthy within' || die "unhealthy not reported"

echo "== fault injection: SIGKILL at each boundary before Doctor; next start blocks and never runs Doctor"
for point in after-guard after-marker after-force; do
  fresh; touch "$st/force-repair"
  killed_at $point
  [ -e "$st/repair-in-progress" ] || die "$point: guard record must already exist"
  case $point in
    after-guard) [ ! -e "$mk" ] && [ -e "$st/force-repair" ] || die "$point: marker/force state" ;;
    after-marker) [ -e "$mk" ] && [ -e "$st/force-repair" ] || die "$point: marker/force state" ;;
    after-force) [ -e "$mk" ] && [ ! -e "$st/force-repair" ] || die "$point: marker/force state" ;;
  esac
  expect_blocked_no_doctor "forced/$point"
  [ ! -e "$mk" ] || die "forced/$point: stale marker left"
done
# The same boundaries for an upgrade repair (no force-repair; stamp unchanged).
for point in after-guard after-marker; do
  fresh; echo 2026.1.1 > "$st/repaired-version"
  killed_at $point
  expect_blocked_no_doctor "upgrade/$point"
  [ "$(cat "$st/repaired-version")" = 2026.1.1 ] || die "upgrade/$point: stamp changed"
done
# A failed-start repair killed right after its guard blocks too: the attempt
# was counted, but the interruption rule applies in every mode.
fresh; echo 0 > "$st/start-pending"
killed_at after-guard
[ "$(cat "$st/start-pending")" = 1 ] || die "open/after-guard: attempt not counted"
expect_blocked_no_doctor "open/after-guard"

echo "== fault injection: SIGKILL between writing the block and removing the record"
fresh
printf 'version=%s\nmode=closed\nreason=forced by test\npid=%s\npidstart=\n' "$v" "$deadpid" > "$st/repair-in-progress"
touch "$st/force-repair"
rc=0; rr ok OPENCLAW_SYSTEMD_TEST_KILL_AT=after-block >"$t/out" 2>&1 || rc=$?
[ "$rc" = 137 ] || die "after-block: expected SIGKILL, got $rc"
[ -e "$st/repair-blocked" ] && [ -e "$st/repair-in-progress" ] || die "after-block: block and record must both exist"
expect_blocked_no_doctor "after-block"
# And a kill before the block is written leaves only the record: still detected.
fresh
printf 'version=%s\nmode=closed\nreason=forced by test\npid=%s\npidstart=\n' "$v" "$deadpid" > "$st/repair-in-progress"
expect_blocked_no_doctor "record-only"
# An unwritable block keeps the record and fails closed, never silently clears it.
fresh
printf 'version=%s\nmode=closed\nreason=forced by test\npid=%s\npidstart=\n' "$v" "$deadpid" > "$st/repair-in-progress"
chmod 555 "$st"
if out=$(rr ok 2>&1); then die "unwritable block must fail closed"; fi
[ -e "$st/repair-in-progress" ] || die "record removed although the block could not be written"
! echo "$out" | grep -q 'running doctor' || die "Doctor ran with an unwritable block"
chmod 755 "$st"

echo "== concurrent owner: a replaced marker is never refreshed, handed over or removed"
fresh; now=$(date +%s)
other() { # another run's live marker (this shell's pid is alive)
  printf 'owner=openclaw-systemd\nphase=repair\npid=%s\npidstart=\ninvocation=other-run\nreason=other\nstart=%s\ndeadline=%s\n' \
    $$ "$now" $((now + 3600)) > "$mk"
  touch -d '2000-01-01' "$mk"
}
# Library level: write as run A, then run B replaces it.
(
  HOME=$H INVOCATION_ID=run-a; . "$lx/maintenance.sh"
  mt_write repair r $$ "$now" $((now + 60)) || exit 1
  mt_mine || exit 2
  other
  mt_touch_mine && exit 3
  [ "$(stat -c %Y "$mk")" -lt 1000000000 ] || exit 4
  mt_rm_mine && exit 5
  [ -e "$mk" ] || exit 6
  mt_write awaiting-ready r "" "$now" $((now + 60)) guard && exit 7
  [ "$(field invocation)" = other-run ] || exit 8
) >"$t/conc.out" 2>&1 || die "library concurrent-owner check failed at step $?: $(cat "$t/conc.out")"
grep -q 'belongs to another run' "$t/conc.out" || die "mismatch not logged"
# Whole run: another run takes over the marker mid-repair. This run's
# heartbeat, hard-cap cleanup and block path must leave it alone.
fresh; touch "$st/force-repair"
( rr chatty OPENCLAW_SYSTEMD_TEST_HARD_CAP_SECS=5 INVOCATION_ID=run-a >"$t/out" 2>&1 || true ) &
bg=$!
waitfor "$mk" 10 || die "no marker"
other
sleep 3
[ "$(stat -c %Y "$mk")" -lt 1000000000 ] || die "heartbeat refreshed another run's marker"
wait "$bg" 2>/dev/null || true
[ -e "$mk" ] && [ "$(field invocation)" = other-run ] || die "this run's cleanup removed another run's marker"
grep -q 'belongs to another run' "$t/out" || die "takeover not logged"
# mark-healthy likewise: a marker from a different invocation is neither
# touched nor removed, even when the readiness check passes.
fresh; touch "$sb/healthz" "$sb/readyz"; other
sed -i 's/^phase=.*/phase=awaiting-ready/; s/^pid=.*/pid=/' "$mk"; touch -d '2000-01-01' "$mk"
PATH=$t:$PATH STUB_DIR=$sb HOME=$H INVOCATION_ID=run-a "$mh" openclaw-gateway.service >/dev/null
[ -e "$mk" ] && [ "$(stat -c %Y "$mk")" -lt 1000000000 ] || die "mark-healthy touched or removed another invocation's marker"

echo "== fault injection: SIGKILL after Doctor succeeded; next start completes without Doctor"
# From the doctor_ok record on, a kill is recovered by finishing the repair:
# no second Doctor, no failed-start repair, no block.
completed_no_doctor() { # completed_no_doctor <label>
  out=$(rr fail INVOCATION_ID=inv-rec 2>&1) || die "$1: next start must complete, not fail: $out"
  ! echo "$out" | grep -q 'running doctor' || die "$1: Doctor ran again"
  echo "$out" | grep -q 'completing it without running Doctor' || die "$1: no completion message"
  got_pending=$(cat "$st/start-pending" 2>/dev/null || echo none)
  [ ! -e "$st/repair-in-progress" ] && [ ! -e "$st/repair-blocked" ] || die "$1: guard/block left"
  [ "$(cat "$st/repaired-version")" = "$v" ] || die "$1: stamp not current"
  # The startup window is re-established for the new invocation, with a
  # deadline, and mark-healthy removes it on /readyz.
  [ "$(field owner)" = openclaw-systemd ] && [ "$(field phase)" = awaiting-ready ] \
    && [ "$(field invocation)" = inv-rec ] && [ "$(field deadline)" -gt "$(date +%s)" ] \
    || die "$1: no awaiting-ready marker for the new invocation"
  touch "$sb/healthz" "$sb/readyz"
  PATH=$t:$PATH STUB_DIR=$sb HOME=$H INVOCATION_ID=inv-rec "$mh" openclaw-gateway.service >/dev/null
  [ ! -e "$mk" ] || die "$1: mark-healthy did not remove the recovery marker"
  rm -f "$sb/healthz" "$sb/readyz"
  # The gateway then became healthy (mark-healthy clears the failed-start
  # marker); the following start must find nothing to repair.
  rm -f "$st/start-pending"
  out=$(rr fail 2>&1) || die "$1: following start failed"
  ! echo "$out" | grep -q 'running doctor' || die "$1: Doctor ran on the following start"
}
for point in after-doctor-mark after-stamp before-handover after-handover; do
  fresh; touch "$st/force-repair"
  killed_at $point
  [ -e "$st/repair-in-progress" ] || die "forced/$point: guard must survive until the end"
  completed_no_doctor "forced/$point"
  [ "$got_pending" = 0 ] || die "forced/$point: pending not armed"
  [ ! -e "$st/force-repair" ] || die "forced/$point: force left"
done
for point in after-doctor-mark after-stamp before-handover; do
  fresh; echo 2026.1.1 > "$st/repaired-version"
  killed_at $point
  completed_no_doctor "upgrade/$point"
done
# A failed-start repair that already succeeded must not be selected again.
for point in after-doctor-mark after-stamp before-handover after-handover; do
  fresh; echo 0 > "$st/start-pending"
  killed_at $point
  completed_no_doctor "open/$point"
  [ "$got_pending" = 1 ] || die "open/$point: attempt count changed"
done
# The one narrow gap: killed between Doctor's exit and the doctor_ok record.
# It fails closed (blocked) in every mode, never loops.
fresh; touch "$st/force-repair"
killed_at after-doctor-ok
expect_blocked_no_doctor "forced/after-doctor-ok"
fresh; echo 0 > "$st/start-pending"
killed_at after-doctor-ok
expect_blocked_no_doctor "open/after-doctor-ok"

echo "== recovery replaces only the interrupted run's marker, under one lock"
# (a) repair-retry runs outside systemd with no InvocationID: an empty ID proves
# nothing, so it must not reap a live handed-over marker.
fresh; now=$(date +%s)
printf 'owner=openclaw-systemd\nphase=awaiting-ready\npid=\npidstart=\ninvocation=live-run\nreason=r\nstart=%s\ndeadline=%s\n' "$now" $((now + 3600)) > "$mk"
env -u INVOCATION_ID HOME=$H PATH=$t/rtbin:$PATH "$rt" >/dev/null || die "retry failed"
[ "$(field invocation)" = live-run ] || die "repair-retry (no InvocationID) removed a live awaiting-ready marker"
# (b) two recoveries read the same dead doctor_ok guard; the late one must find
# the work done and touch nothing.
fresh; touch "$st/force-repair"
killed_at after-handover
: > "$t/holdA"; : > "$t/holdB"; rm -f "$t/holdA.reached" "$t/holdB.reached" "$t/rcA" "$t/rcB"
( rc=0; rr fail INVOCATION_ID=inv-A OPENCLAW_SYSTEMD_TEST_HOLD_FILE="$t/holdA" >"$t/outA" 2>&1 || rc=$?; echo $rc > "$t/rcA" ) &
( rc=0; rr fail INVOCATION_ID=inv-B OPENCLAW_SYSTEMD_TEST_HOLD_FILE="$t/holdB" >"$t/outB" 2>&1 || rc=$?; echo $rc > "$t/rcB" ) &
waitfor "$t/holdA.reached" 10 && waitfor "$t/holdB.reached" 10 || die "both recoveries must have read the guard"
rm -f "$t/holdA"
waitfor "$t/rcA" 15 || die "recovery A did not finish"
[ "$(cat "$t/rcA")" = 0 ] && [ "$(field invocation)" = inv-A ] && [ "$(field phase)" = awaiting-ready ] || die "recovery A: marker/exit"
[ ! -e "$st/repair-in-progress" ] || die "recovery A left the guard"
# The gateway became healthy meanwhile: mark-healthy cleared failed-start state.
rm -f "$st/start-pending"; cp "$mk" "$t/marker.after-A"
rm -f "$t/holdB"
waitfor "$t/rcB" 15 || die "recovery B did not finish"
[ "$(cat "$t/rcB")" = 0 ] || die "recovery B must exit 0"
cmp -s "$mk" "$t/marker.after-A" || die "the late recovery changed the winner's marker"
[ ! -e "$st/start-pending" ] || die "the late recovery re-armed failed-start detection"
grep -q 'nothing to do' "$t/outB" || die "late recovery did not report that it had nothing to do: $(cat "$t/outB")"
# (c) the leftover marker of the killed run, with no InvocationIDs at all, is
# replaced by this start's marker (the CI case).
fresh; touch "$st/force-repair"
env -u INVOCATION_ID HOME=$H OPENCLAW_SYSTEMD_TEST_SIMULATE=ok OPENCLAW_SYSTEMD_TEST_KILL_AT=after-handover "$r" openclaw-gateway.service >/dev/null 2>&1 || true
[ -z "$(field invocation)" ] && [ "$(field phase)" = awaiting-ready ] || die "setup: expected the killed run's empty-ID marker"
out=$(env -u INVOCATION_ID HOME=$H OPENCLAW_SYSTEMD_TEST_SIMULATE=fail INVOCATION_ID=inv-new "$r" openclaw-gateway.service 2>&1) || die "empty-ID recovery failed: $out"
[ "$(field invocation)" = inv-new ] || die "empty-ID leftover marker was not replaced"
# A marker that is not the dead run's (an operator's, a live run's) is left alone.
mkguard_done() { printf 'version=%s\nmode=closed\nreason=r\npid=%s\npidstart=\ninvocation=gone\nstart=100\ndoctor_ok=1\n' "$v" "$deadpid" > "$st/repair-in-progress"; }
fresh; mkguard_done; printf 'hand made\n' > "$mk"
out=$(rr fail INVOCATION_ID=inv-x 2>&1) || die "recovery over an operator marker failed"
[ "$(cat "$mk")" = 'hand made' ] && [ ! -e "$st/repair-in-progress" ] || die "operator marker touched, or guard kept"
echo "$out" | grep -q 'left alone' || die "foreign marker not reported"
fresh; mkguard_done
printf 'owner=openclaw-systemd\nphase=repair\npid=%s\npidstart=\ninvocation=other\nreason=r\nstart=555\ndeadline=%s\n' $$ $((now + 3600)) > "$mk"
rr fail INVOCATION_ID=inv-x >/dev/null 2>&1 || die "recovery over a live run's marker failed"
[ "$(field invocation)" = other ] && [ ! -e "$st/repair-in-progress" ] || die "a live run's marker was replaced"

echo "== fail_closed keeps the guard whenever the block cannot be written"
fresh; touch "$st/force-repair"
mkdir "$st/repair-blocked"
if out=$(rr fail 2>&1); then die "unwritable block must exit non-zero"; fi
[ -e "$st/repair-in-progress" ] || die "guard removed although the block failed"
[ ! -e "$mk" ] || die "marker left"
rm -rf "$st/repair-blocked"
expect_blocked_no_doctor "fail_closed/unwritable-block"

echo "== marker lock: a mutation waits for another holder, then sees the replaced identity"
fresh; now=$(date +%s)
lk=$st/maintenance.lock
(
  HOME=$H INVOCATION_ID=run-a; . "$lx/maintenance.sh"
  mt_write repair r $$ "$now" $((now + 60)) create || exit 1
  touch -d '2000-01-01' "$mk"
  # A second process takes the lock, replaces the marker, holds for 2s.
  ( flock 9; : > "$t/lock-held"
    other
    sleep 2 ) 9>"$lk" &
  waitfor "$t/lock-held" 10 || exit 2
  s0=$(date +%s)
  mt_touch_mine && exit 3
  [ $(( $(date +%s) - s0 )) -ge 1 ] || exit 4
  [ "$(stat -c %Y "$mk")" -lt 1000000000 ] || exit 5
  [ "$(field invocation)" = other-run ] || exit 6
) >"$t/lock.out" 2>&1 || die "lock test failed at step $?: $(cat "$t/lock.out")"
grep -q 'belongs to another run' "$t/lock.out" || die "replacement not reported after the wait"
# An unrelated mutation under an idle lock is not delayed.
(
  HOME=$H INVOCATION_ID=run-b; . "$lx/maintenance.sh"
  rm -f "$mk"
  mt_write repair r $$ "$now" $((now + 60)) create || exit 1
  s0=$(date +%s); mt_touch_mine || exit 2; [ $(( $(date +%s) - s0 )) -lt 2 ] || exit 3
  mt_write repair r $$ "$now" $((now + 60)) create; [ $? = 2 ] || exit 4
  mt_rm_mine || exit 5
) || die "idle-lock mutation failed at step $?"

echo "== repair-retry: --state-only does state work only (the internal re-exec target)"
fresh; : > "$t/rtbin.log"; echo "$v oops" > "$st/repair-blocked"
HOME=$H PATH=$t/rtbin:$PATH "$rt" --state-only >"$t/rt.out" 2>&1 || die "state-only failed: $(cat "$t/rt.out")"
[ -e "$st/maintenance.lock" ] && [ -e "$st/force-repair" ] && [ ! -e "$st/repair-blocked" ] || die "state-only did not do the state work"
[ ! -s "$t/rtbin.log" ] || die "state-only started or reset the gateway"
! grep -q 'OPENCLAW_SYSTEMD_TEST_' "$rt" || die "repair-retry reads a test hook from the environment"

echo "== repair-retry's root branch (static; real root behaviour is covered by boot-test.sh)"
# A test cannot become root, and root-side commands must not be resolvable
# through an inherited PATH (so PATH stubs cannot stand in for them), so the
# root branch is checked structurally here and exercised for real in the image
# by boot-test.sh, which runs repair-retry as root and checks file ownership.
grep -q '"\$(/usr/bin/id -u)" = 0' "$rt" || die "root-ness is not decided with the absolute /usr/bin/id"
! grep -E '(^|[^/A-Za-z_])id -u' "$rt" | grep -v '^#' | grep -q . || die "a bare id -u is used"
pin='PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
grep -qxF "  $pin" "$rt" || die "root PATH is not pinned"
# Before the pin: only comments, blank lines, `set -u`, and the root test itself.
before=$(sed -n '1,/^  PATH=\/usr\/local\/sbin/p' "$rt" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')
want='#!/bin/sh
set -u
if [ "$(/usr/bin/id -u)" = 0 ]; then
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
before=$(sed -n '1,/^  PATH=\/usr\/local\/sbin/p' "$rt" | grep -v '^[[:space:]]*#\($\|[^!]\)' | grep -v '^[[:space:]]*$')
[ "$before" = "$want" ] || die "a command runs before PATH is pinned for root: $before"
# The pinned PATH is passed explicitly across both setpriv re-execs.
[ "$(grep -c 'PATH="\$PATH"' "$rt")" -ge 2 ] || die "PATH is not passed explicitly across the setpriv re-exec"
grep -q -- '--state-only is internal and must not run as root' "$rt" || die "root --state-only is not refused"
! grep -q 'chown' "$rt" || die "repair-retry still chowns state as root"
grep -q '"\$0" --state-only' "$rt" || die "state-only re-exec missing"
grep -q 'exec openclaw gateway start' "$rt" || die "start step missing"

echo "== interleaving: a guard written under the lock is never cleared by repair-retry, nor overwritten by a repair"
mkguard() { printf 'version=%s\nmode=closed\nreason=other\npid=%s\npidstart=%s\n' "$v" $$ "$( ( . "$lx/maintenance.sh"; mt_pidstart $$ ) )" > "$st/repair-in-progress"; }
# holder: takes the lock, then (after the contender is waiting) writes a LIVE
# guard and releases.
fresh; : > "$sb/x"
( flock 9; : > "$t/held"; sleep 2; mkguard ) 9>"$st/maintenance.lock" &
waitfor "$t/held" 10 || die "holder never took the lock"
s0=$(date +%s)
if HOME=$H PATH=$t/rtbin:$PATH "$rt" >"$t/rt.out" 2>&1; then die "retry must refuse once a live guard exists"; fi
[ $(( $(date +%s) - s0 )) -ge 1 ] || die "retry did not wait for the lock"
grep -q 'still running' "$t/rt.out" || die "retry did not report the running repair"
[ -f "$st/repair-in-progress" ] || die "retry deleted a live guard"
rm -f "$t/held"
fresh; touch "$st/force-repair"
( flock 9; : > "$t/held"; sleep 2; mkguard ) 9>"$st/maintenance.lock" &
waitfor "$t/held" 10 || die "holder never took the lock"
if out=$(rr ok 2>&1); then die "repair must not start over a guard written first"; fi
# Either refusal is correct: mt_reap also takes the lock, so the repair usually
# waits there and then finds the live record at its first check; the in-lock
# check is the backstop for the window after that.
echo "$out" | grep -q 'appeared first\|still running' || die "repair did not report the competing record: $out"
! echo "$out" | grep -q 'running doctor' && true
grep -q 'other' "$st/repair-in-progress" || die "repair overwrote the other run's guard"
rm -f "$t/held"; fresh

# The precise window: the repair has decided and not yet written its guard.
# repair-retry runs then (no record to clear), and a second repair's live guard
# lands before the first writes its own: the first must refuse, not overwrite.
fresh; touch "$st/force-repair"; : > "$t/hold"; rm -f "$t/hold.reached"
( rc=0; rr ok OPENCLAW_SYSTEMD_TEST_HOLD_FILE="$t/hold" >"$t/out" 2>&1 || rc=$?; echo $rc > "$t/hold.rc" ) &
waitfor "$t/hold.reached" 10 || die "repair never reached the guard write"
HOME=$H PATH=$t/rtbin:$PATH "$rt" >/dev/null || die "retry in the window failed"
mkguard
rm -f "$t/hold"
waitfor "$t/hold.rc" 10 || die "repair did not finish"
sleep 0.2
[ "$(cat "$t/hold.rc")" = 1 ] || die "repair must refuse after another guard appeared"
grep -q 'appeared first' "$t/out" || die "in-lock refusal not reported: $(cat "$t/out")"
! grep -q 'running doctor' "$t/out" || die "Doctor ran unguarded"
grep -q 'other' "$st/repair-in-progress" || die "repair overwrote the other guard"
fresh

echo "== repair-retry: clears the block, arms force-repair, refuses while a repair runs"
fresh; echo "$v something broke" > "$st/repair-blocked"
printf 'version=%s\nmode=closed\npid=%s\npidstart=\n' "$v" "$deadpid" > "$st/repair-in-progress"
mkmarker repair "$deadpid" $((now + 3600))
HOME=$H PATH=$t/rtbin:$PATH "$rt" >/dev/null || die "repair-retry failed"
[ ! -e "$st/repair-blocked" ] && [ ! -e "$st/repair-in-progress" ] && [ ! -e "$mk" ] || die "retry left blocked state"
[ -e "$st/force-repair" ] || die "retry did not arm force-repair"
grep -q 'openclaw gateway start' "$t/rtbin.log" || die "retry did not start the gateway"
out=$(rr ok) || die "retried repair failed"
echo "$out" | grep -q 'running doctor --fix (forced' || die "retry did not run a forced repair"
printf 'version=%s\nmode=closed\npid=%s\npidstart=\n' "$v" $$ > "$st/repair-in-progress"
if HOME=$H PATH=$t/rtbin:$PATH "$rt" >/dev/null 2>&1; then die "retry must refuse while a repair is running"; fi

echo "maintenance tests passed"
