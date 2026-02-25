#!/bin/bash
# Filename: setup-kind-calico.sh
# Purpose: Setup multi-node KIND cluster with latest Calico CNI
# Usage: sudo bash setup-kind-calico.sh

set -euo pipefail

echo "=== Starting KIND + Calico setup ==="

# Detect architecture
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"

# Download KIND if missing
if ! command -v kind &>/dev/null; then
    echo "Downloading KIND..."
    if [ "$ARCH" = "x86_64" ]; then
        curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
    elif [ "$ARCH" = "aarch64" ]; then
        curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-arm64
    else
        echo "Unsupported architecture: $ARCH"
        exit 1
    fi
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
else
    echo "KIND already installed, skipping download."
fi

# Download kubectl if missing
if ! command -v kubectl &>/dev/null; then
    echo "Downloading kubectl..."
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl"
    curl -LO "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl.sha256"
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
else
    echo "kubectl already installed, skipping download."
fi

# Create KIND cluster config
echo "Creating KIND cluster configuration..."
cat > values.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
networking:
  disableDefaultCNI: true
  podSubnet: 192.168.0.0/16
EOF

# Create KIND cluster if not exists
if ! kind get clusters | grep -q "^dev$"; then
    echo "Creating KIND cluster 'dev'..."
    kind create cluster --config values.yaml --name dev
else
    echo "KIND cluster 'dev' already exists, skipping creation."
fi

# Verify nodes
echo "Kubernetes nodes:"
kubectl get nodes -o wide

# Get latest stable Calico version from GitHub
CALICO_VERSION=$(curl -s https://api.github.com/repos/projectcalico/calico/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
echo "Latest Calico version: v$CALICO_VERSION"

# Install Calico CNI
echo "Installing Calico operator CRDs..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v$CALICO_VERSION/manifests/operator-crds.yaml

echo "Installing Calico operator..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v$CALICO_VERSION/manifests/tigera-operator.yaml

echo "Installing Calico custom resources..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v$CALICO_VERSION/manifests/custom-resources.yaml

echo "Setup complete! Watching Calico pods..."
watch kubectl get pods -l k8s-app=calico-node -A
