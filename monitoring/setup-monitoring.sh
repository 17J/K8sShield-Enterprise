#!/usr/bin/env bash

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="monitoring"
RELEASE_NAME="monitoring"
GRAFANA_PORT=30080
GRAFANA_USER="admin"
GRAFANA_PASS="admin"

echo -e "${GREEN}=== KubeSafe Monitoring Setup ===${NC}"

# Check prerequisites
command -v helm >/dev/null 2>&1 || { echo -e "${RED}Helm not found.${NC}"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}kubectl not found.${NC}"; exit 1; }

echo -e "${YELLOW}Step 1: Adding Helm repo...${NC}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update

echo -e "${YELLOW}Step 2: Ensuring namespace '$NAMESPACE' exists...${NC}"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo -e "${YELLOW}Step 3: Installing kube-prometheus-stack...${NC}"
# Note: Removed trailing comments inside the command to avoid "2 arguments" error
helm upgrade --install "$RELEASE_NAME" prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --set grafana.enabled=true \
  --set grafana.adminPassword="$GRAFANA_PASS" \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort="$GRAFANA_PORT" \
  --set prometheus.prometheusSpec.storageSpec={} \
  --set alertmanager.enabled=true \
  --set alertmanager.alertmanagerSpec.storage={} \
  --set prometheusOperator.admissionWebhooks.enabled=true \
  --set kubeStateMetrics.enabled=true \
  --set nodeExporter.enabled=true \
  --wait --timeout=300s

echo -e "${GREEN}✅ Deployment complete!${NC}"

echo -e "${YELLOW}Step 4: Waiting for Grafana to be ready...${NC}"
kubectl wait --namespace "$NAMESPACE" \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=grafana \
  --timeout=120s

echo ""
echo -e "${GREEN}Grafana is live at: http://localhost:$GRAFANA_PORT${NC}"
echo -e "User: $GRAFANA_USER | Pass: $GRAFANA_PASS"
