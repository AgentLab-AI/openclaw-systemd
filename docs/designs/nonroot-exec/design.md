# Non-root default exec with root systemd: disposable spike

Date: 2026-11-17 UTC. Production deployment unchanged.

## Question

Can the existing systemd image retain root systemd PID1, while ordinary Kubernetes exec processes and gateway tools run as UID1000?

## Real execution result

YES for the isolated prototype on node02, using image ghcr.io/clawd-ops/openclaw-systemd:2026.10.10-bcdd55a.

A native root-owned mode4755 helper was installed by a root init container into an otherwise unwritable shared emptyDir. The main container was configured runAsUser1000/runAsGroup1000 with allowPrivilegeEscalation:true. Helper accepted only PID1, realUID1000 and effectiveUID0, established root IDs and execed the image's fixed original entrypoint. It did not accept arbitrary command arguments.

Observed:
- PID1: systemd, real/effective/saved/fs UID0; CapEff/CapPrm/CapBnd=0x1eb, NoNewPrivs0.
- Direct kubectl exec id: uid1000(node), gid1000(node).
- Direct kubectl exec python: CapEff0, CapPrm0, CapAmb0; bounding0x2001eb.
- Direct os.setuid(0): EPERM.
- File created by direct exec on scratch home: UID1000/GID1000.
- Attempt to invoke launcher from an ordinary exec: refused, exit77, because PID was not1. It was momentarily EUID0 inside the helper before the guard rejected it; this is why minimal audited code matters.
- Image first-boot bootstrap installed the user gateway service and ran Doctor.
- Disposable gateway /readyz on default port18789: HTTP200.
- As UID1000, systemctl --user stop openclaw-gateway.service: succeeded; ActiveStateinactive/MainPID0; container remained up and exec remained UID1000.
- As UID1000, systemctl --user start openclaw-gateway.service: succeeded; subsequent /readyz HTTP200.

No production home/PVC, provider credentials, real gateway token, systemd unit mounts, or service-account token was attached. The spike used emptyDir volumes, a dummy local token, finite900s deadline and explicit CPU/memory limits. Normal agent/model work was not tested.

## Current production facts

Production app container is configured UID0 and allowPrivilegeEscalationfalse. Direct exec is UID0; runtime NoNewPrivs1. PID1 has dropped SYS_ADMIN, but separately injected exec retains SYS_ADMIN in its capability set. Thus PID1 dropping its own capabilities does not constrain later Kubernetes exec.

The image's oc/openclaw wrappers protect OpenClaw CLI invocation only. They do not protect bare bash/python/git/mkdir or other direct commands.

## Limits / production requirements

This is a feasibility proof, NOT a production-ready security design.
- Setuid bootstrap requires effective NoNewPrivs0 and executable suid-capable storage. It cannot elevate under production's current NNP1.
- Shipping launcher should be image-owned, not a writable persistent-volume file. Do not mark a shell script or systemd itself setuid.
- Prototype retained caller environment because existing entrypoint needs Kubernetes values. A production helper must sanitize loader/shell variables before any root shell/utility runs, pin paths, cwd, descriptors and ID/group handling, and audit all root-consumed writable inputs. The existing entrypoint is not established safe for this new trust model.
- Root boot services must not execute scripts/config controlled by node. Current units and writable-root-filesystem assumptions need review.
- Gateway and helper children should explicitly have empty permitted/effective/ambient capabilities and NoNewPrivilegesyes where compatible. Test whether setting NNP on user@1000 service preserves PAM/DBus/bootstrap behavior.
- Routine gateway stop/start already works through its user manager as node; no sudo is needed for that.
- Root administrative access is a SEPARATE design. A PID1-only launcher deliberately provides none. Do not substitute NOPASSWD ALL and call it a security boundary. An explicit helper can be an accident-prevention tool, but all agents sharing UID1000 can invoke it unless separate authorization is provided.
- Test image and chart changes together: set final image USERnode and remove app UID0 override; node-friendly oc wrapper, probes, HOME/XDG_RUNTIME_DIR/user bus; ensure explicit Docker root escape does not become part of Kubernetes exec expectations.
- systemd --user as PID1 is not a drop-in alternative; upstream rejects user mode as PID1.

## Explicit root maintenance (requested design; NOT implemented by this spike)

The finished design must provide a recovery route for a human to delete or repair root-owned files. Non-root defaults without recovery are insufficient.

Proposed UX:

```sh
# Ordinary work: UID1000
kubectl exec -n ai openclaw-0 -c app -- id
# Explicit authenticated administration, if sudo is chosen and configured:
kubectl exec -it -n ai openclaw-0 -c app -- sudo -i
```

These are target behaviors, not installed functionality. Standard kubectl exec does not select a Linux user with `--user` (that flag selects kubeconfig identity).

Options:
- Password/authentication-gated sudo for the operator; do not place the credential in agent-readable env, files, model context, scripts or logs. Use a secret input channel when operating it.
- Narrow fixed-operation privileged helpers for recurring maintenance; avoid arbitrary paths/commands, symlink/path-traversal hazards and agent-writable root unit/env inputs.
- NOPASSWD ALL is an explicit decision to prevent accidents only; any agent sharing UID1000 could deliberately become root. It is not the recommended security boundary.

A tested follow-up should set NoNewPrivileges=yes and clear capabilities on the gateway/user workload subtree, while a separately injected administrative exec session remains eligible for authenticated sudo. Per-service NNP is inherited by internal agents, blocking sudo there; it does not automatically apply to fresh runtime exec processes. Verify service-level policy compatibility with user-manager/PAM, OpenClaw repair hooks, helpers, Codex and CLI subprocesses. Do not promise internal agents can elevate under NNP. Root boot elevation and root maintenance elevation are separate interfaces.

## Integration / acceptance criteria

1. Image defaults USERnode; Kubernetes app runAsUser/runAsGroup explicitly1000 and no UID0 override; direct exec bash/python/git all create UID1000 files.
2. Audited immutable native bootstrap obtains root only at intended PID1, sanitizes root boot environment and reaches systemd UID0. Reject arbitrary args and ordinary exec calls. Test negative case with NNP1.
3. Gateway and internal agent tools run UID1000 with no effective/permitted/ambient capabilities. Verify creating Codex scratch dirs and backing up them as the normal mover UID.
4. Operator root recovery works with explicit authorization; agent workload cannot invoke the same elevation successfully. Audit sudo policy and every privileged command.
5. User gateway stop -> offline Doctor/reindex -> start remains supported; liveness permits intended maintenance while readiness accurately fails. Stop/start and full readiness are mandatory.
6. Preserve envFrom secret handling without making root consume node-writable shell fragments; rotation, no-credential boot, logs, persistent unit reuse and boot-repair gates need regression coverage.
7. Reboot/container restart, shutdown signals and process cleanup, UID/group and capability sets, securityContext/LSM/cgroup requirements, writable/suid mount behavior and snapshot backup all tested on the actual runtime.
8. Build changes belong here; coordinated chart/securityContext changes belong in home-ops through normal review/Flux. Do not merge/deploy during the ongoing10.10->11.5 upgrade.

## Familiar container tools

s6-overlay supervises services and supports running individual services via s6-setuidgid; gosu/su-exec are related privilege-dropping tools. These service-level drops do not by themselves change Kubernetes's stored exec user. Keep root systemd unless replacing it is independently desired; the useful concept here is the credential boundary, not wholesale adoption of s6.

Sources inspected: clawd-ops/openclaw-systemd main eb4171a611de835a1f9a6ecaf9bfe1bda5297df8 (Dockerfile, entrypoint, bootstrap, existing boot tests); upstream just-containers/s6-overlay README at main3420e2ecf14e5532d2ae7b73c02349a847449148. Parallel primary-source review examined containerd exec's stored process spec reuse, Linux execve/no_new_privs, and systemd user-manager startup rules.

Prototype files: pid1-root-spike.c, compiled pid1-root-spike, spike-pod.json in this directory. These are quarantined research artifacts and not committed or deployed to production.
