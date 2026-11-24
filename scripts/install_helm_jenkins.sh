#!/bin/bash

# 1. Strict error handling
set -eo pipefail

# Safely discover the executing user and hostname
REAL_USER=$(whoami)
JENKINS_DIR="/home/${REAL_USER}/jenkinsdir"
NODE_NAME=$(hostname)

echo "------------------------------------------"
echo "1. CHECK HELM VERSION"
helm version --short

echo -e "\n------------------------------------------"
echo "2. ADD AND UPDATE HELM REPOS"
# Use --force-update to ensure idempotency if repos already exist
helm repo add jenkins https://charts.jenkins.io --force-update
helm repo add bitnami https://charts.bitnami.com/bitnami --force-update
helm repo update

echo -e "\n------------------------------------------"
echo "3. PREPARE LOCAL JENKINS DIRECTORY"
echo "Target directory: ${JENKINS_DIR}"
mkdir -p "${JENKINS_DIR}"
chmod -R 777 "${JENKINS_DIR}"

echo -e "\n------------------------------------------"
echo "4. APPLY PERSISTENT VOLUME"
# Apply directly via stdin without creating and deleting temporary files
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: jenkins-pv
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: "${JENKINS_DIR}"
EOF

kubectl get pv jenkins-pv

echo -e "\n------------------------------------------"
echo "5. REMOVE CONTROL-PLANE TAINT"
kubectl taint nodes "${NODE_NAME}" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true

echo -e "\n------------------------------------------"
echo "6. RESTART CALICO COMPONENTS"
kubectl rollout restart deployment/calico-kube-controllers -n kube-system
kubectl rollout status deployment/calico-kube-controllers -n kube-system --timeout=5m

kubectl rollout restart daemonset/calico-node -n kube-system
kubectl rollout status daemonset/calico-node -n kube-system --timeout=5m

echo -e "\n------------------------------------------"
echo "7. INSTALL OR UPGRADE JENKINS VIA HELM"
# 'helm upgrade --install' is idempotent and prevents errors on re-runs
helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins \
  --create-namespace \
  --set controller.nodeSelector."kubernetes\.io/hostname"="${NODE_NAME}"

echo -e "\n------------------------------------------"
echo "8. WAIT FOR JENKINS STATEFULSET ROLLOUT"
kubectl rollout status statefulset/jenkins -n jenkins --timeout=15m

echo -e "\n------------------------------------------"
echo "9. EXPOSE JENKINS VIA NODEPORT SERVICE"
# Create declarative Service instead of imperative 'kubectl expose' (which fails if service exists)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: jenkins-service
  namespace: jenkins
spec:
  type: NodePort
  selector:
    app.kubernetes.io/component: jenkins-controller
    app.kubernetes.io/instance: jenkins
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
EOF

kubectl get service -n jenkins

echo -e "\n------------------------------------------"
echo "10. SHOW JENKINS ADMIN PASSWORD"
# Removed '-it' flag so it doesn't crash in non-interactive shells (e.g., Ansible/CI)
kubectl exec --namespace jenkins svc/jenkins -c jenkins -- /bin/cat /run/secrets/additional/chart-admin-password && echo

echo -e "\n------------------------------------------"
echo "11. CONFIGURE JENKINS ROLEBINDING"
# Dry-run + apply ensures idempotency instead of 'kubectl create'
kubectl create rolebinding jenkins-admin-binding \
  --clusterrole=admin \
  --serviceaccount=jenkins:default \
  --namespace=jenkins \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "\n------------------------------------------"
echo "11.1. CREATE AND CONFIGURE ARGOCD ROLEBINDING"
# Dry-run + apply ensures idempotency instead of 'kubectl create'
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create rolebinding argocd-admin-binding \
  --clusterrole=admin \
  --serviceaccount=jenkins:default \
  --namespace=argocd \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "\n------------------------------------------"
echo "12. ENSURE DIRECTORY PERMISSIONS"
echo "chmod -R 777 "${JENKINS_DIR}" <-- to move to the ansible directly"

echo -e "\n=========================================="
echo "Jenkins installation and configuration completed!"
echo "=========================================="
