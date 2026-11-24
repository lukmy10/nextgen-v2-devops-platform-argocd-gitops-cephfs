#!/bin/bash

# 1. Strict error handling
set -eo pipefail

echo "========================================================================"
echo "CALICO CNI INSTALLATION"
echo "Provides pod networking and network policies for Kubernetes"
echo "========================================================================"

echo -e "\n------------------------------------------"
echo "1. APPLY CALICO MANIFEST"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml

echo -e "\n------------------------------------------"
echo "2. WAIT FOR CALICO ROLLOUT STATUS"
echo "Waiting for calico-node DaemonSet in kube-system..."
# Added missing '-n kube-system' flag; without it kubectl looks in 'default' namespace and fails
kubectl rollout status daemonset/calico-node -n kube-system --timeout=5m

echo "Waiting for calico-kube-controllers Deployment in kube-system..."
kubectl rollout status deployment/calico-kube-controllers -n kube-system --timeout=5m

echo -e "\n------------------------------------------"
echo "3. VERIFY SYSTEM PODS"
kubectl get pods -n kube-system -l k8s-app=calico-node
kubectl get pods -n kube-system -l k8s-app=calico-kube-controllers

echo -e "\n========================================================================"
echo "Calico CNI installed and ready!"
echo "========================================================================"
