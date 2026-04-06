#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CLUSTER_NAME="novadeploy"
ARGOCD_NS="argocd"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Prereq checks ---
for cmd in kind kubectl helm; do
  command -v "$cmd" &>/dev/null || error "$cmd is required but not installed."
done

# --- Kind cluster ---
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  info "Kind cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  info "Creating Kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --config "${SCRIPT_DIR}/kind-config.yaml"
fi

kubectl config use-context "kind-${CLUSTER_NAME}"
info "Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# --- ArgoCD ---
info "Installing ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

helm upgrade --install argocd argo/argo-cd \
  --namespace "${ARGOCD_NS}" --create-namespace \
  --values "${SCRIPT_DIR}/argocd-values.yaml" \
  --wait --timeout 5m

info "Waiting for ArgoCD server..."
kubectl wait --for=condition=Available deployment/argocd-server \
  -n "${ARGOCD_NS}" --timeout=300s

# --- Apply App of Apps ---
info "Applying App of Apps..."
kubectl apply -f "${ROOT_DIR}/platform/app-of-apps.yaml"

# --- Print access info ---
ARGOCD_PASS=$(kubectl -n "${ARGOCD_NS}" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "admin")

echo ""
info "========================================="
info " NovaDeploy Platform Bootstrap Complete"
info "========================================="
info "ArgoCD UI:  https://localhost:443 (port-forward below)"
info "  Username: admin"
info "  Password: ${ARGOCD_PASS}"
echo ""
info "To access ArgoCD UI:"
info "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
info "  Then open: https://localhost:8080"
echo ""
info "To check sync status:"
info "  kubectl get applications -n argocd"
echo ""
