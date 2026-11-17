# openclaw-systemd

The upstream [OpenClaw](https://github.com/openclaw/openclaw) container image with **systemd as PID 1**, so the gateway runs as a native OpenClaw systemd user service inside a Kubernetes pod.

The upstream image starts the gateway directly, so stopping the gateway ends the container. That rules out every command that needs the gateway down: `openclaw gateway stop/start/restart`, `openclaw doctor --fix`, and database maintenance. Here, those commands behave the way they do on a local install. The container keeps running while the gateway is stopped.

Images: `ghcr.io/clawd-ops/openclaw-systemd:<openclaw-version>`. The version tracks upstream through Renovate. Updates are image bumps; `openclaw update` is not supported in the container.

## How it works

1. A root entrypoint prepares the container, drops to 7 capabilities, and `exec`s systemd.
2. systemd starts a lingering user manager for uid 1000 (`node`, whose home is `/home/openclaw`).
3. On first boot, `openclaw-bootstrap.service` runs `openclaw gateway install`. OpenClaw writes its own user unit onto the state volume. Later boots find that unit and the user manager starts it.
4. The gateway runs as uid 1000 with no capabilities, `NoNewPrivs`, and the pod's seccomp profile, the same as the upstream image.
5. Before each gateway start, a drop-in decides whether to run `openclaw doctor --fix` first. See [Upgrades and repair](#upgrades-and-repair).

| Concern | Handling |
|---|---|
| Kubernetes env and Secrets | Written each boot to `/run/openclaw/gateway.env` (tmpfs, root 0600) and loaded by the user manager, so every user unit, including the gateway, gets them. Never written to the state volume. |
| Keys OpenClaw persists | `gateway install` copies some provider keys into `~/.openclaw/gateway.systemd.env`, which would override a rotated Secret. Each boot, keys that Kubernetes also supplies are removed from it. Other keys are kept. |
| Gateway heap | Set `OPENCLAW_SYSTEMD_HEAP_MIB` (>= 8192) to pin `--max-old-space-size` at install. It works by giving the installer a memory limit of 4x that value, so the node needs at least that much RAM; otherwise OpenClaw sizes from RAM and the entrypoint logs a warning. Unset, OpenClaw sizes it from the pod memory limit. |
| Logs | The journal is streamed to the container's stdout, so `kubectl logs` shows systemd, bootstrap, and gateway output, including shutdown. |
| Termination | `STOPSIGNAL SIGRTMIN+3` (systemd's halt signal; SIGTERM would make it re-execute). An idle gateway stops in well under a second. A gateway with work in flight may drain for up to 330s (OpenClaw's fixed service timeout), so set `terminationGracePeriodSeconds` to 360. |
| `/tmp` | Not emptied at boot, since in a pod it is usually shared with other containers. |
| Zombies | systemd reaps them; no tini needed. |

## Pod requirements

- App container: `runAsUser: 0`, `runAsNonRoot: false`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, and add `SYS_ADMIN CHOWN DAC_OVERRIDE FOWNER KILL SETGID SETPCAP SETUID`. `SYS_ADMIN` is only used by the entrypoint to remount the cgroup tree writable, and is dropped before systemd starts. The `RuntimeDefault` seccomp profile works.
- The state volume mounted at `/home/openclaw`.
- `/run` and `/run/lock` as `emptyDir` with `medium: Memory`.
- `terminationGracePeriodSeconds: 360`.
- Probes: `openclaw-probe-live` for liveness (fails only if systemd or the user manager is unhealthy, or the gateway crashed past its restart limit; an intentionally stopped gateway passes, including one whose stop ended `failed`; see below), and an exec startup probe (every 5s, 240 failures, about 20 minutes) that passes if `~/.openclaw/MAINTENANCE` is a file younger than 240 minutes (`find -mmin -240`), and otherwise if the pod's gateway proxy answers `/healthz`. The image's `openclaw-probe-ready` (gateway answering on `127.0.0.1:18789`) is not what that probe runs. The startup probe must pass for as long as a repair can legitimately run (up to the 3 hour hard cap, see [Maintenance window](#maintenance-window)): a probe that gives up first kills the pod mid-repair, before the repaired version is recorded, so every boot would repeat it. The repair lifecycle creates and refreshes the marker itself. Liveness is unaffected while a repair runs, because the gateway unit is `activating`, not `failed`.

**Security note:** `kubectl exec` processes, including exec probes, get the container's capabilities rather than PID 1's reduced set, so an exec session runs as root with `SYS_ADMIN`. Restrict who can exec into the pod accordingly.

## Operating

The command is just `openclaw`, from `kubectl exec` or anywhere else in the container:

```sh
kubectl exec -it <pod> -c app -- openclaw gateway stop
kubectl exec -it <pod> -c app -- openclaw doctor --fix
kubectl exec -it <pod> -c app -- openclaw gateway start
```

`kubectl exec` lands as root, which can't reach uid 1000's systemd user bus and would otherwise create root-owned files under the account's home. `/usr/local/bin/openclaw` is a small wrapper: as root it hands off to `oc`, which runs the CLI as uid 1000 with the right environment; as any other user it runs the image CLI directly, unchanged. The entrypoint also shadows the same handoff onto `~/.local/bin/openclaw` (an init container's copy that would otherwise win on PATH for a root shell), without touching that file on the state volume. `oc` is still there as an implementation detail, and works the same as a direct alias if you prefer to type it.

Extra system units (for example a helper daemon) can be mounted as files into `/etc/openclaw-systemd/units/`; each `*.service` there is installed and enabled at boot.

## Upgrades and repair

The upstream image's entrypoint runs `openclaw doctor --fix --non-interactive` before every gateway start; that is how retained state is migrated and drifted official plugins are brought to the new release after an image bump. This image replaces that entrypoint, so it runs the same command from an `ExecStartPre` drop-in instead, but only when needed, because a Doctor pass takes on the order of minutes even with nothing to fix.

The drop-in is `/etc/systemd/user/service.d/10-openclaw-gateway-repair.conf`, the top-level drop-in directory that applies to every user service; its scripts receive the unit name and do nothing for anything but `openclaw-gateway.service`. It cannot be a unit-specific `openclaw-gateway.service.d` drop-in: OpenClaw refuses to install or change its unit (`SERVICE_DEFINITION_SEALED [foreign-owner]`) when such a drop-in belongs to another account, and exempts only top-level `service.d` files as shared.

| Trigger | When | If Doctor fails |
|---|---|---|
| Upgrade | The image's OpenClaw version differs from the last version repaired successfully, or nothing has been repaired yet | Fail closed: the gateway is held stopped (see below) |
| Forced | `~/.openclaw/state/openclaw-systemd/force-repair` exists (consumed once the repair is recorded, see below) | Fail closed |
| Failed start | The previous start never answered `/healthz` | Fail open: start anyway. After two such repairs without a healthy start, stop repairing until the gateway is healthy again |

Every other start, including `openclaw gateway restart`, skips Doctor and costs a few milliseconds. Doctor runs as the state-owning account with `OPENCLAW_SERVICE_REPAIR_POLICY=external`, since systemd owns the gateway's lifecycle here, so it repairs state without stopping, starting or reinstalling the service. Its output is in the container log, prefixed `repair:`.

A gateway that exits non-zero while it shuts down leaves its unit `failed`, which systemd records exactly like a crash. So that `openclaw gateway stop` still opens a maintenance window, an `ExecStop=` hook (`mark-stop-requested`) writes the unit's `InvocationID` to `~/.openclaw/state/openclaw-systemd/stop-requested`. systemd runs `ExecStop=` when the unit is asked to stop (and also after a clean exit on its own, which leaves the unit `inactive`, so the extra marker is harmless); in testing it did not run when the process died on its own with a non-zero status or a signal. `openclaw-probe-live` treats a `failed` gateway as stopped on request only if that file names the unit's current invocation and the unit's `Result` is `exit-code`, `signal`, `core-dump` or `timeout`. The `Result` check matters because a restart refused by the start limit (`start-limit-hit`) leaves the unit `failed` with the old invocation's ID, which still matches the marker while the gateway is down; that and any other result (`dependency`, `resources`, `protocol`) fails the probe. `openclaw gateway start` begins a new invocation, which ends the window; a marker left from an earlier run never excuses a later crash, and nothing needs to clear it. A crash past the restart limit has no marker for its invocation and still fails the probe. The probe takes its state directory from an optional first argument (only the tests pass one), not from the environment.

When a fail-closed repair fails, it writes `~/.openclaw/state/openclaw-systemd/repair-blocked`. While that names the current version, every later start (systemd's automatic restarts, `openclaw gateway start`, a pod restart) fails immediately without running Doctor again, and `openclaw-probe-live` reports the container live, so Kubernetes leaves it up for inspection instead of restart-looping. (`openclaw-probe-live` honors the block only while it names the image's current version.) `openclaw-probe-ready` fails in that state because the gateway is not answering; a readiness probe that runs `openclaw-probe-live` passes, as it does for an intentionally stopped gateway.

To recover, read the `repair:` lines in the log (Doctor's full output of the last run is also kept in `~/.openclaw/state/openclaw-systemd/doctor.log`) and fix the cause, then retry with the one supported command:

```sh
kubectl exec -it <pod> -c app -- /usr/local/libexec/openclaw-systemd/repair-retry
```

`repair-retry` clears `repair-blocked` and any dead `repair-in-progress` record, removes a stale marker this lifecycle left, arms `force-repair`, resets a start-limited unit and starts the gateway, whose start then runs Doctor once. It refuses while a repair is genuinely still running. Run as root (as `kubectl exec` does), it re-executes itself as uid 1000 for every state and lock operation, so it never leaves root-owned state; only the final gateway start goes through the `openclaw` wrapper. As root it decides that with the absolute `/usr/bin/id` and pins `PATH` (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`) before any command lookup, passing it explicitly across the re-exec, because a `kubectl exec` shell's inherited `PATH` can put a directory the gateway account can write (`~/.local/bin`) first. Its check-and-clear of `repair-in-progress` runs under the same lock as a starting repair's guard write, so the two cannot interleave. Nobody should hand-create `~/.openclaw/MAINTENANCE` or edit a unit's `TimeoutStartSec`. A successful repair removes the block files. To deliberately start without a repair, write the current version (`node -p 'require("/app/package.json").version'`) to `repaired-version` and remove `repair-blocked`. It is the only supported retry: do not touch `force-repair` by hand. A `force-repair` found next to a dead `repair-in-progress` record is consumed by the block (below), so the request is dropped, not honoured.

### Maintenance window

Every forced, upgrade or failed-start repair owns a maintenance window, so that nothing (systemd, the Kubernetes startup probe, a person) needs to be told to be patient:

1. **Before Doctor starts**, `repair-if-needed` does three things in this order: (a) writes `state/repair-in-progress` (the interruption guard: version, mode, reason, owner pid and start time, invocation), atomically; (b) creates `~/.openclaw/MAINTENANCE` atomically (temp file + rename, owned by the account that runs it, uid 1000); (c) only then consumes `force-repair`. A kill at any of those points leaves the guard behind, so the next start sees an interruption. If the guard cannot be written, a forced or upgrade repair does not start. The marker is `key=value` lines: `owner=openclaw-systemd`, `phase`, `pid` and `pidstart` (the owner process and its `/proc` start time, so a reused pid is not mistaken for it), `invocation` (the systemd `InvocationID`), `reason`, `start` and `deadline` (epoch seconds). Every marker mutation (create, refresh, handover, removal, stale reap), in `repair-if-needed`, `mark-healthy` and `repair-retry`, runs under one `flock` on `state/maintenance.lock` and re-checks the whole identity (owner, pid, pidstart, invocation) inside the lock, so a marker another run replaced is left alone. The lock is held only for the mutation, never across Doctor or the readiness wait. Only a hand edit bypasses it.
2. **Doctor runs as a watched child** with its own deadlines, because `TimeoutStartSec` is only a finite backstop: `200min`, above the 3 hour cap plus gateway startup. It is not infinity because the drop-in also governs the user D-Bus daemon and transient units, and it is not extended dynamically (`EXTEND_TIMEOUT_USEC`) because that needs `NotifyAccess=all` on every user service. The wrapper kills Doctor (its whole process group) and fails closed if it writes **no output for 30 minutes** (a hang, not work) or runs past the **3 hour hard cap** (the 2026.11.5 upgrade overran 15 minutes, an operator settled on 1 hour by hand; 3 hours leaves a wide margin and stays inside the probe's 240 minute window). Every 60 seconds the marker is re-touched, so the probe keeps passing.
3. **On success** the marker becomes `phase=awaiting-ready` (no owner process; bounded by its invocation and a 30 minute deadline) and `mark-healthy` removes it once `127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}/readyz` returns 200, not merely `/healthz`. It removes only a marker this lifecycle owns for this invocation: a hand-made marker (no owner fields) or another run's is logged and left. If readiness never comes, the expired marker is released at the end of the wait. The guard is kept until the handover is done: right after Doctor exits 0 it is rewritten with `doctor_ok=1`, then the stamp, start-pending and marker handover follow, and the guard is removed last. A start that finds a dead guard with `doctor_ok=1` finishes those steps without Doctor and without picking a failed-start repair. Recovery runs under one lock: it re-reads the guard, finishes the stamp and `start-pending`, puts this start's `awaiting-ready` marker in place (creating one, or replacing only the interrupted run's own marker by its pid/pidstart/invocation or invocation/start; an operator's, a live run's or an already-replaced marker is left alone), and removes the guard last. A second start that read the same dead guard arrives late, finds it gone and changes nothing, so the startup probe stays covered until `/readyz` and `mark-healthy` removes the marker. The one gap is the instant between Doctor exiting and the `doctor_ok` write, which fails closed (blocked) in every mode.
4. **On failure** the marker and record are removed, `repair-blocked` is written and the start fails closed, as above.

States and files (`state/` is `~/.openclaw/state/openclaw-systemd`): `force-repair` (a request) becomes `repair-in-progress` (running) becomes nothing (repaired; `repaired-version` updated) or `repair-blocked` (failed, killed or interrupted). Stale markers are never trusted: at each start, a marker this lifecycle owns whose owner process is gone, whose `awaiting-ready` invocation differs from a different, non-empty current one (an empty ID on either side proves nothing, so `repair-retry`, which runs outside systemd, never reaps a live handed-over marker), or that is past its `deadline` is removed and logged. Interruption: if a start finds `repair-in-progress` whose owner is gone (SIGKILL, OOM, pod restart, node drain), it does **not** run Doctor again. Every mode (forced, upgrade and failed-start) writes `repair-blocked` and fails, so systemd's automatic restart cannot start a second full Doctor; run `repair-retry`. When a start finds a stale `repair-in-progress` for a forced or upgrade repair, it writes `repair-blocked` (temp file + rename) **before** removing the record, and also drops any leftover `force-repair`; if the block cannot be written the record stays and the start fails. A kill in between is therefore safe: the record is found again and the same block is rewritten.

What the Kubernetes startup probe sees: only the marker's modification time. It cannot see the `deadline` or whether the owner is alive, so a dead run's marker keeps a *starting* pod passing for up to 240 minutes from its last touch; the lifecycle removes such a marker at the next start, and `repair-retry` removes it too.

## Tests

CI builds the image, runs `tests/static-checks.sh` inside it, and boots it with systemd as PID 1 (`tests/boot-test.sh`): first-boot install, pinned heap, stop/start with the container staying up, and a clean halt. The static checks cover the repair decision table with Doctor simulated, and `tests/maintenance.test.sh` covers the maintenance window (marker create/remove, the progress deadline, hard cap and heartbeat, stale-owner cleanup, interrupted repairs not looping at every kill point from the guard write to the end of the handover, the marker lock, readiness-gated removal against a stubbed `/readyz`, `repair-retry`); run it locally with `sh tests/maintenance.test.sh`; the boot test runs Doctor for real on first boot and on a simulated failed start, checks that a plain restart skips it, and checks that a failing repair holds the gateway down with the container still live, then recovers through `repair-retry`.

The repair scripts have test-only hooks (simulated Doctor, kill points, shortened deadlines), all named `OPENCLAW_SYSTEMD_TEST_*`. `write-env-file.mjs` never copies that prefix from the pod environment into the user manager, so they cannot be switched on from the pod spec; the tests set them on the process directly, and `boot-test.sh` uses `systemctl --user set-environment`. `repair-retry` takes the state owner's home from its passwd entry, not the environment.
