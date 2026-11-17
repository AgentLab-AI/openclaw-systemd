# Disposable proof of concept — not production code

This directory preserves the non-root-exec/root-systemd experiment and is deliberately outside the image build inputs. Do not install the launcher or deploy this manifest as-is.

See `design.md` for observed results, security caveats, proposed authenticated root maintenance and acceptance criteria.

## Reproduce in an authorized disposable environment

The fixture uses the existing 2026.10.10 image to demonstrate the architecture independently of the concurrent 11.5 upgrade. Adjust names, namespace, node selector, image and resource limits to your own environment. Never attach the production PVC or real credentials.

```sh
gcc -static -Os -s -Wall -Wextra -Werror pid1-root-spike.c -o pid1-root-spike
kubectl -n ai create configmap oc-uid-spike-20261117 --from-file=launcher=./pid1-root-spike
kubectl create -f spike-pod.json
kubectl -n ai wait --for=condition=Ready pod/oc-uid-spike-20261117 --timeout=90s
kubectl -n ai exec oc-uid-spike-20261117 -c app -- id
```

Kubernetes Pod Ready in this fixture has no app readiness probe; it does NOT prove the gateway is ready. Wait for actual gateway readiness on its unconfigured/default port18789:

```sh
kubectl -n ai exec oc-uid-spike-20261117 -c app -- curl -fsS http://127.0.0.1:18789/readyz
kubectl -n ai exec oc-uid-spike-20261117 -c app -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user stop openclaw-gateway.service
kubectl -n ai exec oc-uid-spike-20261117 -c app -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user show openclaw-gateway.service -p ActiveState -p MainPID
kubectl -n ai exec oc-uid-spike-20261117 -c app -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user start openclaw-gateway.service
```

Then require /readyz200 again. Inspect actual process UID and capability/NNP fields in /proc/1/status and /proc/self/status; UID alone is insufficient. Attempted `/bootstrap/launcher` under ordinary exec must refuse (exit77), not launch another root command. The fixture's launcher preserves boot environment and is NOT an audited secure setuid boundary. The existing image can carry other setuid programs; audit them separately before interpreting refusal of this one helper as overall privilege isolation.

Cleanup even after failure:

```sh
kubectl -n ai delete pod oc-uid-spike-20261117 --wait=true --timeout=90s
kubectl -n ai delete configmap oc-uid-spike-20261117
```

The actual experiment completed those deletions; no test pod/configmap remains from it. No compiled executable is committed.
