#!/usr/bin/env bash
# One-command local setup: kind cluster "demo" + ingress-nginx + image build/load + Helm release "demo".
# Safe to re-run: every step checks current state before acting.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER_NAME="${CLUSTER_NAME:-demo}"
NAMESPACE="${NAMESPACE:-demo}"
RELEASE="${RELEASE:-demo}"
IMAGE_REPO="${IMAGE_REPO:-demo-service}"
IMAGE_TAG="${IMAGE_TAG:-1.0.0}"
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.12.1}"
INGRESS_NGINX_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

for tool in docker kind kubectl helm; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but not found in PATH"
done
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable — start Docker and retry"

# ---------------------------------------------------------------------------
log "kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "cluster already exists — reusing"
else
  # Port mappings let the ingress controller be reached on localhost:${HTTP_PORT}.
  kind create cluster --name "$CLUSTER_NAME" --wait 120s --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: ${HTTP_PORT}
        protocol: TCP
      - containerPort: 443
        hostPort: ${HTTPS_PORT}
        protocol: TCP
EOF
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=120s >/dev/null

# ---------------------------------------------------------------------------
log "ingress-nginx (${INGRESS_NGINX_VERSION})"
if kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1; then
  echo "controller already installed — skipping apply"
else
  kubectl apply -f "$INGRESS_NGINX_MANIFEST"
fi
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
# The admission webhook must answer before Helm can create an Ingress.
kubectl -n ingress-nginx wait --for=condition=Ready pod \
  -l app.kubernetes.io/component=controller --timeout=180s >/dev/null

# ---------------------------------------------------------------------------
log "build image ${IMAGE_REPO}:${IMAGE_TAG} and load into kind"
docker build -t "${IMAGE_REPO}:${IMAGE_TAG}" ./service
kind load docker-image "${IMAGE_REPO}:${IMAGE_TAG}" --name "$CLUSTER_NAME"

# ---------------------------------------------------------------------------
log "helm release '${RELEASE}' in namespace '${NAMESPACE}'"
HELM_EXTRA_ARGS=()
# Helm 4 uses server-side apply; an out-of-band `kubectl patch` on the ConfigMap would
# otherwise make the upgrade fail with a field-manager conflict. Chart values must win.
if helm upgrade --help 2>/dev/null | grep -q -- '--force-conflicts'; then
  HELM_EXTRA_ARGS+=(--force-conflicts)
fi
helm upgrade --install "$RELEASE" ./chart \
  --namespace "$NAMESPACE" --create-namespace \
  --set image.repository="$IMAGE_REPO" \
  --set image.tag="$IMAGE_TAG" \
  ${HELM_EXTRA_ARGS[@]+"${HELM_EXTRA_ARGS[@]}"} \
  --wait --timeout 180s

# ---------------------------------------------------------------------------
log "verification"
kubectl -n "$NAMESPACE" get deploy,pods,svc,ingress
echo
# nginx needs a moment to reload after a new Ingress object appears.
reached=false
for _ in $(seq 1 15); do
  if body=$(curl -sf --max-time 5 -H 'Host: demo.local' "http://localhost:${HTTP_PORT}/"); then
    reached=true; break
  fi
  sleep 2
done
if [ "$reached" = true ]; then
  echo "$body"
  echo "Service reachable through the Ingress."
else
  warn "Ingress not answering on localhost:${HTTP_PORT} yet. Retry manually:"
  warn "  curl -H 'Host: demo.local' http://localhost:${HTTP_PORT}/"
fi

cat <<EOF

Done. Useful commands:
  kubectl -n ${NAMESPACE} get pods
  curl -H 'Host: demo.local' http://localhost:${HTTP_PORT}/
  curl -H 'Host: demo.local' http://localhost:${HTTP_PORT}/healthz
EOF
