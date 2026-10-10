# ANSWERS

## Q1 — Migrating ~40 Ingress objects from ingress-nginx (EOL) to the Gateway API with no downtime

**Approach: run both data planes side by side, move traffic per host, keep a rollback path at every step.**

1. **Inventory first.** Dump all 40 Ingresses and group them by what they actually use: plain host/path routing, TLS (cert-manager or static secrets), and `nginx.ingress.kubernetes.io/*` annotations (rewrite-target, regex paths, auth, CORS, rate limits, body size, `configuration-snippet`). The annotation list *is* the risk register — everything in it has no 1:1 Gateway equivalent.
2. **Pick the controller** (Envoy Gateway, Cilium, Istio, NGINX Gateway Fabric…) based on which of those features it covers natively; the ones it doesn't cover need an app-side change or a filter CRD before migration, not during.
3. **Install Gateway API CRDs + controller alongside ingress-nginx**, with its own LoadBalancer/IP. Nothing points at it yet; no user impact.
4. **Translate** with `ingress2gateway`, then hand-review every HTTPRoute. One `Gateway` per TLS/wildcard domain; ReferenceGrants for cross-namespace cert Secrets.
5. **Verify without traffic**: resolve the new LB IP with `curl --resolve host:443:NEW_IP`, run per-route smoke tests, compare status codes/headers against the old path. Shadow with a low-weight DNS record or `/etc/hosts` canaries first.
6. **Cut over host by host**, lowest-risk service first: DNS TTL dropped to 60 s a day ahead, flip the record (or move the shared IP), watch 5xx rate and latency, keep the Ingress object in place as the rollback.
7. Only after all hosts are stable for days: remove Ingress objects, then uninstall ingress-nginx, then remove `IngressClass`.

**What I expect to break**

- Annotation-driven behaviour silently gone: rewrites (`rewrite-target` with capture groups ≠ `URLRewrite` filter), regex paths (Gateway `PathPrefix`/`Exact` only; `RegularExpression` is implementation-specific), auth/snippets, custom timeouts and body-size limits.
- TLS: cert-manager must learn the new `Gateway` (gateway-shim / `HTTPRoute` solver), otherwise renewals stop; SNI/default cert behaviour differs.
- Client IP & headers: `X-Forwarded-*`/PROXY protocol defaults differ, so IP allow-lists and audit logs change.
- Apps that keyed on `ingress.class` or read the Ingress status IP (external-dns) need their source updated.
- Observability: dashboards and alerts built on `nginx_ingress_controller_*` metrics go dark until re-pointed.
- Long-lived connections (WebSockets, gRPC streams) drop at cutover — schedule those hosts in a low-traffic window.
