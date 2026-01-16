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
GRAFANA_PASS="admin"

echo -e "${GREEN}=== KubeSafe Monitoring Setup (Dev Mode) ===${NC}"

# Step 1: Repo update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update

# Step 2: Namespace (Using simple create to avoid annotation warning)
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Step 3: Install (Wait Hata diya hai taaki timeout na ho)
echo -e "${YELLOW}Deploying Prometheus & Grafana (Background)...${NC}"
helm upgrade --install "$RELEASE_NAME" prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --set alertmanager.enabled=false \
  --set grafana.adminPassword="$GRAFANA_PASS" \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort="$GRAFANA_PORT" \
  --set prometheus.prometheusSpec.storageSpec=null \
  --set prometheusOperator.admissionWebhooks.enabled=false

# Step 4: 
echo -e "${YELLOW}Waiting for Grafana Pod (Downloading images can take time)...${NC}"
# Timeout badha kar 600s (10 min) kar diya hai
kubectl wait --namespace "$NAMESPACE" \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=grafana \
  --timeout=600s

echo -e "${GREEN}✅ Done! Grafana is ready.${NC}"
echo -e "${GREEN}Grafana: http://localhost:$GRAFANA_PORT${NC}"
echo -e "User: admin | Pass: $GRAFANA_PASS"
