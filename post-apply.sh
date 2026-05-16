#!/bin/bash
# post-apply.sh — wire the ELB address into api-gateway after kubectl apply -k eks/
# Run once after every fresh cluster deploy:
#   bash eks/post-apply.sh
set -euo pipefail

ELB=$(kubectl get ingress taskmanager-ingress-api \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "ELB: $ELB"

kubectl patch configmap api-gw-cm \
  --patch "{\"data\":{\"CORS_ORIGIN\":\"http://${ELB}\"}}"

kubectl rollout restart deployment/api-gateway
kubectl rollout status deployment/api-gateway --timeout=90s

echo "Done — CORS_ORIGIN set to http://${ELB}"
