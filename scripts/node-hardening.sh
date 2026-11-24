#!/bin/bash

# 1. Strict error handling
set -eo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Execute this script with sudo or as root." >&2
  exit 1
fi

# Detect node role automatically based on kube-apiserver manifest
if [ -f "/etc/kubernetes/manifests/kube-apiserver.yaml" ]; then
  NODE_ROLE="control-plane"
else
  NODE_ROLE="worker"
fi

echo "========================================================================"
echo "🛡️  SYSTEM & KUBERNETES NODE SECURITY HARDENING (ROLE: ${NODE_ROLE^^})"
echo "========================================================================"

echo -e "\n------------------------------------------"
echo "1. INSTALL SECURITY TOOLS (UFW, FAIL2BAN, UNATTENDED-UPGRADES)"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw fail2ban unattended-upgrades

echo -e "\n------------------------------------------"
echo "2. CONFIGURE FIREWALL (UFW) FOR ROLE: ${NODE_ROLE^^}"
ufw default deny incoming
ufw default allow outgoing

# --- COMMON RULES FOR ALL NODES (CONTROL PLANE & WORKER) ---
ufw allow 22/tcp comment 'SSH Access'
ufw allow 10250/tcp comment 'Kubelet API'
ufw allow 30000:32767/tcp comment 'Kubernetes NodePort Services'

# Calico CNI Networking (BGP & VXLAN)
ufw allow 179/tcp comment 'Calico BGP'
ufw allow 4789/udp comment 'Calico VXLAN'

# Allow Calico IP-in-IP (protocol 4) in /etc/ufw/before.rules (UFW CLI rejects 'proto 4')
if ! grep -q -- "-A ufw-before-input -p 4 -j ACCEPT" /etc/ufw/before.rules; then
  sed -i '/^COMMIT/i # Allow Calico IP-in-IP (protocol 4)\n-A ufw-before-input -p 4 -j ACCEPT\n-A ufw-before-output -p 4 -j ACCEPT\n' /etc/ufw/before.rules
  echo "Added Calico IP-in-IP (protocol 4) rule to /etc/ufw/before.rules"
fi

# Rook-Ceph Storage (OSD & Monitor communication across nodes)
ufw allow 6789/tcp comment 'Ceph Monitor v1'
ufw allow 3300/tcp comment 'Ceph Monitor v2'
ufw allow 6800:7300/tcp comment 'Ceph OSD & Daemons'

# --- CONTROL PLANE ONLY RULES ---
if [ "${NODE_ROLE}" == "control-plane" ]; then
  echo "Applying additional Control Plane firewall rules..."
  ufw allow 6443/tcp comment 'Kubernetes API Server'
  ufw allow 2379:2380/tcp comment 'etcd server client API'
  ufw allow 10259/tcp comment 'kube-scheduler'
  ufw allow 10257/tcp comment 'kube-controller-manager'
fi

# Enable and reload UFW non-interactively
ufw --force enable
ufw reload
ufw status numbered

echo -e "\n------------------------------------------"
echo "3. HARDEN SSH CONFIGURATION"
SSHD_HARDENING_CONF="/etc/ssh/sshd_config.d/99-k8s-hardening.conf"
mkdir -p /etc/ssh/sshd_config.d

cat <<EOF > "${SSHD_HARDENING_CONF}"
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
ChallengeResponseAuthentication no
KerberosAuthentication no
GSSAPIAuthentication no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

if sshd -t; then
    systemctl reload ssh || systemctl reload sshd
    echo "Success: SSH configuration hardened and reloaded."
else
    echo "ERROR: SSH config syntax check failed. Reverting..." >&2
    rm -f "${SSHD_HARDENING_CONF}"
    exit 1
fi

echo -e "\n------------------------------------------"
echo "4. CONFIGURE FAIL2BAN FOR SSH BRUTE-FORCE PROTECTION"
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
EOF

systemctl enable fail2ban
systemctl restart fail2ban
systemctl is-active --quiet fail2ban && echo "Success: Fail2ban is active."

echo -e "\n------------------------------------------"
echo "5. KERNEL NETWORK SECURITY (SYSCTL) - K8S COMPATIBLE"
cat <<EOF > /etc/sysctl.d/99-k8s-security.conf
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
EOF

sysctl --system > /dev/null
echo "Success: Kernel network hardening parameters applied."

echo -e "\n------------------------------------------"
echo "6. ENABLE AUTOMATIC SECURITY UPDATES"
dpkg-reconfigure -f noninteractive unattended-upgrades
echo "Success: Unattended security upgrades enabled."

echo -e "\n========================================================================"
echo "🛡️  Security hardening for ${NODE_ROLE^^} completed successfully!"
echo "========================================================================"
