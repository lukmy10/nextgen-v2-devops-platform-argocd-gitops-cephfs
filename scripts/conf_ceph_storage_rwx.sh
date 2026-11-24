#!/bin/bash

# 1. Enable strict error handling
# -e: exit immediately if any command exits with a non-zero status
# -o pipefail: catch errors hidden inside pipelines
set -eo pipefail

# Ensure we are in the home directory as requested by the original script
cd ~

echo "------------------------------------------"
echo "1. APPLY CEPH FILESYSTEM YAML"
kubectl apply -f cephfilesystem.yaml

echo -e "\n------------------------------------------"
echo "2. APPLY STORAGE CLASS YAML"
kubectl apply -f cephstorageclass_fs_rwx.yml

echo "Waiting for StorageClass 'rook-ceph-fs' to be registered..."
kubectl wait --for=create storageclass/rook-ceph-fs --timeout=30s

echo "Waiting for CephFilesystem 'myfs' to be Ready..."
kubectl wait --for=jsonpath='{.status.phase}'=Ready cephfilesystem/myfs -n rook-ceph --timeout=300s

echo -e "\n------------------------------------------"
echo "3. APPLY PERSISTENT VOLUME CLAIM"
kubectl apply -f pvc_nginx_rwx.yaml -n argocd

echo -e "\n------------------------------------------"
echo "4. WAIT FOR PVC TO BE BOUND"
# Instead of a blind 'sleep 45', we actively wait for the specific PVC status.
# We first extract the name of the PVC dynamically from the file to remain fully autonomous.
# If your file contains a fixed name (e.g., 'nginx-pvc'), you can replace the variable with the raw name.
PVC_NAME=$(kubectl apply -f pvc_nginx_rwx.yaml -n argocd --dry-run=client -o jsonpath='{.metadata.name}')

echo "Waiting for PVC '${PVC_NAME}' in namespace 'argocd' to reach Bound state..."
kubectl wait --namespace argocd \
  --for=jsonpath='{.status.phase}'=Bound pvc/"${PVC_NAME}" \
  --timeout=180s

echo -e "\n------------------------------------------"
echo "5. GET PERSISTENT VOLUME CLAIMS STATUS"
kubectl get pvc -n argocd

echo -e "\n=========================================="
echo "Ceph Filesystem and PVC configured successfully!"
echo "=========================================="

