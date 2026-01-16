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

# --- STEP 0: VELERO CLI ---
if ! command -v velero >/dev/null 2>&1; then
    echo -e "${YELLOW}Installing Velero CLI...${NC}"
    VELERO_VERSION=$(curl -s https://api.github.com/repos/vmware-tanzu/velero/releases/latest | grep tag_name | cut -d '"' -f 4)
    curl -LO "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz"
    tar -xvf "velero-${VELERO_VERSION}-linux-amd64.tar.gz"
    sudo mv "velero-${VELERO_VERSION}-linux-amd64/velero" /usr/local/bin/
    rm -rf "velero-${VELERO_VERSION}-linux-amd64" "velero-${VELERO_VERSION}-linux-amd64.tar.gz"
fi

# --- STEP 1: MINIO ---
echo -e "${YELLOW}Step 1: Setting up MinIO...${NC}"
docker rm -f minio || true
docker run -d --name minio \
    -p $MINIO_PORT:9000 -p $MINIO_CONSOLE:9001 \
    -e "MINIO_ROOT_USER=$MINIO_USER" \
    -e "MINIO_ROOT_PASSWORD=$MINIO_PASS" \
    minio/minio server /data --console-address ":9001"
sleep 5
docker exec minio mc alias set myminio http://localhost:9000 $MINIO_USER $MINIO_PASS || true
docker exec minio mc mb myminio/$VELERO_BUCKET || true

# --- STEP 2: CREDENTIALS ---
echo -e "${YELLOW}Step 2: Creating credentials...${NC}"
cat <<EOF > credentials-velero
[default]
aws_access_key_id = $MINIO_USER
aws_secret_access_key = $MINIO_PASS
EOF

# --- STEP 3: INSTALL VELERO CRDs FIRST ---
echo -e "${YELLOW}Step 3: Installing Velero CRDs...${NC}"

# Create namespace first
kubectl create namespace $VELERO_NS --dry-run=client -o yaml | kubectl apply -f -

# Download and apply all CRDs
VELERO_VERSION=$(curl -s https://api.github.com/repos/vmware-tanzu/velero/releases/latest | grep tag_name | cut -d '"' -f 4 | sed 's/v//')
CRD_BASE_URL="https://raw.githubusercontent.com/vmware-tanzu/velero/v${VELERO_VERSION}/config/crd/v1/bases"

echo "Downloading CRDs from version v${VELERO_VERSION}..."

for crd in backups backupstoragelocations deletebackuprequests downloadrequests \
           podvolumebackups podvolumerestores resticrepositories restores \
           schedules serverstatusrequests volumesnapshotlocations backuprepositories \
           datadownloads datauploads; do
    echo "  - Applying ${crd}.velero.io CRD..."
    kubectl apply -f "${CRD_BASE_URL}/velero.io_${crd}.yaml" 2>/dev/null || true
done

# Wait for CRDs to be established
echo "Waiting for CRDs to be fully established..."
kubectl wait --for condition=established --timeout=60s crd/backups.velero.io
kubectl wait --for condition=established --timeout=60s crd/backupstoragelocations.velero.io
kubectl wait --for condition=established --timeout=60s crd/restores.velero.io
kubectl wait --for condition=established --timeout=60s crd/volumesnapshotlocations.velero.io

sleep 5

# --- STEP 4: INSTALL VELERO SERVER ---
echo -e "${YELLOW}Step 4: Installing Velero Server via Helm...${NC}"

helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts || true
helm repo update

# Uninstall previous release if exists
helm uninstall velero -n $VELERO_NS 2>/dev/null || true
sleep 5

# Install with --skip-crds since we already applied them
helm install velero vmware-tanzu/velero \
  --namespace $VELERO_NS \
  --skip-crds \
  --set-file credentials.secretContents.cloud=credentials-velero \
  --set configuration.backupStorageLocation[0].name=default \
  --set configuration.backupStorageLocation[0].provider=aws \
  --set configuration.backupStorageLocation[0].bucket=$VELERO_BUCKET \
  --set configuration.backupStorageLocation[0].config.region=minio \
  --set configuration.backupStorageLocation[0].config.s3ForcePathStyle=true \
  --set configuration.backupStorageLocation[0].config.s3Url=http://$DOCKER_GATEWAY_IP:$MINIO_PORT \
  --set snapshotsEnabled=false \
  --set deployNodeAgent=false \
  --set initContainers[0].name=velero-plugin-for-aws \
  --set initContainers[0].image=velero/velero-plugin-for-aws:v1.10.0 \
  --set initContainers[0].volumeMounts[0].mountPath=/target \
  --set initContainers[0].volumeMounts[0].name=plugins

# --- STEP 5: WAIT FOR VELERO POD ---
echo -e "${YELLOW}Step 5: Waiting for Velero to be ready...${NC}"
kubectl wait --namespace $VELERO_NS \
  --for=condition=ready pod \
  --selector=component=velero \
  --timeout=300s

# Verify backup location
echo "Verifying backup storage location..."
sleep 10
velero backup-location get || echo "Backup location not yet available, retrying..."
sleep 5
velero backup-location get

# --- STEP 6: TEST BACKUP ---
echo -e "${YELLOW}Step 6: Testing Backup...${NC}"
velero backup delete my-k8s-backup --confirm 2>/dev/null || true
sleep 5
velero backup create my-k8s-backup --include-namespaces $APP_NAMESPACE --wait

echo ""
echo -e "${GREEN}✅ SUCCESS! Velero is installed and configured.${NC}"
echo -e "${GREEN}MinIO Console: http://localhost:$MINIO_CONSOLE${NC}"
echo -e "${GREEN}Credentials: $MINIO_USER / $MINIO_PASS${NC}"
echo ""
echo "Verify installation:"
echo "  kubectl get pods -n $VELERO_NS"
echo "  velero backup get"
echo "  velero backup describe my-k8s-backup"
