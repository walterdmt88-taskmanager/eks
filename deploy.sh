#!/usr/bin/env bash
# eks/deploy.sh — Deploy Task Manager to EKS.
#
# All configuration lives in eks/*/kustomization.yaml and eks/manifests/*.
# This script is a thin sequencer: it runs kubectl apply -k in layer order
# with kubectl wait gates between layers. No business logic lives here.
#
# External Helm charts (managed here, not in kustomize):
#   - ingress-nginx  : cluster infra; must be ready before Ingress objects land
#   - bitnami/redis  : cache for api-gateway rate-limiter
#   - metrics-server : required by HPA objects in Layer 03
#
# Usage:
#   bash eks/deploy.sh
#   NAMESPACE=staging bash eks/deploy.sh
#
# Prerequisites:
#   - kubectl connected to the cluster  (aws eks update-kubeconfig …)
#   - helm 3 installed
#   - eks/02-data/secrets.yaml populated (cp eks/02-data/secrets-template.yaml eks/02-data/secrets.yaml, fill values)
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NAMESPACE:-default}"

# ── Helm: ingress-nginx controller ────────────────────────────────────────────
# Managed by Terraform (module.cluster_bootstrap) — skip if already installed.
echo "=== [helm] ingress-nginx controller ==="
if helm status ingress-nginx -n ingress-nginx &>/dev/null; then
  echo "  ingress-nginx already managed by Terraform, skipping."
else
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
  helm repo update ingress-nginx
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --set controller.service.type=LoadBalancer \
    --version 4.10.1 \
    --wait --timeout=5m
fi

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

# ── Layer 01: cluster infra (StorageClass) ────────────────────────────────────
echo "=== [kustomize] Layer 01: StorageClass ==="
kubectl apply -k "${SCRIPT_DIR}/01-infra/"

# ── Layer 02: data (Secrets + ConfigMaps + PostgreSQL StatefulSets) ───────────
echo "=== [kustomize] Layer 02: data layer ==="
kubectl apply -k "${SCRIPT_DIR}/02-data/"

# Wait gates removed — G-18 Phase 6: StatefulSets decommissioned, app uses RDS.
# RDS is always available; no pod-level wait gate needed.

# ── Layer 03: app (Deployments + Ingress + HPA + NetworkPolicies + CronJob) ───
echo "=== [kustomize] Layer 03: app layer ==="
kubectl apply -k "${SCRIPT_DIR}/03-app/"

# ── Helm: Redis ────────────────────────────────────────────────────────────────
# Managed by Terraform (module.cluster_bootstrap) — skip if already installed.
# If installing manually: Bitnami HTTP repo deprecated; use OCI registry directly.
echo "=== [helm] Redis ==="
if helm status my-redis -n "${NS}" &>/dev/null; then
  echo "  my-redis already managed by Terraform, skipping."
else
  helm upgrade --install my-redis \
    oci://registry-1.docker.io/bitnamicharts/redis \
    -f "${SCRIPT_DIR}/redis-values.yaml" \
    --namespace="${NS}" --wait --timeout=5m
fi

# ── metrics-server (required by HPA) ──────────────────────────────────────────
# EKS 1.24+ may pre-install metrics-server; skip if deployment already exists.
echo "=== [kubectl] metrics-server ==="
if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
  echo "  metrics-server already installed, skipping."
else
  kubectl apply -f \
    https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
fi
kubectl wait deployment metrics-server \
  --namespace kube-system --for=condition=available --timeout=120s

# ── Rollout health check ───────────────────────────────────────────────────────
echo "=== rollout status ==="
for svc in user-service task-service api-gateway frontend-service; do
  kubectl rollout status "deployment/${svc}" --namespace="${NS}" --timeout=180s
done

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "=== Deploy complete ==="
kubectl get pods --namespace="${NS}"
echo ""
ELB=$(kubectl get svc ingress-nginx-controller \
  -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
printf "Frontend : http://%s/\n"     "${ELB}"
printf "API      : http://%s/api/\n" "${ELB}"
