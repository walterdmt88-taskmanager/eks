#!/usr/bin/env bash
# eks/overlays/local-dev/sync-image.sh — pull the real image the CI/CD pipeline
# just built and pushed to GHCR, and roll it into the persistent app-dev
# namespace on minikube (see Phase 0 in the CI/CD session notes).
#
# Why this exists: deploy-dev/deploy-staging/deploy-prod in pr-merged.yml use an
# EPHEMERAL kind cluster that's deleted right after the job finishes — nothing to
# browse afterward. app-dev on minikube is the only environment that stays up, but
# it only reflects whatever image was last synced into it manually. This script is
# that manual sync step.
#
# Usage:
#   eks/overlays/local-dev/sync-image.sh [image-tag]
#   eks/overlays/local-dev/sync-image.sh 79b9c1ac61b89c01345188246f40c6f5aee85d1b
#
# With no argument, uses the current tip of origin/main (the SHA the CI pipeline
# would have tagged the image with on the last merge).
#
# Prerequisites:
#   - gh CLI authenticated with the read:packages scope
#       (gh auth refresh -h github.com -s read:packages)
#   - minikube running with the app-dev namespace already deployed (Phase 0)
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

PROJECT="proops2026-taskmanager"
SERVICE="user-service"
NAMESPACE="app-dev"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../${SERVICE}" && pwd)"

IMAGE_TAG="${1:-}"
if [[ -z "${IMAGE_TAG}" ]]; then
  echo "=== No tag given — using tip of origin/main in ${REPO_DIR} ==="
  git -C "${REPO_DIR}" fetch origin main --quiet
  IMAGE_TAG="$(git -C "${REPO_DIR}" rev-parse origin/main)"
fi

IMAGE="ghcr.io/${PROJECT}/${SERVICE}:${IMAGE_TAG}"
echo "=== Target image: ${IMAGE} ==="

echo "=== [1/4] docker login ghcr.io (via gh auth token) ==="
gh auth token | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin

echo "=== [2/4] docker pull ==="
docker pull "${IMAGE}"

echo "=== [3/4] minikube image load ==="
minikube image load "${IMAGE}"

echo "=== [4/4] kubectl set image + rollout ==="
kubectl set image "deployment/${SERVICE}" "${SERVICE}=${IMAGE}" -n "${NAMESPACE}"
kubectl patch "deployment/${SERVICE}" -n "${NAMESPACE}" --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]' \
  || true   # no-op if already set — patch fails harmlessly if value is unchanged
kubectl rollout status "deployment/${SERVICE}" -n "${NAMESPACE}" --timeout=120s

echo ""
echo "=== Done — ${SERVICE} in ${NAMESPACE} is now running ${IMAGE} ==="
kubectl get pods -n "${NAMESPACE}" -l "app=${SERVICE}"
