#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ERRORS=0

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== NovaDeploy Manifest Validation ==="
echo ""

# 1. YAML lint
echo "--- YAML Syntax ---"
if command -v yamllint &>/dev/null; then
  if yamllint -d relaxed "$ROOT_DIR/components" "$ROOT_DIR/platform" "$ROOT_DIR/policies" "$ROOT_DIR/secrets" 2>/dev/null; then
    pass "YAML syntax valid"
  else
    fail "YAML syntax errors found"
  fi
else
  warn "yamllint not installed, skipping"
fi

# 2. Kustomize build validation
echo ""
echo "--- Kustomize Build ---"
if command -v kustomize &>/dev/null || command -v kubectl &>/dev/null; then
  for dir in $(find "$ROOT_DIR/components" -name "kustomization.yaml" -exec dirname {} \;); do
    name=$(echo "$dir" | sed "s|$ROOT_DIR/||")
    if kubectl kustomize "$dir" >/dev/null 2>&1; then
      pass "kustomize build: $name"
    else
      fail "kustomize build: $name"
    fi
  done
  for dir in $(find "$ROOT_DIR/secrets" -name "kustomization.yaml" -exec dirname {} \;); do
    name=$(echo "$dir" | sed "s|$ROOT_DIR/||")
    if kubectl kustomize "$dir" >/dev/null 2>&1; then
      pass "kustomize build: $name"
    else
      fail "kustomize build: $name"
    fi
  done
  for dir in $(find "$ROOT_DIR/policies" -name "kustomization.yaml" -exec dirname {} \;); do
    name=$(echo "$dir" | sed "s|$ROOT_DIR/||")
    if kubectl kustomize "$dir" >/dev/null 2>&1; then
      pass "kustomize build: $name"
    else
      fail "kustomize build: $name"
    fi
  done
else
  warn "kubectl/kustomize not installed, skipping"
fi

# 3. Kubeconform — validate against K8s schemas
echo ""
echo "--- Kubernetes Schema Validation ---"
if command -v kubeconform &>/dev/null; then
  find "$ROOT_DIR/components" "$ROOT_DIR/secrets" -name "*.yaml" ! -name "kustomization.yaml" | while read -r f; do
    name=$(echo "$f" | sed "s|$ROOT_DIR/||")
    if kubeconform -strict -ignore-missing-schemas -summary "$f" 2>/dev/null; then
      pass "schema: $name"
    else
      fail "schema: $name"
    fi
  done
else
  warn "kubeconform not installed, skipping (install: go install github.com/yannh/kubeconform/cmd/kubeconform@latest)"
fi

# 4. Check for secrets in repo
echo ""
echo "--- Secret Leak Detection ---"
LEAKED=$(grep -rn --include="*.yaml" --include="*.yml" -E '(password|secret|token|key)\s*[:=]\s*["\x27]?[A-Za-z0-9+/=]{16,}' \
  "$ROOT_DIR/components" "$ROOT_DIR/platform" "$ROOT_DIR/secrets" 2>/dev/null \
  | grep -v "secretKeyRef" | grep -v "SecretStore" | grep -v "ExternalSecret" \
  | grep -v "secretStoreRef" | grep -v "vault-token" | grep -v "argocd-initial-admin-secret" \
  | grep -v "remoteRef" | grep -v "secretKey:" | grep -v "property:" \
  | grep -v "key:" \
  || true)
if [ -z "$LEAKED" ]; then
  pass "No hardcoded secrets detected"
else
  fail "Possible hardcoded secrets:"
  echo "$LEAKED"
fi

# 5. Check for :latest tags
echo ""
echo "--- Image Tag Check ---"
LATEST=$(grep -rn --include="*.yaml" 'image:.*:latest' "$ROOT_DIR/components" 2>/dev/null || true)
# Match images without any colon (no tag at all), e.g. "image: nginx"
NO_TAG=$(grep -rn --include="*.yaml" -E 'image:\s+[a-z][a-z0-9./_-]+\s*$' "$ROOT_DIR/components" 2>/dev/null | grep -v ':' | head -0 || true)
# Actually: check for images that have no colon after the image name
NO_TAG=$(grep -rn --include="*.yaml" -P 'image:\s+(?!.*:)[a-z]' "$ROOT_DIR/components" 2>/dev/null || true)
if [ -z "$LATEST" ] && [ -z "$NO_TAG" ]; then
  pass "No :latest or untagged images"
else
  [ -n "$LATEST" ] && fail "Images using :latest:" && echo "$LATEST"
  [ -n "$NO_TAG" ] && fail "Images without tags:" && echo "$NO_TAG"
fi

# 6. Check for resource limits
echo ""
echo "--- Resource Limits Check ---"
MISSING_RESOURCES=$(find "$ROOT_DIR/components" -name "*.yaml" ! -name "kustomization.yaml" -exec grep -l "kind: Deployment" {} \; | while read -r f; do
  if ! grep -q "resources:" "$f"; then
    echo "$f"
  fi
done)
if [ -z "$MISSING_RESOURCES" ]; then
  pass "All deployments have resource definitions"
else
  fail "Deployments missing resources:" && echo "$MISSING_RESOURCES"
fi

# Summary
echo ""
echo "=== Validation Complete ==="
if [ "$ERRORS" -gt 0 ]; then
  fail "$ERRORS check(s) failed"
  exit 1
else
  pass "All checks passed"
fi
