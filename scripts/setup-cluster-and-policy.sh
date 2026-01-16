#!/usr/bin/env bash

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

CLUSTER_NAME="kubesafe-demo"

echo -e "${GREEN}=== KubeSafe Phase 1 & 2 Setup Script ===${NC}"
echo "This will:"
echo "1. Create Kind cluster with ingress-ready label + ports"
echo "2. Install Calico CNI (latest v3.31.x)"
echo "3. Install NGINX Ingress Controller for Kind"
echo "Date: $(date)"
echo ""

# Check prerequisites
command -v kind >/dev/null 2>&1 || { echo -e "${RED}Kind not found. Install first.${NC}"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}kubectl not found.${NC}"; exit 1; }

if kind get clusters | grep -q "^$CLUSTER_NAME$"; then
  echo -e "${YELLOW}Cluster '$CLUSTER_NAME' already exists. Deleting first...${NC}"
  kind delete cluster --name "$CLUSTER_NAME"
fi

echo -e "${YELLOW}Phase 1: Creating Kind cluster with Ingress support...${NC}"
cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
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

echo -e "${GREEN}Cluster created.${NC}"
kubectl cluster-info --context kind-"$CLUSTER_NAME"

echo -e "${YELLOW}Installing Calico (v3.31.3 manifests)...${NC}"
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/tigera-operator.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/custom-resources.yaml

# Patch for Kind (CIDR compatibility - 10.244.0.0/16 common for Kind/Calico)
echo -e "${YELLOW}Patching Calico IP pool for Kind...${NC}"
kubectl patch installation default --type=merge -p '{"spec": {"calicoNetwork": {"ipPools": [{"cidr": "10.244.0.0/16", "encapsulation": "VXLAN"}]}}}'

echo -e "${YELLOW}Waiting for Calico pods to be ready (up to 5 min)...${NC}"
kubectl wait --for=condition=ready pod -l k8s-app=calico-node -A --timeout=300s

echo -e "${GREEN}Calico ready.${NC}"

echo -e "${YELLOW}Phase 2: Installing NGINX Ingress Controller...${NC}"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Common fix for Kind (admission webhook sometimes causes connection refused)
echo -e "${YELLOW}Applying webhook fix (delete validating webhook if exists)...${NC}"
sleep 10
kubectl delete --ignore-not-found=true -A ValidatingWebhookConfiguration ingress-nginx-admission

echo -e "${YELLOW}Waiting for Ingress controller to be ready (up to 3 min)...${NC}"
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

echo -e "${GREEN}NGINX Ingress ready!${NC}"
echo ""
echo -e "${GREEN}====================================${NC}"
echo "Setup complete!"
echo "Next steps:"
echo "- Check pods: kubectl get pods -A"
echo "- Test ingress later with your app"
echo "- To cleanup: kind delete cluster --name $CLUSTER_NAME"
echo -e "${GREEN}====================================${NC}"