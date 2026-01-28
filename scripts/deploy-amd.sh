#!/bin/bash
set -e

NAMESPACE_SYSTEMS="arc-systems"
NAMESPACE_RUNNERS="arc-runners"
RUNNER_SET="${1:-stateless}"
CLUSTER_NAME="theia-prod"

if [[ ! "$RUNNER_SET" =~ ^(stateless)$ ]]; then
  echo "Error: Invalid runner set '$RUNNER_SET'. Valid: stateless"
  exit 1
fi

CURRENT_CONTEXT=$(kubectl config current-context)
if [[ "$CURRENT_CONTEXT" != "$CLUSTER_NAME" ]]; then
    echo "Warning: Current context is '$CURRENT_CONTEXT', expected '$CLUSTER_NAME'."
    read -p "Proceed? (y/n) " -r confirm
    [[ "$confirm" != "y" ]] && exit 1
fi

echo ""
echo "================================================"
echo "  ARC Runner Deployment (AMD64)"
echo "================================================"
echo "Runner Set: $RUNNER_SET"
echo "Cluster: $CURRENT_CONTEXT"
echo ""

echo "Step 1/7: Deploying Registry Mirrors..."
kubectl apply -f manifests/registry-mirror.yaml
kubectl apply -f manifests/registry-mirror-ghcr.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=registry-mirror -n registry-mirror --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=registry-mirror-ghcr -n registry-mirror --timeout=120s
echo "Registry mirrors ready"
echo ""

echo "Step 2/8: Deploying Verdaccio (npm cache)..."
kubectl apply -f manifests/verdaccio.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=verdaccio -n verdaccio --timeout=120s
echo "Verdaccio ready"
echo ""

echo "Step 3/8: Deploying Apt-Cacher-NG (apt cache)..."
kubectl apply -f manifests/apt-cacher-ng.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=apt-cacher-ng -n apt-cacher-ng --timeout=120s
echo "Apt-Cacher-NG ready"
echo ""

echo "Step 4/8: Creating ARC namespaces..."
kubectl create namespace $NAMESPACE_SYSTEMS --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $NAMESPACE_RUNNERS --dry-run=client -o yaml | kubectl apply -f -
echo "Namespaces ready"
echo ""

echo "Step 5/8: Installing ARC Controller..."
if helm list -n $NAMESPACE_SYSTEMS | grep -q "^arc"; then
  helm upgrade arc --namespace $NAMESPACE_SYSTEMS \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
else
  helm install arc --namespace $NAMESPACE_SYSTEMS --create-namespace \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
fi
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=gha-runner-scale-set-controller \
  -n $NAMESPACE_SYSTEMS --timeout=300s
echo "ARC Controller ready"
echo ""

echo "Step 6/8: Deploying RBAC..."
kubectl apply -f manifests/rbac-runner.yaml
echo "RBAC deployed"
echo ""

echo "Step 7/8: Creating GitHub PAT secret..."
if [ -z "$GITHUB_PAT" ]; then
  if kubectl get secret github-arc-secret -n $NAMESPACE_RUNNERS &>/dev/null; then
    echo "Secret already exists"
  else
    echo "Error: GITHUB_PAT not set and secret doesn't exist"
    exit 1
  fi
else
  kubectl create secret generic github-arc-secret \
    --namespace=$NAMESPACE_RUNNERS \
    --from-literal=github_token="$GITHUB_PAT" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Secret created/updated"
fi
echo ""

echo "Step 8/8: Deploying runner scale set..."
helm upgrade --install arc-runner-set-${RUNNER_SET} \
  --namespace $NAMESPACE_RUNNERS \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  -f manifests/values-runner-set-${RUNNER_SET}.yaml
echo "Runner scale set deployed"
echo ""

echo "================================================"
echo "Verification"
echo "================================================"
echo ""
echo "Registry Mirrors:"
kubectl get pods -n registry-mirror
echo ""
echo "Verdaccio (npm cache):"
kubectl get pods -n verdaccio
echo ""
echo "Apt-Cacher-NG (apt cache):"
kubectl get pods -n apt-cacher-ng
echo ""
echo "ARC Controller:"
kubectl get pods -n $NAMESPACE_SYSTEMS -l app.kubernetes.io/name=gha-runner-scale-set-controller
echo ""
echo "Listeners:"
kubectl get pods -n $NAMESPACE_SYSTEMS | grep listener || echo "No listeners yet (takes ~30s)"
echo ""
echo "Runners:"
kubectl get pods -n $NAMESPACE_RUNNERS 2>/dev/null || echo "No runner pods (expected when idle)"
echo ""
echo "================================================"
echo "Deployment Complete!"
echo "================================================"
