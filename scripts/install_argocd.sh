#!/bin/bash

# 1. Enable strict error handling
# -e: exit immediately if any command exits with a non-zero status
# -o pipefail: the return value of a pipeline is the status of the last command to exit with a non-zero status
set -eo pipefail

NAMESPACE="argocd"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

echo "------------------------------------------"
echo "1. CREATE ARGOCD NAMESPACE (IF NOT EXISTS)"
# Use dry-run and apply to ensure idempotency (won't fail if the namespace already exists)
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

echo -e "\n------------------------------------------"
echo "2. INSTALL ARGOCD"
kubectl apply -n ${NAMESPACE} --server-side --force-conflicts -f ${ARGOCD_MANIFEST}

echo -e "\n------------------------------------------"
echo "3. WAIT FOR ARGOCD DEPLOYMENTS TO BE READY"
# Instead of hardcoded sleep, dynamically wait until the core deployment is available
echo "Waiting for argocd-server deployment to be available..."
kubectl wait --namespace ${NAMESPACE} \
  --for=condition=available deployment/argocd-server \
  --timeout=300s

echo -e "\n------------------------------------------"
echo "4. PATCH ARGOCD SERVICE TO NODEPORT"
kubectl patch svc argocd-server -n ${NAMESPACE} -p '{"spec": {"type": "NodePort"}}'

echo -e "\n------------------------------------------"
echo "5. WAIT FOR INITIAL ADMIN SECRET"
# Wait until Kubernetes automatically generates the admin secret after the API starts
echo "Waiting for admin secret to be created..."
until kubectl -n ${NAMESPACE} get secret argocd-initial-admin-secret &>/dev/null; do
  sleep 2
done

echo -e "\n------------------------------------------"
echo "6. GET ARGOCD ADMIN PASSWORD"
# Safely fetch and decode the password
PASSWORD=$(kubectl -n ${NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo -e "\n------------------------------------------"
echo "7. GET NETWORK PARAMETERS (IPS & NODEPORT)"
# Fetch the InternalIP of the first available Kubernetes node inside the cluster
INTERNAL_NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Fetch all IP addresses, filter out loops, docker, and virtualbox/NAT networks (like 10.0.2.x), then take the first valid one
LOCAL_HOST_IP=$(hostname -I | tr ' ' '\n' | grep -v -E '^(127\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|10\.0\.2\.)' | head -n 1)

# Fetch the specific NodePort mapped to the container's HTTPS port (443)
NODE_PORT=$(kubectl get svc argocd-server -n ${NAMESPACE} -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')

echo "=========================================="
echo "ArgoCD installed successfully!"
echo "Cluster Internal URL: https://${INTERNAL_NODE_IP}:${NODE_PORT}"
echo "Host Local URL:       https://${LOCAL_HOST_IP}:${NODE_PORT}"
echo "Admin password:       ${PASSWORD}"
echo "=========================================="