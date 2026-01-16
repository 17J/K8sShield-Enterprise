#!/usr/bin/env bash

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

CLUSTER_NAME="kubesafe-demo"
APP_NAMESPACE="two-tier-app"
MINIO_PORT=9005 
MINIO_CONSOLE=9001
MINIO_USER="minioadmin"
MINIO_PASS="minioadmin"
VELERO_BUCKET="velero"
VELERO_NS="velero"

DOCKER_GATEWAY_IP=$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}')

echo -e "${GREEN}=== KubeSafe Backup Setup (MinIO + Velero) ===${NC}"

# --- CLEANUP OLD INSTALLATION ---
echo -e "${YELLOW}Cleaning up any previous installation...${NC}"
kubectl delete namespace $VELERO_NS --ignore-not-found=true
sleep 5

# Delete ALL Velero CRDs
echo "Removing old Velero CRDs..."
kubectl get crd | grep velero.io | awk '{print $1}' | xargs -r kubectl delete crd 2>/dev/null || true
sleep 3

# --- STEP 0: VELERO CLI ---
if ! command -v velero >/dev/null 2>&1; then
    echo -e "${YELLOW}Installing Velero CLI...${NC}"
    VELERO_VERSION=$(curl -s https://api.github.com/repos/vmware-tanzu/velero/releases/latest | grep tag_name | cut -d '"' -f 4)
    curl -LO "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz"
    tar -xvf "velero-${VELERO_VERSION}-linux-amd64.tar.gz"
    sudo mv "velero-${VELERO_VERSION}-linux-amd64/velero" /usr/local/bin/
    rm -rf "velero-${VELERO_VERSION}-linux-amd64" "velero-${VELERO_VERSION}-linux-amd64.tar.gz"
    echo -e "${GREEN}Velero CLI installed: $(velero version --client-only)${NC}"
fi

# --- STEP 1: MINIO ---
echo -e "${YELLOW}Step 1: Setting up MinIO...${NC}"
docker rm -f minio 2>/dev/null || true
docker run -d --name minio \
    -p $MINIO_PORT:9000 -p $MINIO_CONSOLE:9001 \
    -e "MINIO_ROOT_USER=$MINIO_USER" \
    -e "MINIO_ROOT_PASSWORD=$MINIO_PASS" \
    minio/minio server /data --console-address ":9001"

echo "Waiting for MinIO to start..."
sleep 8

# Verify MinIO is running
if ! docker ps | grep -q minio; then
    echo -e "${RED}Error: MinIO container failed to start${NC}"
    exit 1
fi

docker exec minio mc alias set myminio http://localhost:9000 $MINIO_USER $MINIO_PASS
docker exec minio mc mb myminio/$VELERO_BUCKET 2>/dev/null || echo "Bucket already exists"
echo -e "${GREEN}MinIO bucket created: $VELERO_BUCKET${NC}"

# --- STEP 2: CREDENTIALS ---
echo -e "${YELLOW}Step 2: Creating credentials file...${NC}"
cat <<EOF > credentials-velero
[default]
aws_access_key_id = $MINIO_USER
aws_secret_access_key = $MINIO_PASS
EOF

# --- STEP 3: INSTALL VELERO USING CLI (NO HELM) ---
echo -e "${YELLOW}Step 3: Installing Velero using Velero CLI...${NC}"

velero install \
    --provider aws \
    --plugins velero/velero-plugin-for-aws:v1.10.0 \
    --bucket $VELERO_BUCKET \
    --secret-file ./credentials-velero \
    --use-node-agent=false \
    --use-volume-snapshots=false \
    --backup-location-config region=minio,s3ForcePathStyle="true",s3Url=http://$DOCKER_GATEWAY_IP:$MINIO_PORT \
    --namespace $VELERO_NS

echo -e "${GREEN}Velero installation initiated${NC}"

# --- STEP 4: WAIT FOR VELERO DEPLOYMENT ---
echo -e "${YELLOW}Step 4: Waiting for Velero deployment...${NC}"

# Wait for deployment to be created
sleep 10

# Wait for deployment
echo "Waiting for Velero deployment to be available..."
kubectl wait --namespace $VELERO_NS \
  --for=condition=available deployment/velero \
  --timeout=300s

# Wait for pod to be ready
echo "Waiting for Velero pod to be ready..."
kubectl wait --namespace $VELERO_NS \
  --for=condition=ready pod \
  --selector=component=velero \
  --timeout=300s

echo -e "${GREEN}✓ Velero pod is running${NC}"

# Show pod status
kubectl get pods -n $VELERO_NS

# --- STEP 5: VERIFY BACKUP LOCATION ---
echo -e "${YELLOW}Step 5: Verifying backup storage location...${NC}"

# Give it time to connect to MinIO
sleep 15

# Check backup location
velero backup-location get

# Verify backup location is available
RETRY_COUNT=0
MAX_RETRIES=6
LOCATION_AVAILABLE=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if velero backup-location get 2>/dev/null | grep -q "Available"; then
        echo -e "${GREEN}✓ Backup location is available!${NC}"
        LOCATION_AVAILABLE=true
        break
    else
        echo "Waiting for backup location to become available... ($((RETRY_COUNT + 1))/$MAX_RETRIES)"
        sleep 10
        RETRY_COUNT=$((RETRY_COUNT + 1))
    fi
done

if [ "$LOCATION_AVAILABLE" = false ]; then
    echo -e "${RED}Warning: Backup location not showing as available yet${NC}"
    echo "Checking Velero logs..."
    kubectl logs -n $VELERO_NS deployment/velero --tail=50
fi

# --- STEP 6: TEST BACKUP ---
echo -e "${YELLOW}Step 6: Creating test backup...${NC}"

# Delete old backup if exists
velero backup delete my-k8s-backup --confirm 2>/dev/null || true
sleep 3

# Check if target namespace exists
if kubectl get namespace $APP_NAMESPACE &> /dev/null; then
    echo "Creating backup of namespace: $APP_NAMESPACE"
    velero backup create my-k8s-backup \
        --include-namespaces $APP_NAMESPACE \
        --wait
    
    echo ""
    echo "Backup details:"
    velero backup describe my-k8s-backup --details
else
    echo -e "${RED}Warning: Namespace '$APP_NAMESPACE' not found${NC}"
    echo "Creating backup of 'default' namespace instead..."
    velero backup create test-backup \
        --include-namespaces default \
        --wait
    
    velero backup describe test-backup --details
fi

# --- STEP 7: SUMMARY ---
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Velero Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${GREEN}MinIO Console:${NC} http://localhost:$MINIO_CONSOLE"
echo -e "${GREEN}Username:${NC} $MINIO_USER"
echo -e "${GREEN}Password:${NC} $MINIO_PASS"
echo ""
echo -e "${YELLOW}Useful Commands:${NC}"
echo "  # Check Velero status"
echo "  kubectl get all -n $VELERO_NS"
echo ""
echo "  # List backups"
echo "  velero backup get"
echo ""
echo "  # Check backup location"
echo "  velero backup-location get"
echo ""
echo "  # Describe specific backup"
echo "  velero backup describe my-k8s-backup"
echo ""
echo "  # View backup logs"
echo "  velero backup logs my-k8s-backup"
echo ""
echo "  # Create new backup"
echo "  velero backup create <name> --include-namespaces <namespace>"
echo ""
echo "  # Restore from backup"
echo "  velero restore create --from-backup <backup-name>"
echo ""
