#!/bin/bash

# 1. Strict error handling
set -eo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Execute this script with sudo or as root." >&2
  exit 1
fi

K8S_VERSION="v1.35" # Consistent version for both keyring and repository (e.g., v1.31, v1.35)

echo "------------------------------------------"
echo "0. DISABLE UNATTENDED UPGRADES & CLEAN DPKG"
systemctl stop unattended-upgrades.service 2>/dev/null || true
systemctl disable unattended-upgrades.service 2>/dev/null || true

while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
  echo "Waiting a few seconds for unattended-upgrades to finish the current package..."
  sleep 2
done

dpkg --configure -a
echo "Success: unattended-upgrades disabled and dpkg ready."

echo -e "\n------------------------------------------"
echo "1. CONFIGURE KERNEL MODULES"
cat <<EOM > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOM

modprobe overlay
modprobe br_netfilter

lsmod | grep -E "br_netfilter|overlay"

echo -e "\n------------------------------------------"
echo "2. CONFIGURE SYSCTL NETWORKING"
cat <<EOM > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOM

sysctl --system | grep -E "net.bridge.bridge-nf-call|net.ipv4.ip_forward"

echo -e "\n------------------------------------------"
echo "3. INSTALL AND CONFIGURE CONTAINERD"
apt-get -o DPkg::Lock::Timeout=300 update -qq
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq containerd

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl enable containerd.service
systemctl restart containerd.service
systemctl is-active --quiet containerd.service && echo "Success: containerd is running."

echo -e "\n------------------------------------------"
echo "4. DISABLE SWAP"
swapoff -a
sed -i '/ swap / s/^\([^#]\)/#\1/g' /etc/fstab
free -h

echo -e "\n------------------------------------------"
echo "5. INSTALL KUBERNETES PACKAGES (${K8S_VERSION})"
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq apt-transport-https ca-certificates curl gpg conntrack

mkdir -p -m 755 /etc/apt/keyrings

# Fixed official pkgs.k8s.io URLs with proper ${K8S_VERSION} variable syntax
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list

apt-get -o DPkg::Lock::Timeout=300 update -qq
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

dpkg -l kubelet kubeadm kubectl | awk '/^ii/ {print $2, $3}'

echo -e "\n=========================================="
echo "Worker node prerequisites configured successfully!"
echo "Ready for Ansible kubeadm join task."
echo "=========================================="
