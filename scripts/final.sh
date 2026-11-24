#!/bin/bash

# 1. Strict error handling (with fallback handling for optional components)
set -eo pipefail

echo "========================================================================"
echo "📊  CLOUD-NATIVE DEVOPS BOOTSTRAP - FINAL SYSTEM SUMMARY"
echo "========================================================================"
echo "This script summarizes the end-to-end infrastructure deployment."
echo "It dynamically extracts cluster access endpoints, storage health states,"
echo "and administrative credentials for the provisioned platform layer."
echo "========================================================================"

echo -e "\n------------------------------------------"
echo "1. KUBERNETES CONTROL PLANE ACCESS"
# Added timeout and fallback in case external internet/ifconfig.me is slow or blocked
IP=$(curl -fsSL --max-time 5 https://ifconfig.me || hostname -I | awk '{print $1}')
echo "Public/Node IP Address : ${IP}"
echo "SSH Login Command      : ssh root@${IP}"
echo "Kubectl Active User    : $(whoami)"

echo -e "\n------------------------------------------"
echo "2. JENKINS ACCESS & CREDENTIALS"
if kubectl get svc jenkins-service -n jenkins &>/dev/null; then
    PORT=$(kubectl get svc jenkins-service -n jenkins -o jsonpath="{.spec.ports[0].nodePort}")
    # Removed '-it' flag so it works smoothly inside Ansible/non-TTY environments
    PASSWD=$(kubectl exec --namespace jenkins svc/jenkins -c jenkins -- /bin/cat /run/secrets/additional/chart-admin-password 2>/dev/null || echo "N/A (Pod not ready)")
    echo "Web Link : http://${IP}:${PORT}"
    echo "Username : admin"
    echo "Password : ${PASSWD}"
else
    echo "Jenkins service not found in namespace 'jenkins'."
fi

echo -e "\n------------------------------------------"
echo "3. ARGOCD ACCESS & CREDENTIALS"
if kubectl get svc argocd-server -n argocd &>/dev/null; then
    # Dynamically find the NodePort for http/https instead of assuming index [0]
    PORT_A=$(kubectl get svc argocd-server -n argocd -o jsonpath="{.spec.ports[?(@.name=='http')].nodePort}")
    [ -z "$PORT_A" ] && PORT_A=$(kubectl get svc argocd-server -n argocd -o jsonpath="{.spec.ports[0].nodePort}")
    
    # Decode directly into a variable instead of writing plaintext password to passwd_a.txt
    PASSWD_A=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "N/A (Secret not found)")
    echo "Web Link : http://${IP}:${PORT_A}"
    echo "Username : admin"
    echo "Password : ${PASSWD_A}"
else
    echo "ArgoCD service not found in namespace 'argocd'."
fi

echo -e "\n------------------------------------------"
echo "4. DEMO APPLICATION ENDPOINT"
NGINX_PORT=30080
echo "NGINX Demo Link : http://${IP}:${NGINX_PORT}"


echo -e "\n------------------------------------------"
echo "5. ROOK-CEPH CLUSTER HEALTH STATUS"
if kubectl get deploy rook-ceph-tools -n rook-ceph &>/dev/null; then
    kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
else
    echo "Rook-Ceph toolbox not found in namespace 'rook-ceph'."
fi

echo -e "\n------------------------------------------"
echo "6. EXPORTING DYNAMIC PORTS FOR TERRAFORM CYCLE 2"
cat <<EOF > /tmp/k8s_ports.env
JENKINS_PORT=${PORT:-null}
ARGOCD_PORT=${PORT_A:-null}
NGINX_DEMO_PORT=${NGINX_PORT:-30080}
EOF
echo "Ports exported to /tmp/k8s_ports.env"

echo -e "\n========================================================================"
echo "Summary generation completed!"
echo "========================================================================"
