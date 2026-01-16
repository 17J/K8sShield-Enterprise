#!/usr/bin/env bash

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

CLUSTER_NAME="kubesafe-demo"

echo -e "${GREEN}=== KubeSafe Phase 1 & 2 Setup Script ===${NC}"

# Check prerequisites
command -v kind >/dev/null 2>&1 || { echo -e "${RED}Kind not found.${NC}"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}kubectl not found.${NC}"; exit 1; }

if kind get clusters | grep -q "^$CLUSTER_NAME$"; then
  echo -e "${YELLOW}Cluster '$CLUSTER_NAME' already exists. Deleting first...${NC}"
  kind delete cluster --name "$CLUSTER_NAME"
fi

echo -e "${YELLOW}Phase 1: Creating Kind cluster (with CNI disabled for Calico)...${NC}"
cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true # Important: Calico needs this
  podSubnet: "192.168.0.0/16"
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF

echo -e "${GREEN}Cluster created. Waiting for nodes to initialize...${NC}"
sleep 20

# --- CALICO INSTALLATION SECTION (Fixed) ---
echo -e "${YELLOW}Installing Calico Operator...${NC}"
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/tigera-operator.yaml

echo -e "${YELLOW}Waiting for Tigera Operator CRDs to register...${NC}"
# Wait specifically for the CRD to be recognized by API server
until kubectl get crd installations.operator.tigera.io >/dev/null 2>&1; do
  echo "Waiting for CRD..."
  sleep 5
done

echo -e "${YELLOW}Applying Calico Custom Resources...${NC}"
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/custom-resources.yaml

# Patching Calico for Kind compatibility
echo -e "${YELLOW}Patching Calico IP pool for Kind...${NC}"
sleep 10
kubectl patch installation default --type=merge -p '{"spec": {"calicoNetwork": {"ipPools": [{"cidr": "192.168.0.0/16", "encapsulation": "VXLAN"}]}}}'

echo -e "${YELLOW}Waiting for Calico pods to be ready (This takes time)...${NC}"
kubectl wait --for=condition=ready pod -l k8s-app=calico-node -A --timeout=300s

# --- INGRESS SECTION ---
echo -e "${YELLOW}Phase 2: Installing NGINX Ingress Controller...${NC}"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

echo -e "${YELLOW}Applying webhook fix...${NC}"
# Ingress sometimes gets stuck due to this webhook in Kind
sleep 15
kubectl delete --ignore-not-found=true ValidatingWebhookConfiguration ingress-nginx-admission

echo -e "${YELLOW}Waiting for Ingress controller to be ready...${NC}"
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

echo -e "${GREEN}====================================${NC}"
echo -e "${GREEN}✅ Setup Complete!${NC}"
echo "Check pods: kubectl get pods -A"
echo -e "${GREEN}====================================${NC}"
