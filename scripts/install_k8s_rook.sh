#!/bin/bash

# 1. Enable strict error handling
# -e: exit immediately if any command exits with a non-zero status
# -o pipefail: catch errors hidden inside pipelines
set -eo pipefail

# Avoid using $USER directly if script might run under sudo/Ansible context
# This safely discovers the real executing user
REAL_USER=$(whoami)
HOME_DIR="/home/${REAL_USER}"

echo "------------------------------------------"
echo "1. CHECK USER AND DIRECTORY ENVIRONMENT"
echo "Running as user: ${REAL_USER}"
echo "Target directory: ${HOME_DIR}/rook"

echo -e "\n------------------------------------------"
echo "2. ROOK GIT CLONE"
cd "${HOME_DIR}"

# Ensure idempotency: remove old directory if it exists, or skip cloning if preferred
if [ -d "rook" ]; then
    echo "Rook directory already exists. Cleaning up before clean clone..."
    rm -rf rook
fi

git clone --single-branch --branch v1.21.0 https://github.com/rook/rook.git

echo -e "\n------------------------------------------"
echo "3. GO TO ROOK EXAMPLES DIRECTORY"
cd "${HOME_DIR}/rook/deploy/examples"

echo -e "\n------------------------------------------"
echo "4. CREATE CRDS, COMMON, AND CSI-OPERATOR"
# Use 'apply' instead of 'create' to support re-running the script without errors
kubectl apply -f crds.yaml -f common.yaml -f csi-operator.yaml

echo -e "\n------------------------------------------"
echo "5. WAIT FOR CRDS TO BE DISCOVERED BY THE API"
# Waiting dynamically for key CRDs to be registered before deploying the operator
echo "Waiting for Rook CRDs to establish..."
kubectl wait --for=condition=Established crd/cephclusters.ceph.rook.io --timeout=60s

echo -e "\n------------------------------------------"
echo "6. CREATE ROOK OPERATOR"
kubectl apply -f operator.yaml

echo -e "\n------------------------------------------"
echo "7. WAIT FOR OPERATOR TO BE DEPLOYED AND READY"
# Instead of sleep 90, we actively track the deployment status
echo "Waiting for rook-ceph-operator deployment to be available..."
kubectl wait --namespace rook-ceph \
  --for=condition=available deployment/rook-ceph-operator \
  --timeout=300s

echo -e "\n------------------------------------------"
echo "8. UPDATE CLUSTER.YAML FOR 2-NODE ARCHITECTURE"
echo "Enabling multi-daemon placement per node for 2-node compatibility..."

# This allows Rook to schedule multiple daemons on a single node when only 2 nodes are available
sed -i 's/allowMultiplePerNode: false/allowMultiplePerNode: true/' cluster.yaml

echo -e "\n------------------------------------------"
echo "9. CREATE CEPH CLUSTER"
kubectl apply -f cluster.yaml

echo -e "\n------------------------------------------"
echo "10. WAIT FOR CEPH CLUSTER TO BE READY"
echo "Waiting for CephCluster to reach Ready state (this can take several minutes)..."
kubectl wait --for=condition=Ready cephcluster --all -n rook-ceph --timeout=15m

echo -e "\n------------------------------------------"
echo "11. CREATE CEPH TOOLBOX"
kubectl apply -f toolbox.yaml

echo -e "\n------------------------------------------"
echo "12. VERIFY TOOLBOX DEPLOYMENT ROLLOUT"
echo "Waiting for rook-ceph-tools rollout to finish..."
kubectl -n rook-ceph rollout status deploy/rook-ceph-tools --timeout=5m

echo -e "\n------------------------------------------"
echo "13. CHECK CEPH STATUS VIA TOOLBOX"
echo "Fetching final Ceph health status..."
# Automatically run 'ceph status' inside the newly created toolbox pod to verify health
TOOLBOX_POD=$(kubectl -n rook-ceph get pod -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}')
kubectl -n rook-ceph exec "${TOOLBOX_POD}" -- ceph status

echo "=========================================="
echo "Rook-Ceph storage installed successfully on 2 nodes!"
echo "=========================================="

