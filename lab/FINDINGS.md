# Findings — Part 4 debug lab

Session recording: `part4-session.log` (recorded with `script -aq`, one block per
command; everything below is pasted from it). Cluster: kind `demo`, Helm v4.3.0.
Started on `kindest/node` v1.37.0; the cluster was recreated on v1.32.5 half-way
through while chasing a wrong hypothesis for the reporter (see "Unresolved").

Note on `scenario.sh up`: `kubectl apply -f cluster-state/` applies `limits.yaml`
before `namespace.yaml` (alphabetical), so on a fresh cluster the first `up` fails to
create the LimitRange (`namespaces "debug-lab" not found`). I ran `up` twice. This
matters because it *masks defect 5* on the first pass (metrics pod gets created).

---

## Defect 1 — migrate Job has an invalid `restartPolicy`

**Symptom**

```
$ ./scenario.sh up
Release "debug-lab" does not exist. Installing it now.
Error: server-side apply failed for object debug-lab/migrate batch/v1, Kind=Job:
 Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value:
 valid values: "OnFailure", "Never"
$ ./scenario.sh verify
  FAIL  migrate Job has not completed (does it exist? did the chart even install cleanly?)
```

**Cause** `templates/migrate-job.yaml` sets `restartPolicy: Always`, which is only
valid for Deployments/ReplicaSets. The API server rejects the Job, Helm reports the
release as failed, and the Job never exists.

**Fix** `restartPolicy: OnFailure` (so a failed migration retries up to
`backoffLimit`, rather than `Never` which would leave failed pods around).

**How I found it** The helm error in `up` says exactly which field. `kubectl -n
debug-lab get all` confirmed there was no Job object at all.

---

## Defect 2 — `runAsNonRoot: true` with a non-numeric image user

**Symptom** Every Deployment pod stuck in `CreateContainerConfigError`:

```
$ kubectl -n debug-lab describe pod -l app=backend | sed -n "/^Events/,$p"
  Warning  Failed  6s (x3 over 19s)  kubelet  Error: container has runAsNonRoot and
  image has non-numeric user (nonroot), cannot verify user is non-root
```

**Cause** The image's `USER` is the *name* `nonroot`. The kubelet cannot resolve a
name to a UID at admission time, so with `runAsNonRoot: true` and no `runAsUser` it
refuses to start the container (it would otherwise have to trust the image).

**Fix** Added `common.runAsUser: 65532` in values and `runAsUser: {{ .Values.common.runAsUser }}`
to every container securityContext (6 templates). I kept `runAsNonRoot: true`
rather than removing it — the guardrail is correct, it just needed a verifiable UID.

**How I found it** `describe pod` events. To get the UID without a shell in the
image I pulled it locally and read `/etc/passwd` out of the layer:

```
$ docker image inspect docker.io/ebinterview/eb-debug-app:1.0.1 --format 'User={{.Config.User}} ... ExposedPorts={{.Config.ExposedPorts}}'
User=nonroot Entrypoint=[/eb-debug-app] ... ExposedPorts=map[8081/tcp:{}]
$ cid=$(docker create --platform linux/amd64 docker.io/ebinterview/eb-debug-app:1.0.1) && docker cp "$cid":/etc/passwd - | tar -xO | grep nonroot
nonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin
```

(`ExposedPorts=8081` was the first hint for defect 3.)

---

## Defect 3 — the app listens on 8081, the chart assumes 8080

**Symptom** After defect 2, pods `Running` but never `Ready`:

```
$ kubectl -n debug-lab logs deploy/backend --tail=10
... eb-debug-app 2.0.0 starting: mode=api pod=backend-794c558bfb-gfqzp listening on :8081
    (image default is 8081; set PORT to override)
$ kubectl -n debug-lab describe pod -l app=backend | grep -E "Readiness|Warning" | tail -5
  Warning  Unhealthy  4s (x6 over 29s)  kubelet  Readiness probe failed:
  Get "http://10.244.0.22:8080/healthz": dial tcp 10.244.0.22:8080: connect: connection refused
```

**Cause** `common.port: 8080` drives `containerPort`, the readiness probe and every
Service `targetPort`, but the binary defaults to 8081.

**Fix** `common.port: 8081`. One value, every template follows; Service *public*
ports (backend 8080, gateway 80, reporter 8080) are untouched so `verify`'s URLs
still work. Setting `PORT=8080` in every workload's env would also work but is
five edits instead of one.

**How I found it** Container log says it plainly; the probe failure in `describe`
confirms the direction (probe hits 8080, nothing listens there). Verified the
Service wiring afterwards: `kubectl get endpoints backend` → `10.244.0.27:8081`.

---

## Defect 4 — worker needs a writable cache dir on a read-only root fs

**Symptom**

```
$ kubectl -n debug-lab get pods
worker-85c774d568-2kzb2  0/1  CrashLoopBackOff  2 (11s ago)
$ kubectl -n debug-lab logs deploy/worker --tail=20
FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system
 — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

**Cause** `readOnlyRootFilesystem: true` (correct hardening) but no volume where the
worker writes.

**Fix** `emptyDir` mounted at `/var/cache/app` (path in `worker.cacheDir`). I kept
the root filesystem read-only instead of flipping the flag — the message offers
both options and the volume is the one that keeps the security posture.

**How I found it** CrashLoopBackOff → `logs` (previous container). Nothing else needed.

---

## Defect 5 — metrics requests more CPU than the namespace LimitRange allows

**Symptom** No metrics pod at all after the rollout; the ReplicaSet shows why:

```
$ kubectl -n debug-lab describe rs -l app=metrics | sed -n "/^Events/,$p"
  Warning  FailedCreate  34s  replicaset-controller  Error creating: pods
  "metrics-6c57877dc7-mcdl4" is forbidden: maximum cpu usage per Container is 1, but limit is 4
```

**Cause** `metrics.resources` asks for `cpu: 2` / limit `cpu: 4` (very likely a
typo for `200m`/`400m`); `cluster-state/limits.yaml` caps containers at `cpu: 1`.
Admission rejects the pod, so there is nothing to `describe` at pod level — the
evidence is on the ReplicaSet. On my first `up` the LimitRange did not exist (see
note at the top), so this defect was invisible until the second `up`.

**Fix** Aligned metrics with the other services: `50m`/`64Mi` requests,
`200m`/`128Mi` limits. The LimitRange is environment and must not be touched.

**How I found it** `get pods` showed no metrics pod while the Deployment wanted 1;
`describe rs` events.

---

## Defect 6 — gateway points at the backend in the wrong namespace

**Symptom** Gateway `Running` but readiness returns 503. Port-forwarded to the pod:

```
$ curl -s -i http://localhost:18081/status
HTTP/1.1 503 Service Unavailable
{"app":"gateway","backend":"error: GET http://backend.default.svc:8080/healthz: ...
 dial tcp: lookup backend.default.svc on 10.96.0.10:53: no such host",
 "backend_url":"http://backend.default.svc:8080", ...}
```

**Cause** `gateway.env.BACKEND_URL: http://backend.default.svc:8080` — the lab is
in `debug-lab`, not `default`.

**Fix** `BACKEND_URL: http://backend:8080` (same-namespace short name; it follows the
release namespace wherever the chart is installed).

**How I found it** `describe pod` showed "Readiness probe failed: HTTP probe failed
with statuscode: 503"; `/status` body names the URL and the DNS error.

---

## Defect 7 — RoleBinding grants the Role to the wrong ServiceAccount

**Symptom**

```
$ ./scenario.sh verify
  FAIL  ServiceAccount debug-lab/reporter cannot list pods
$ curl -s -i http://localhost:18082/report      # port-forward to reporter pod
HTTP/1.1 503 Service Unavailable
{"error":"kubernetes API returned HTTP 403: ... pods is forbidden: User
 \"system:serviceaccount:debug-lab:reporter\" cannot list resource \"pods\" ..."}
$ kubectl -n debug-lab get rolebinding reporter-read -o jsonpath='{.subjects}'
[{"kind":"ServiceAccount","name":"default","namespace":"debug-lab"}]
$ kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter
no
$ kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:default
yes
```

**Cause** `templates/rbac.yaml` binds `reporter-read` to the `default` SA while the
Deployment runs as `reporter`.

**Fix** Subject name → `{{ .Values.reporter.serviceAccountName }}` so the binding
can't drift from the Deployment again. The Role's verbs (`get`, `list`) were already
right. After the change: `auth can-i ... --as=...:reporter` → `yes`.

**How I found it** Reporter `/report` body quotes the 403 with the exact subject;
`get rolebinding -o jsonpath` and `auth can-i` as both SAs made it unambiguous.

(That is seven, not six — the assignment said some defects mask others, and I'd
rather over-report than merge two root causes into one entry.)

---

## Unresolved — reporter still not Ready: `parse pod list: unexpected end of JSON input`

**Status: not fixable from the chart; root cause isolated to the image.** Final verify
is 7/11 with the three remaining in-cluster probe checks explained below.

**Symptom** With RBAC fixed, the reporter immediately changed error:

```
$ kubectl -n debug-lab logs -l app=reporter --tail=100 | grep -v healthz
10:05:04 pod list failed: kubernetes API returned HTTP 403: ...
10:05:14 pod list failed: parse pod list: unexpected end of JSON input
$ curl -s -i http://localhost:18082/report
HTTP/1.1 503 Service Unavailable
{"error":"parse pod list: unexpected end of JSON input","status":"unhealthy"}
```

**Diagnostic path (all in the recording), including the dead ends**

1. Replayed the API call as the `reporter` SA from a curl pod: `code=200`, full JSON,
   so RBAC and the API are fine; the problem is on the reader side.
2. Ruled out CPU throttling (`kubectl set resources --limits=cpu=1` on the live
   Deployment — same error), a hidden writable-`/tmp` need (emptyDir on `/tmp` —
   same), and HTTP/2 (`GODEBUG=http2client=0` — same).
3. Pointed throwaway reporter pods at other namespaces (temporary `view` bindings,
   removed afterwards): `default` (0 pods) → `{"pods":0}` **works**; `demo`
   (2 pods, 15 KB) / `ingress-nginx` (3 pods, 24 KB) / `kube-system` (8 pods, 68 KB)
   → all fail. So it is payload size, not RBAC/protocol.
4. **Dead end:** I hypothesised the app needed a `Content-Length` header and that
   Kubernetes ≥1.34's always-on list streaming (`StreamingCollectionEncodingToJSON`,
   GA 1.34) removed it. Recreated the kind cluster on `kindest/node:v1.32.5` —
   identical failure. (Go's HTTP server never sets Content-Length above 2 KiB
   anyway, so the hypothesis was wrong in mechanism.) The node-image pin stayed in
   `setup.sh` for reproducibility, with an honest comment.
5. Isolated the binary from Kubernetes: ran the image with `docker run` against a
   fake HTTPS "API server" (Python, self-signed cert for `kubernetes.default.svc`,
   fake SA token/CA mounted) that returns a synthetic PodList of controlled size.
   The app requests `GET /api/v1/namespaces/<ns>/pods?limit=100` and:

   ```
   PODS=1 PAD=600  -> {"namespace":"debug-lab","pod":"...","pods":1}   server: RESP bytes=807
   PODS=1 PAD=800  -> {"namespace":"debug-lab","pod":"...","pods":1}   server: RESP bytes=1007
   PODS=1 PAD=900  -> {"error":"parse pod list: unexpected end of JSON input"} RESP bytes=1107
   PODS=2 PAD=6000 -> same error, with and without chunked transfer-encoding
   ```

**Cause (evidence-based)** The reporter in `eb-debug-app:1.0.1` reads at most
**1 KiB** of the pod-list body (threshold between 1007 and 1107 bytes; the binary
contains `io.LimitReader`/`maxBytesReader` symbols and a hard-coded URL with
`limit=100`), then `json.Unmarshal`s the truncated buffer. A real Pod object is
~7 KB, so any namespace with ≥1 pod fails on any Kubernetes version. Nothing in
`broken-chart/` can change the API response size, and the image tag may not be
changed.

**What I would try next** (a) ask whether `1.0.1` is the intended tag — a
`1.0.2` with a bigger read buffer or a `PartialObjectMetadataList` Accept header
would fix it; (b) if a chart-side mitigation were acceptable, a tiny sidecar proxy
that lists pods with `Accept: application/json;as=PartialObjectMetadataList;g=meta.k8s.io;v=v1`
and rewrites `kubernetes.default.svc` — but that is a hack around an app bug,
not a fix, so I did not ship it.

**Side-effect on `verify`** The three in-cluster probe checks also show FAIL for
backend and gateway even though both work. `incluster_probe` uses
`kubectl run -i` and the first lines of output are emitted before kubectl attaches:

```
RAW OUTPUT (35 bytes):
PROBE_REPORTER_BODY=
PROBE_DNS=fail
--- same probe with a 2s head start before producing output:
PROBE_BACKEND=ok
PROBE_GATEWAY_BODY={"app":"gateway","backend":"ok","backend_url":"http://backend:8080",...}
```

`scenario.sh` is off-limits, so I left it; on a machine where the reporter's wget
returns quickly the race window is different. The deployments/Job/RBAC checks
(7/11) pass deterministically.
