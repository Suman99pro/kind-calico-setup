#!/bin/bash
# Filename: setup-kind-calico.sh
# Purpose: Setup multi-node KIND cluster with Calico CNI
# Usage: sudo bash setup-kind-calico.sh

set -euo pipefail

echo "=== Starting KIND + Calico setup ==="

# --- Determine primary user ---
if [ "$SUDO_USER" ]; then
    PRIMARY_USER=$SUDO_USER
else
    PRIMARY_USER=$(whoami)
fi
USER_HOME=$(eval echo "~$PRIMARY_USER")
echo "Running as user: $PRIMARY_USER, home: $USER_HOME"

# --- Detect architecture ---
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"

# --- Install Docker if missing ---
if ! command -v docker &>/dev/null; then
    echo "Docker not found. Installing..."
    if [ -f /etc/debian_version ]; then
        apt-get update
        apt-get install -y ca-certificates curl gnupg lsb-release
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
          $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
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
    echo "Docker already installed."
fi

# --- Add user to docker group ---
if ! groups $PRIMARY_USER | grep -qw docker; then
    echo "Adding $PRIMARY_USER to docker group..."
    usermod -aG docker $PRIMARY_USER
    echo "Log out and back in for docker group changes to take effect."
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
    curl -LO "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl.sha256"
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
else
    echo "kubectl already installed."
fi

# --- KIND cluster config ---
echo "Creating KIND cluster configuration..."
cat > values.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
networking:
  podSubnet: 192.168.0.0/16
EOF

# --- Create KIND cluster ---
if ! kind get clusters | grep -qw dev; then
    echo "Creating KIND cluster 'dev'..."
    kind create cluster --config values.yaml
else
    echo "KIND cluster 'dev' already exists."
fi

# --- Save kubeconfig ---
mkdir -p "$USER_HOME/.kube"
kind get kubeconfig --name dev > "$USER_HOME/.kube/config"
chown -R $PRIMARY_USER:$PRIMARY_USER "$USER_HOME/.kube"
export KUBECONFIG="$USER_HOME/.kube/config"

# --- Optional: Show nodes (may be NotReady) ---
echo "KIND cluster nodes (may be NotReady until CNI is installed):"
kubectl get nodes -o wide

# --- Pre-pull Calico images ---
CALICO_VERSION="v3.31.4"
CALICO_IMAGES=(
    calico/node:$CALICO_VERSION
    calico/kube-controllers:$CALICO_VERSION
    calico/cni:$CALICO_VERSION
    calico/pod2daemon-flexvol:$CALICO_VERSION
)
echo "Pre-pulling Calico images..."
for img in "${CALICO_IMAGES[@]}"; do
    docker pull $img
    kind load docker-image $img --name dev
done

# --- Install Calico ---
echo "Installing Calico operator CRDs..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/operator-crds.yaml

echo "Installing Calico operator..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/tigera-operator.yaml

echo "Installing Calico custom resources..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/custom-resources.yaml

# --- Wait for Calico pods to be Ready ---
echo "Waiting for all Calico pods to be Ready..."
while true; do
    NOT_READY=$(kubectl get pods -n kube-system -l k8s-app=calico-node -o jsonpath='{.items[?(@.status.phase!="Running")].metadata.name}')
    if [ -z "$NOT_READY" ]; then
        echo "All Calico pods are Ready!"
        break
    fi
    echo "Still waiting for pods: $NOT_READY"
    sleep 5
done

echo "=== KIND + Calico setup complete ==="
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide
