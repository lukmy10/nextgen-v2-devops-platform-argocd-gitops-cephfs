#!/bin/bash

# 1. Enable strict error handling
# -e: exit immediately if any command exits with a non-zero status
# -o pipefail: catch errors hidden inside pipelines
set -eo pipefail

echo "------------------------------------------"
echo "1. LOAD RBD KERNEL MODULE"
# Load the rbd module immediately
sudo modprobe rbd

echo -e "\n------------------------------------------"
echo "2. VERIFY RBD MODULE IS LOADED"
# Check if the module is active. If not, exit with an error.
if lsmod | grep -i rbd; then
    echo "Success: RBD module is successfully loaded into the kernel."
else
    echo "Error: RBD module failed to load!" >&2
    exit 1
fi

echo -e "\n------------------------------------------"
echo "3. CONFIGURE PERSISTENT LOADING ON REBOOT"
# Ensure the module loads automatically after a system restart
# Using tee with sudo to safely write to system configuration
echo "rbd" | sudo tee /etc/modules-load.d/rbd.conf > /dev/null

echo -e "\n------------------------------------------"
echo "4. VERIFY MODULES-LOAD CONFIGURATION"
# Verify that the configuration file exists and contains the correct rule
if [ -f "/etc/modules-load.d/rbd.conf" ] && grep -q "rbd" /etc/modules-load.d/rbd.conf; then
    echo "Success: /etc/modules-load.d/rbd.conf is properly configured."
    ls -l /etc/modules-load.d/rbd.conf
else
    echo "Error: Failed to configure persistent RBD loading!" >&2
    exit 1
fi

echo -e "\n=========================================="
echo "RBD module configuration completed successfully!"
echo "=========================================="
