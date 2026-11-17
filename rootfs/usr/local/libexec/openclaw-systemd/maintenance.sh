#!/bin/sh
# Sourced (not executed) by repair-if-needed, mark-healthy and repair-retry.
# Owns the maintenance marker, $HOME/.openclaw/MAINTENANCE, that the
# Kubernetes startup probe treats as "a legitimate long start is in progress"
# (it passes while the file is younger than 240 minutes). Every repair run
# creates it BEFORE work starts and the lifecycle removes it again, so nobody
# has to hand-create a marker or patch a timeout mid-upgrade.
#
# Format: one key=value per line, written whole to a temp file and moved into
# place so a reader never sees a partial marker:
#
#   owner       always "openclaw-systemd"; a marker without it was made by a
#               person and is never removed, rewritten or reaped here
#   phase       "repair" (Doctor running, pid below is its owner) or
#               "awaiting-ready" (repair done, waiting for /readyz; no owner
#               pid, the unit's invocation and the deadline bound it)
#   pid         owner process; pidstart is its /proc start time, so a reused
#               pid is not mistaken for the owner
#   invocation  systemd InvocationID of the gateway start (may be empty)
#   reason      why the run exists
#   start       epoch seconds when the run began
#   deadline    epoch seconds; past it the marker is stale whatever else holds
#
# Liveness is kept visible to the probe by re-touching the file (mtime); the
# probe cannot read the deadline, only its own mtime window. See README.md.

mt_tag=openclaw-systemd
mt_marker=${HOME:?HOME not set}/.openclaw/MAINTENANCE

mt_field() { sed -n "s/^$1=//p" "${2:-$mt_marker}" 2>/dev/null | head -n 1; }

# 0 when the marker exists and carries this lifecycle's owner tag.
mt_owned() { [ -f "$mt_marker" ] && [ "$(mt_field owner)" = "$mt_tag" ]; }

# /proc/<pid>/stat field 22 (start time). The command name (field 2) may hold
# spaces and parentheses, so strip through the last ") " first; what remains
# starts at field 3.
mt_pidstart() { sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20; }

# A process that exited but was not yet reaped still answers kill -0, so a
# zombie counts as gone.
mt_running() {
  [ -n "${1:-}" ] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  [ "$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -c1)" != Z ]
}

# mt_pid_is_owner <pid> <pidstart>: the same process that wrote the marker.
mt_pid_is_owner() {
  mt_running "$1" || return 1
  [ -z "${2:-}" ] || [ "$(mt_pidstart "$1")" = "$2" ]
}

# One-read snapshot of a marker's run identity: owner|phase|pid|pidstart|
# invocation|start|. Read once so the fields cannot straddle a replacement.
mt_ident() {
  _c=$(cat "$mt_marker" 2>/dev/null) || return 1
  for _k in owner phase pid pidstart invocation start; do
    printf '%s|' "$(printf '%s\n' "$_c" | sed -n "s/^$_k=//p" | head -n 1)"
  done
}

# Every marker mutation (create, touch, handover, remove, reap) runs under one
# flock on $state/maintenance.lock, in repair-if-needed, mark-healthy and
# repair-retry alike, and re-checks the run identity INSIDE the lock. Writers
# that honour the lock therefore cannot interleave a check with another run's
# replace: a marker another run replaced is left alone. The lock is held only
# for the brief mutation (a few syscalls), never across Doctor or the
# readiness wait. Descriptor 9 holds it; it is closed before anything long
# runs, so no child inherits it. Residual: a person editing the marker by hand
# does not take the lock, and if flock is missing the helpers warn and run
# unlocked (the image installs util-linux, and static-checks.sh asserts it).
mt_lockfile=${HOME:?HOME not set}/.openclaw/state/openclaw-systemd/maintenance.lock
mt_lock() {
  mkdir -p "$(dirname "$mt_lockfile")" 2>/dev/null
  command -v flock >/dev/null 2>&1 || { echo "maintenance: flock not found; marker changes are unserialised"; return 0; }
  { : >> "$mt_lockfile"; } 2>/dev/null || { echo "maintenance: cannot open $mt_lockfile"; return 1; }
  exec 9>> "$mt_lockfile"
  flock -w 30 9 || { exec 9>&-; echo "maintenance: could not take $mt_lockfile within 30s"; return 1; }
}
mt_unlock() { exec 9>&-; }

# The identity this process last wrote (mt_write) or adopted (mark-healthy).
# Refresh, handover and removal require the marker to still be exactly that.
mt_expect=
mt_mine() { [ -n "$mt_expect" ] && [ "$(mt_ident)" = "$mt_expect" ]; }
mt_changed() { echo "maintenance: $mt_marker belongs to another run now; left alone"; return 1; }

# mt_write <phase> <reason> <pid> <start> <deadline> [guard|create]
#   guard   the marker on disk must still be ours
#   create  the marker must not exist; returns 2 if one does
# Both checks and the rename happen under the lock.
mt_write() {
  _mt_reason=$(printf '%s' "$2" | tr '\n\r' '  ')
  _mt_ps=
  [ -n "$3" ] && _mt_ps=$(mt_pidstart "$3")
  _mt_tmp=$mt_marker.tmp.$$
  mkdir -p "$(dirname "$mt_marker")" 2>/dev/null
  {
    echo "owner=$mt_tag"
    echo "phase=$1"
    echo "pid=$3"
    echo "pidstart=$_mt_ps"
    echo "invocation=${INVOCATION_ID:-}"
    echo "reason=$_mt_reason"
    echo "start=$4"
    echo "deadline=$5"
  } > "$_mt_tmp" || { rm -f "$_mt_tmp" 2>/dev/null; return 1; }
  mt_lock || { rm -f "$_mt_tmp"; return 1; }
  _mt_rc=0
  if [ "${6:-}" = guard ] && ! mt_mine; then
    mt_changed; _mt_rc=1
  elif [ "${6:-}" = create ] && [ -e "$mt_marker" ]; then
    _mt_rc=2
  elif mv -f "$_mt_tmp" "$mt_marker"; then
    mt_expect="$mt_tag|$1|$3|$_mt_ps|${INVOCATION_ID:-}|$4|"
  else
    _mt_rc=1
  fi
  mt_unlock
  rm -f "$_mt_tmp" 2>/dev/null
  return $_mt_rc
}

# Keep the probe's mtime window fresh, only on a marker that is still ours.
mt_touch_mine() {
  mt_lock || return 1
  if mt_mine; then touch "$mt_marker" 2>/dev/null; _mt_rc=0; else mt_changed; _mt_rc=1; fi
  mt_unlock
  return $_mt_rc
}
mt_rm_mine() {
  mt_lock || return 1
  if mt_mine; then rm -f "$mt_marker"; _mt_rc=0; else mt_changed; _mt_rc=1; fi
  mt_unlock
  return $_mt_rc
}

# 0 when a marker THIS lifecycle owns is stale. A marker without our owner tag
# is never stale (it is somebody's, and not ours to judge). Stale means any of:
#   - past its recorded hard-cap deadline;
#   - phase=repair and its owner process is gone (or the pid was reused);
#   - phase=awaiting-ready, belonging to a different systemd invocation than
#     the caller's (a later start): the readiness wait it described is over.
# A stale marker never grants anything: callers remove it.
mt_stale() {
  mt_owned || return 1
  _now=$(date +%s)
  _dl=$(mt_field deadline)
  case "$_dl" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_now" -ge "$_dl" ] && return 0
  case "$(mt_field phase)" in
    repair)
      mt_pid_is_owner "$(mt_field pid)" "$(mt_field pidstart)" || return 0 ;;
    awaiting-ready)
      # Differing invocations, including one side being empty (a marker
      # written without an InvocationID, or read without one): the readiness
      # wait it described belongs to an earlier start. Only two empty IDs
      # (no systemd at all) cannot be told apart.
      _mi=$(mt_field invocation)
      if [ "$_mi" != "${INVOCATION_ID:-}" ]; then
        return 0
      fi ;;
    *) return 0 ;;
  esac
  return 1
}

# mt_drop_awaiting: remove our own awaiting-ready marker whatever its
# invocation. Recovery of a finished-but-killed repair uses it: the guard's
# owner is dead, so any awaiting-ready marker is a leftover of that run, and the
# start now beginning needs its own (stale detection alone cannot tell two runs
# apart when neither has an InvocationID).
mt_drop_awaiting() {
  mt_lock || return 1
  if mt_owned && [ "$(mt_field phase)" = awaiting-ready ]; then
    rm -f "$mt_marker"
    echo "maintenance: replaced the awaiting-ready marker left by the interrupted run"
  fi
  mt_unlock
}

# Decision point: drop our own marker if stale. Says so, so a leftover from a
# killed run is visible in the log instead of silently vanishing.
mt_reap() {
  mt_lock || return 0
  if mt_stale; then
    _reap_phase=$(mt_field phase)
    rm -f "$mt_marker"
    echo "maintenance: removed stale marker (phase=${_reap_phase:-unknown})"
  fi
  mt_unlock
}
