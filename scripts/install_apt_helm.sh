#!/bin/bash

# 1. Enable strict error handling
# -e: exit immediately if any command exits with a non-zero status
# -o pipefail: catch errors hidden inside pipelines (crucial for 'curl | bash')
set -eo pipefail

echo "------------------------------------------"
echo "1. CHECK AND INSTALL REQUIRED PACKAGES"

# List of packages to verify and install if missing
PACKAGES=("curl" "jq" "yq")
APT_UPDATED=false

for pkg in "${PACKAGES[@]}"; do
    if ! command -v "$pkg" &> /dev/null; then
        echo -e "\n------------------------------------------"
        echo "${pkg^^} NOT INSTALLED. Installing..."
        
        # Run apt-get update only once to save time
        if [ "$APT_UPDATED" = false ]; then
            sudo apt-get update -qq
            APT_UPDATED=true
        fi
        
        # Install package non-interactively without unnecessary sleep
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y -qq "$pkg"
        echo "Success: ${pkg} installed."
    else
        echo -e "\n------------------------------------------"
        echo "${pkg^^} IS ALREADY INSTALLED."
    fi
done

echo -e "\n------------------------------------------"
echo "2. VERIFY INSTALLED PACKAGES"
dpkg -l "${PACKAGES[@]}" | awk '/^ii/ {print $2, $3}'

echo -e "\n------------------------------------------"
echo "3. INSTALL OR UPDATE HELM 3"

# Check if Helm is already installed; the official script handles updates natively,
# but adding flags -fsSL makes curl fail safely on HTTP errors instead of piping HTML error pages to bash.
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo -e "\n------------------------------------------"
echo "4. VERIFY HELM INSTALLATION"
helm version --short

echo -e "\n=========================================="
echo "All tools (curl, jq, yq, helm) are ready!"
echo "=========================================="
