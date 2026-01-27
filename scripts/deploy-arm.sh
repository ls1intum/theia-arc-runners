#!/bin/bash
# ==============================================================================
# ARC Runner Deployment Script (ARM64 / Parma)
# ==============================================================================
# This script deploys GitHub Actions self-hosted runners using Actions Runner
# Controller (ARC) in "Hybrid Kubernetes Mode" (Stateless + DinD).
# It also installs the Spegel P2P cache and k8s-digester.
# ==============================================================================

set -e  # Exit on error

# ========================================
# Configuration
# ========================================
NAMESPACE_SYSTEMS="arc-systems"
NAMESPACE_RUNNERS="arc-runners"
RUNNER_SET="${1:-arm64}"
CLUSTER_NAME="parma"

# Validate runner set parameter
if [[ ! "$RUNNER_SET" =~ ^(arm64)$ ]]; then
  echo "❌ Error: Invalid runner set '$RUNNER_SET'"
  echo "   Valid options: arm64"
  exit 1
fi

# Validate Cluster context
CURRENT_CONTEXT=$(kubectl config current-context)
if [[ "$CURRENT_CONTEXT" != "$CLUSTER_NAME" ]]; then
    echo "⚠️ Warning: Current context is '$CURRENT_CONTEXT', expected '$CLUSTER_NAME'."
    echo "Do you want to proceed? (y/n)"
    read -r confirm
    if [[ "$confirm" != "y" ]]; then
        echo "Aborting."
        exit 1
    fi
fi

echo ""
echo "================================================"
echo "  ARC Runner Deployment (ARM64)"
echo "================================================"
echo "Runner Set: $RUNNER_SET"
echo "Target Cluster: $(kubectl config current-context)"
echo ""

# ========================================
# Step 1: Deploy Caching Layer (Spegel + Digester)
# ========================================
echo "📦 Step 1/7: Deploying Caching Layer..."
# Spegel removed: Single node cluster, no P2P benefit.
# Digester removed: Requires complex TLS setup, blocked pods.

echo "Skipping Caching Layer (using direct internet pulls)"
echo ""

# ========================================
# Step 2: Create Namespaces
# ========================================
echo "📦 Step 2/7: Creating ARC namespaces..."
kubectl create namespace $NAMESPACE_SYSTEMS --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $NAMESPACE_RUNNERS --dry-run=client -o yaml | kubectl apply -f -
echo "✅ Namespaces ready"
echo ""

# ========================================
# Step 3: Install ARC Controller
# ========================================
echo "🎮 Step 3/7: Installing ARC Controller..."

if helm list -n $NAMESPACE_SYSTEMS | grep -q "arc"; then
  echo "ARC controller already installed, upgrading..."
  helm upgrade arc \
    --namespace $NAMESPACE_SYSTEMS \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
else
  echo "Installing ARC controller for the first time..."
  helm install arc \
    --namespace $NAMESPACE_SYSTEMS \
    --create-namespace \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
fi

echo "Waiting for ARC controller to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=gha-runner-scale-set-controller \
  -n $NAMESPACE_SYSTEMS \
  --timeout=300s

echo "✅ ARC Controller ready"
echo ""

# ========================================
# Step 4: Deploy RBAC (Kubernetes Mode)
# ========================================
echo "🛡️ Step 4/7: Deploying RBAC for Kubernetes Mode..."
kubectl apply -f manifests/rbac-runner.yaml
echo "✅ RBAC deployed"
echo ""

# ========================================
# Step 5: Create GitHub PAT Secret
# ========================================
echo "🔑 Step 5/7: Creating GitHub PAT secret..."

if [ -z "$GITHUB_PAT" ]; then
  echo "⚠️  GITHUB_PAT environment variable not set."
  echo "Checking if secret already exists..."
  if kubectl get secret github-arc-secret -n $NAMESPACE_RUNNERS &>/dev/null; then
    echo "✅ Secret 'github-arc-secret' already exists"
  else
    echo "❌ Secret does not exist. Please create it manually or set GITHUB_PAT."
    exit 1
  fi
else
  kubectl create secret generic github-arc-secret \
    --namespace=$NAMESPACE_RUNNERS \
    --from-literal=github_token="$GITHUB_PAT" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "✅ GitHub PAT secret created/updated"
fi
echo ""

# ========================================
# Step 6: Deploy Runner Scale Sets
# ========================================
echo "🏃 Step 6/7: Deploying runner scale sets..."

echo "Deploying single runner scale set: arc-runner-set-${RUNNER_SET}"

helm upgrade --install arc-runner-set-${RUNNER_SET} \
  --namespace $NAMESPACE_RUNNERS \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  -f manifests/values-runner-set-${RUNNER_SET}.yaml

echo "✅ arc-runner-set-${RUNNER_SET} deployment initiated"
echo ""

# ========================================
# Step 7: Verify Deployment
# ========================================
echo "🔍 Step 7/7: Verifying deployment..."
echo ""

echo "Spegel Status:"
echo "--------------"
kubectl get pods -n spegel
echo ""

echo "Digester Status:"
echo "----------------"
kubectl get pods -n digester-system
echo ""

echo "ARC Controller Status:"
echo "----------------------"
kubectl get pods -n $NAMESPACE_SYSTEMS -l app.kubernetes.io/name=gha-runner-scale-set-controller
echo ""

echo "Listener Pods:"
echo "--------------"
kubectl get pods -n $NAMESPACE_SYSTEMS | grep listener || echo "⏳ No listeners yet"
echo ""

echo "Runner Pods (ephemeral):"
echo "------------------------"
kubectl get pods -n $NAMESPACE_RUNNERS 2>/dev/null || echo "No runner pods (expected when idle)"
echo ""

echo "================================================"
echo "✅ Deployment Complete!"
echo "================================================"
