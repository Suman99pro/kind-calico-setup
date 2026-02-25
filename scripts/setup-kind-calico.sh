#!/bin/bash
# Filename: setup-kind-calico.sh
# Purpose: Setup multi-node KIND cluster with Calico CNI
# Usage: sudo bash setup-kind-calico.sh

set -euo pipefail

echo "=== Starting KIND + Calico setup ==="

# --- Determine primary user ---
PRIMARY_USER=${SUDO_USER:-$(whoami)}
USER_HOME=$(eval echo "~$PRIMARY_USER")

echo "Running as user: $PRIMARY_USER"
echo "User home: $USER_HOME"

# --- Detect architecture ---
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"

# --- Install Docker if missing ---
if ! command -v docker &>/dev/null; then
    echo "Docker not found. Installing..."

    if [ -f /etc/debian_version ]; then
        apt-get update
        apt-get install -y docker.io
    else
        echo "Unsupported OS. Install Docker manually."
        exit 1
    fi

    systemctl enable docker
    systemctl start docker
else
    echo "Docker already installed."
fi

# --- Add user to docker group ---
if ! groups "$PRIMARY_USER" | grep -qw docker; then
    echo "Adding $PRIMARY_USER to docker group..."
    usermod -aG docker "$PRIMARY_USER"
    echo "⚠ Logout/login required for docker group changes"
else
    echo "$PRIMARY_USER already in docker group."
fi

# --- Install KIND ---
if ! command -v kind &>/dev/null; then
    echo "Installing KIND..."

    if [ "$ARCH" = "x86_64" ]; then
        curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
    elif [ "$ARCH" = "aarch64" ]; then
        curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-arm64
    else
        echo "Unsupported architecture: $ARCH"
        exit 1
    fi

    chmod +x ./kind
    mv ./kind /usr/local/bin/kind
else
    echo "KIND already installed."
fi

# --- Install kubectl ---
if ! command -v kubectl &>/dev/null; then
    echo "Installing kubectl..."

    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl"

    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
else
    echo "kubectl already installed."
fi

# --- KIND cluster config ---
echo "Creating KIND cluster configuration..."

cat > values.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: dev
nodes:
- role: control-plane
- role: worker
- role: worker
networking:
  disableDefaultCNI: true
  podSubnet: 192.168.0.0/16
EOF

# --- Create KIND cluster ---
if ! kind get clusters | grep -qw dev; then
    echo "Creating KIND cluster 'dev'..."
    kind create cluster --config values.yaml
else
    echo "KIND cluster 'dev' already exists."
fi

# --- Save kubeconfig safely ---
echo "Configuring kubeconfig..."

mkdir -p "$USER_HOME/.kube"

kind get kubeconfig --name dev > "$USER_HOME/.kube/config"

chown -R "$PRIMARY_USER:$PRIMARY_USER" "$USER_HOME/.kube"

export KUBECONFIG="$USER_HOME/.kube/config"

# --- Show nodes ---
echo "Cluster nodes (NotReady is NORMAL before CNI):"
kubectl get nodes -o wide

# --- Install Calico (DIRECT MANIFEST — STABLE) ---
CALICO_VERSION="v3.31.4"

echo "Installing Calico CNI..."

kubectl apply -f \
https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml

# --- Wait for Calico pods ---
echo "Waiting for Calico pods..."

kubectl wait --for=condition=Ready pods \
-n kube-system \
-l k8s-app=calico-node \
--timeout=300s || true

echo ""
echo "=== Setup Complete ==="
kubectl get nodes
kubectl get pods -A
