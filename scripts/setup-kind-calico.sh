#!/bin/bash
# Filename: setup-kind-calico.sh
# Purpose: Setup multi-node KIND cluster with latest Calico CNI
#          Also ensures Docker is installed and user can run docker without sudo
# Usage: sudo bash setup-kind-calico.sh

set -euo pipefail

echo "=== Starting KIND + Calico setup ==="

# Get the username running the script
if [ "$SUDO_USER" ]; then
    USERNAME=$SUDO_USER
else
    USERNAME=$(whoami)
fi
echo "Running as user: $USERNAME"

# Detect architecture
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"

# --- Install Docker if missing ---
if ! command -v docker &>/dev/null; then
    echo "Docker not found. Installing Docker..."
    # For Debian/Ubuntu
    if [ -f /etc/debian_version ]; then
        apt-get update
        apt-get install -y ca-certificates curl gnupg lsb-release
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
          $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    # For RHEL/CentOS/AlmaLinux
    elif [ -f /etc/redhat-release ]; then
        yum install -y yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        echo "Unsupported OS for automatic Docker install. Please install Docker manually."
        exit 1
    fi
    systemctl enable docker
    systemctl start docker
else
    echo "Docker is already installed."
fi

# --- Add user to docker group for passwordless access ---
if ! groups $USERNAME | grep -q "\bdocker\b"; then
    echo "Adding $USERNAME to docker group..."
    usermod -aG docker $USERNAME
    echo "You may need to log out and log back in for docker group changes to take effect."
else
    echo "$USERNAME is already in the docker group."
fi

# --- Install KIND ---
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

# --- Install kubectl ---
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

# --- Create KIND cluster config ---
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

# --- Create KIND cluster ---
if ! kind get clusters | grep -q "^dev$"; then
    echo "Creating KIND cluster 'dev'..."
    kind create cluster --config values.yaml --name dev
else
    echo "KIND cluster 'dev' already exists, skipping creation."
fi

# --- Verify nodes ---
echo "Kubernetes nodes:"
kubectl get nodes -o wide

# --- Wait for KIND nodes to be ready ---
echo "Waiting for all KIND nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# --- Install Calico using KIND-optimized manifest ---

echo "Installing Calico CNI (KIND-optimized manifest)..."
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

echo "Setup complete! Watching Calico pods..."
watch kubectl get pods -l k8s-app=calico-node -A
