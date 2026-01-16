#!/usr/bin/env bash

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="monitoring"
RELEASE_NAME="monitoring"  # Helm release name
GRAFANA_PORT=30080         # NodePort for Grafana (access via http://localhost:30080)
GRAFANA_USER="admin"
GRAFANA_PASS="admin"       # CHANGE THIS in production!

echo -e "${GREEN}=== KubeSafe Monitoring Setup (kube-prometheus-stack) ===${NC}"
echo "Namespace: $NAMESPACE"
echo "Grafana: http://localhost:$GRAFANA_PORT (user: $GRAFANA_USER / pass: $GRAFANA_PASS)"
echo "Date: $(date)"
echo ""

# Check prerequisites
command -v helm >/dev/null 2>&1 || { echo -e "${RED}Helm not found. Install first.${NC}"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}kubectl not found.${NC}"; exit 1; }

# Check if in Kind cluster
CURRENT_CONTEXT=$(kubectl config current-context)
if [[ ! "$CURRENT_CONTEXT" =~ ^kind- ]]; then
  echo -e "${YELLOW}Warning: Not in a Kind cluster context ($CURRENT_CONTEXT). Continuing anyway...${NC}"
fi

echo -e "${YELLOW}Step 1: Adding/Updating prometheus-community Helm repo...${NC}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo update

echo -e "${YELLOW}Step 2: Creating namespace '$NAMESPACE' if not exists...${NC}"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo -e "${YELLOW}Step 3: Installing/Upgrading kube-prometheus-stack...${NC}"
helm upgrade --install "$RELEASE_NAME" prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --version ">=80.0.0" \  
  --set grafana.enabled=true \
  --set grafana.adminPassword="$GRAFANA_PASS" \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort="$GRAFANA_PORT" \
  --set prometheus.prometheusSpec.storageSpec={ } \  # Disable persistence for Kind demo (no PV needed)
  --set alertmanager.enabled=true \
  --set alertmanager.alertmanagerSpec.storage={ } \
  --set prometheusOperator.admissionWebhooks.enabled=true \  
  --set kubeStateMetrics.enabled=true \
  --set nodeExporter.enabled=true \
  --wait --timeout=300s

echo -e "${GREEN}Deployment complete!${NC}"

echo -e "${YELLOW}Step 4: Verifying pods...${NC}"
kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/part-of=kube-prometheus-stack"

echo ""
echo -e "${YELLOW}Grafana Access:${NC}"
echo "→ Open browser: http://localhost:$GRAFANA_PORT"
echo "→ Login: $GRAFANA_USER / $GRAFANA_PASS"
echo "→ Default dashboards for cluster monitoring already loaded!"

echo ""
echo -e "${YELLOW}Next steps / Tips:${NC}"
echo "- Check Prometheus: kubectl port-forward svc/monitoring-kube-prom-prometheus -n monitoring 9090:9090 & → http://localhost:9090"
echo "- Add ServiceMonitor for your app (like nginx) if needed (example in your repo)"
echo "- Cleanup: helm uninstall $RELEASE_NAME -n $NAMESPACE"
echo "- Delete namespace: kubectl delete ns $NAMESPACE (careful – deletes everything)"

echo -e "${GREEN}====================================${NC}"
echo "Monitoring stack ready 
echo -e "${GREEN}====================================${NC}"