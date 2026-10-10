# Enterprise Bot DevOps take-home

| Part | Where | Status |
|---|---|---|
| 1 Service + Dockerfile | [`service/`](service/) | done, verified locally |
| 2 Helm chart | [`chart/`](chart/) | done, verified with `--set` overrides |
| 3 One-command setup | [`setup.sh`](setup.sh) | done, idempotent (run 5× on this machine) |
| 4 Debug lab | [`lab/`](lab/) | 7 defects fixed; 1 remaining defect isolated to the image, not fixable from the chart — see [`lab/FINDINGS.md`](lab/FINDINGS.md) |
| 5 Written question | [`ANSWERS.md`](ANSWERS.md) | done |
| Bonus CI | [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | helm lint, docker build, Trivy (fails on HIGH/CRITICAL) |

## Run

Prerequisites: Docker running, `kind`, `kubectl`, `helm` (3 or 4) in `PATH`. Port 80/443 free on localhost.

```bash
./setup.sh          # create/reuse kind cluster "demo", ingress-nginx, build+load image, helm release demo/demo
./setup.sh          # second run is a no-op upgrade and must also exit 0
```

What it does, in order: tool/daemon checks → kind cluster `demo` (pinned `kindest/node:v1.32.5`, ports 80/443 mapped to the host) → ingress-nginx `controller-v1.12.1` + wait for rollout and admission webhook → `docker build service/` → `kind load docker-image` → `helm upgrade --install demo ./chart -n demo --create-namespace --wait`. Every step checks state before acting. Override via env: `CLUSTER_NAME`, `NAMESPACE`, `RELEASE`, `IMAGE_TAG`, `HTTP_PORT`, `KIND_NODE_IMAGE`, `INGRESS_NGINX_VERSION`.

## Verify

```bash
kubectl -n demo get deploy,pods,svc,ingress
kubectl -n demo rollout status deploy/demo-demo-service

# through the Ingress (host header, no /etc/hosts change needed)
curl -H 'Host: demo.local' http://localhost/
#   {"app": "demo", "version": "1.0.0", "pod": "demo-demo-service-xxxxx"}
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: demo.local' http://localhost/healthz   # 200

# directly, bypassing the ingress
kubectl -n demo port-forward svc/demo-demo-service 8080:80 &
curl http://localhost:8080/

# chart follows overrides
helm upgrade demo ./chart -n demo --set replicaCount=3 --set config.appName=harness --set config.version=7.7.7 --wait
curl -H 'Host: demo.local' http://localhost/        # app=harness version=7.7.7, pods rolled by checksum annotation
helm template demo ./chart --set replicaCount=3 --set ingress.host=other.local | grep -E 'replicas:|host:'
```

Changing `APP_NAME`/`VERSION` **directly on the ConfigMap** (`kubectl patch cm demo-demo-service ...`) is picked up only after the pods restart — see "Skipped" below:

```bash
kubectl -n demo patch cm demo-demo-service -p '{"data":{"APP_NAME":"patched","VERSION":"2.0.0"}}'
kubectl -n demo rollout restart deploy/demo-demo-service && kubectl -n demo rollout status deploy/demo-demo-service
curl -H 'Host: demo.local' http://localhost/        # app=patched version=2.0.0
```

Part 4:

```bash
cd lab && ./scenario.sh up && ./scenario.sh up && ./scenario.sh verify
```
(`up` twice: `kubectl apply -f cluster-state/` applies `limits.yaml` alphabetically before `namespace.yaml` exists, so the LimitRange is only created on the second pass. Not mine to fix.)

## Resource requests and limits — and why

```yaml
requests: { cpu: 50m,  memory: 64Mi }
limits:   { cpu: 200m, memory: 128Mi }
```

Measured, not guessed: the service is a stdlib Python HTTP server; idle RSS in the container is ~27 MiB (`docker stats`: `27.04MiB`, `0.02%` CPU), and a `curl` loop against it stays well under 50 m CPU on this machine. So:

- **memory request 64Mi** ≈ 2.5× idle, headroom for the interpreter plus a burst of concurrent requests (`ThreadingHTTPServer` spawns a thread per connection). **Limit 128Mi** is 2× request; a Python process that reaches it is leaking, and I'd rather it be OOM-killed and restarted than squeeze neighbours.
- **cpu request 50m** keeps two replicas schedulable on a one-node kind cluster alongside ingress-nginx and still gives the scheduler a real number. **Limit 200m** (4× request, Burstable QoS) allows a spike without being throttled hard; this app has no CPU-heavy path, so anything higher is wasted reservation.
- Same numbers were reused for the lab's `metrics` fix, because they sit comfortably inside the namespace `LimitRange` (`max cpu 1 / 512Mi`) and match the other lab services.

In production these would come from a week of `container_memory_working_set_bytes` / `container_cpu_usage_seconds_total` p95 under real traffic, with VPA in recommendation mode; the ratios (request ≈ p95, memory limit ≈ 1.5–2× request, no or generous CPU limit) would stay.

## What I deliberately skipped, and the risk

| Skipped | Risk |
|---|---|
| **Hot-reload of a directly patched ConfigMap.** Env vars from `envFrom` are read at process start; only `helm upgrade` rolls pods (via `checksum/config`). A `kubectl patch` of the ConfigMap is invisible until a restart. | If the grading harness patches the ConfigMap *without* restarting pods, that gate fails. I kept the assignment's env-var design and documented the restart command instead of adding a mounted-file fallback or Reloader; both are small, listed under production changes. |
| **TLS on the Ingress.** Plain HTTP to `demo.local`. | Fine on a laptop; a non-starter anywhere else. Needs cert-manager + an issuer. |
| **NetworkPolicy, PodDisruptionBudget, HPA.** | A node drain can take both replicas down at once; nothing stops lateral traffic in the namespace. |
| **Image is only loaded into kind, not pushed to a registry; tag is a fixed `1.0.0`.** | Not reproducible across machines, and `IfNotPresent` + a reused tag can serve a stale image after a code change. CI builds a digest-tagged image but doesn't push. |
| **Chart has no unit tests (`helm unittest`) or schema (`values.schema.json`).** | `--set replicaCount=abc` is caught by the API server, not by the chart. |
| **Part 4 reporter defect left unfixed** (see FINDINGS). | `./scenario.sh verify` is 7/11 on my cluster, not green. The alternative — a sidecar proxy that shrinks the API response — would make the check pass without fixing the real problem, which the lab rules describe as the habit they don't want. |
| **Didn't test on Helm 3.** | `setup.sh` only passes `--force-conflicts` when the local `helm` advertises it, so Helm 3 should just work, but I only had Helm 4 locally. |

## What I would change for production

- **Image**: push to a registry with an immutable tag (git SHA) and reference by digest; sign (cosign) and verify at admission; keep the non-root/read-only posture, add `seccompProfile` (already `RuntimeDefault` in the chart).
- **Config propagation**: either stakater Reloader, or mount the ConfigMap as a file the app re-reads, so operators patching config doesn't require knowing to restart.
- **Availability**: `replicaCount ≥ 3`, `PodDisruptionBudget minAvailable: 1`, `topologySpreadConstraints` across zones, HPA on CPU/RPS; `startupProbe` if boot time grows.
- **Network**: default-deny `NetworkPolicy`, allow only ingress controller → service; TLS via cert-manager; rate limiting and WAF at the edge.
- **Ingress controller**: ingress-nginx is itself end-of-life — start the Gateway API migration described in `ANSWERS.md` rather than hardening the old controller.
- **Observability**: structured JSON logs, `/metrics` + ServiceMonitor, SLO alerts on 5xx and p99 latency, not on pod restarts.
- **Delivery**: `setup.sh` becomes a GitOps repo (Argo CD / Flux) with per-env values files; CI gates on `helm lint`, `kubeconform`, `helm unittest`, Trivy for image **and** config (`trivy config chart/`), and a kind-based e2e that runs `setup.sh` twice.
- **Resources**: set from observed p95 with VPA recommendations; consider dropping the CPU limit entirely to avoid CFS throttling, keeping only the memory limit.

## How I used AI

Tool: GitHub Copilot (agent mode, Claude) in VS Code, for the whole exercise.

- **Parts 1–3**: it drafted the service, Dockerfile, chart templates and `setup.sh`, and ran the build/lint/render/curl checks. Corrections along the way: the first `setup.sh` failed on a re-run after a `kubectl patch` because Helm 4 uses server-side apply and refused to overwrite fields owned by `kubectl-patch` — fixed by adding `--force-conflicts` only when the helm binary supports it. The ingress curl at the end of `setup.sh` initially fired before nginx had reloaded; it became a retry loop.
- **Part 4**: the agent drove the `kubectl` investigation, I reviewed each step. Everything in `part4-session.log` is real output from my kind cluster, recorded with `script`. It went down one wrong path (recreating the cluster on Kubernetes 1.32 on a Content-Length theory) before isolating the reporter bug with a fake API server; the dead end is left in the log and in FINDINGS on purpose.
- **Parts 5–6 and CI**: drafted by the agent from my notes; I edited the wording and the risk judgements.
- **What I had to correct or reject**: it proposed a sidecar proxy to make the reporter check pass — rejected as a workaround that hides an application bug; it proposed hot-reloading the ConfigMap via a volume mount — deferred and documented as a gap instead of deviating from the env-var spec.

I can explain and modify every file here.
