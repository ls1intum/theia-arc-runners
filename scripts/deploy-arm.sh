#!/bin/bash
# ==============================================================================
# ARC Runner Deployment Script
# ==============================================================================
# This script deploys GitHub Actions self-hosted runners using Actions Runner
# Controller (ARC) with persistent Docker layer caching.
#
# Usage:
#   ./scripts/deploy.sh [runner_set]
#
# Parameters:
#   runner_set: Which runner set to deploy ('stateless')
#               Default: 'stateless'
#
# Prerequisites:
#   - kubectl configured for target Kubernetes cluster
#   - Helm 3.14+ installed
#   - GITHUB_PAT environment variable set (or secret created manually)
#
# Examples:
#   ./scripts/deploy.sh stateless      # Deploy stateless runner set
#
# Environment Variables:
#   GITHUB_PAT: GitHub Personal Access Token (admin:org + repo + workflow scopes)
# ==============================================================================

set -e  # Exit on error

# ========================================
# Configuration
# ========================================
NAMESPACE_SYSTEMS="arc-systems" # Same namespace as AMD
NAMESPACE_RUNNERS="arc-runners" # Same namespace as AMD
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
echo "  ARC Runner Deployment"
echo "================================================"
echo "Runner Set: $RUNNER_SET"
echo "Target Cluster: $(kubectl config current-context)"
echo ""

# ========================================
# Step 1: Create Namespaces
# ========================================
echo "📦 Step 1/6: Creating namespaces..."
kubectl create namespace $NAMESPACE_SYSTEMS --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $NAMESPACE_RUNNERS --dry-run=client -o yaml | kubectl apply -f -
echo "✅ Namespaces ready"
echo ""

# ========================================
# Step 2: Install ARC Controller
# ========================================
echo "🎮 Step 2/6: Installing ARC Controller..."

# Check if controller already exists
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
# Step 3: Deploy RBAC (Kubernetes Mode)
# ========================================
echo "🛡️ Step 3/6: Deploying RBAC for Kubernetes Mode..."

# Create namespace if it doesn't exist
kubectl create namespace $NAMESPACE_RUNNERS --dry-run=client -o yaml | kubectl apply -f -

# Deploy RBAC Role and RoleBinding
kubectl apply -f manifests/rbac-runner.yaml

echo "✅ RBAC deployed"
echo ""

# ========================================
# Step 4: Create GitHub PAT Secret
# ========================================
echo "🔑 Step 4/6: Creating GitHub PAT secret..."

if [ -z "$GITHUB_PAT" ]; then
  echo "⚠️  GITHUB_PAT environment variable not set."
  echo ""
  echo "Checking if secret already exists..."
  if kubectl get secret github-arc-secret -n $NAMESPACE_RUNNERS &>/dev/null; then
    echo "✅ Secret 'github-arc-secret' already exists in namespace $NAMESPACE_RUNNERS"
  else
    echo "❌ Secret does not exist. Please create it manually:"
    echo ""
    echo "   kubectl create secret generic github-arc-secret \\"
    echo "     --namespace=$NAMESPACE_RUNNERS \\"
    echo "     --from-literal=github_token='YOUR_GITHUB_PAT'"
    echo ""
    echo "Or set the GITHUB_PAT environment variable and re-run this script:"
    echo "   export GITHUB_PAT='ghp_xxxxxxxxxxxx'"
    echo ""
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
# Step 4: Deploy PVCs
# ========================================
echo "💾 Step 4/6: Deploying Persistent Volume Claims..."
echo "Skipping PVC deployment (Stateless Mode)"
echo ""

# ========================================
# Step 5: Deploy Runner Scale Sets
# ========================================
echo "🏃 Step 5/6: Deploying runner scale sets..."

echo "Deploying single runner scale set: arc-runner-set-${RUNNER_SET}"

helm upgrade --install arc-runner-set-${RUNNER_SET} \
  --namespace $NAMESPACE_RUNNERS \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  -f manifests/values-runner-set-${RUNNER_SET}.yaml

echo "✅ arc-runner-set-${RUNNER_SET} deployment initiated"
echo ""

# ========================================
# Step 6: Verify Deployment
# ========================================
echo "🔍 Step 6/6: Verifying deployment..."
echo ""

echo "ARC Controller Status:"
echo "----------------------"
kubectl get pods -n $NAMESPACE_SYSTEMS -l app.kubernetes.io/name=gha-runner-scale-set-controller
echo ""

echo "Listener Pods (may take 30-60 seconds to appear):"
echo "---------------------------------------------------"
kubectl get pods -n $NAMESPACE_SYSTEMS | grep listener || echo "⏳ No listeners yet (check again in 30 seconds)"
echo ""

echo "PVC Status:"
echo "-----------"
kubectl get pvc -n $NAMESPACE_RUNNERS
echo ""

echo "Runner Pods (ephemeral, appear only when jobs are running):"
echo "-------------------------------------------------------------"
kubectl get pods -n $NAMESPACE_RUNNERS 2>/dev/null || echo "No runner pods (expected when idle)"
echo ""

# ========================================
# Success Summary
# ========================================
echo "================================================"
echo "✅ Deployment Complete!"
echo "================================================"
echo ""
echo "Next steps:"
echo "1. Wait 30-60 seconds for listener pods to register with GitHub"
echo "2. Check GitHub → Settings → Actions → Runners to verify runners appear"
echo "3. Trigger a workflow in artemis-theia-blueprints or theia-cloud"
echo "4. Monitor with: kubectl get pods -n $NAMESPACE_RUNNERS -w"
echo ""
echo "Troubleshooting:"
echo "- Check listener logs: kubectl logs -n $NAMESPACE_SYSTEMS \$(kubectl get pods -n $NAMESPACE_SYSTEMS -o name | grep listener) --tail=50"
echo "- Check runner logs: kubectl logs -n $NAMESPACE_RUNNERS \$(kubectl get pods -n $NAMESPACE_RUNNERS -o name) -c runner"
echo "- Check DinD logs: kubectl logs -n $NAMESPACE_RUNNERS \$(kubectl get pods -n $NAMESPACE_RUNNERS -o name) -c dind"
echo ""
