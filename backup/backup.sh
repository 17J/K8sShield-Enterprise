#!/usr/bin/env bash

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

CLUSTER_NAME="kubesafe-demo"
APP_NAMESPACE="two-tier-app"
# FIX: Port 9005 taaki SonarQube (9000) se ladai na ho
MINIO_PORT=9005 
MINIO_CONSOLE=9001
MINIO_USER="minioadmin"
MINIO_PASS="minioadmin"
VELERO_BUCKET="velero"
VELERO_NS="velero"

# BEST FIX for Kind: Docker gateway IP for MinIO-to-Kubernetes communication
DOCKER_GATEWAY_IP=$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}')

echo -e "${GREEN}=== KubeSafe Backup Setup (MinIO + Velero) ===${NC}"
echo "MinIO API: http://localhost:$MINIO_PORT (SonarQube safe)"

# --- STEP 0: VELERO CLI INSTALLATION ---
if ! command -v velero >/dev/null 2>&1; then
    echo -e "${YELLOW}Velero CLI not found. Installing latest version...${NC}"
    VELERO_VERSION=$(curl -s https://api.github.com/repos/vmware-tanzu/velero/releases/latest | grep tag_name | cut -d '"' -f 4)
    curl -LO "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz"
    tar -xvf "velero-${VELERO_VERSION}-linux-amd64.tar.gz"
    sudo mv "velero-${VELERO_VERSION}-linux-amd64/velero" /usr/local/bin/
    rm -rf "velero-${VELERO_VERSION}-linux-amd64" "velero-${VELERO_VERSION}-linux-amd64.tar.gz"
    echo -e "${GREEN}Velero CLI installed successfully!${NC}"
fi

# --- STEP 1: MINIO SETUP (Docker) ---
echo -e "${YELLOW}Step 1: Starting MinIO (Docker)...${NC}"
if docker ps -a --format '{{.Names}}' | grep -q "^minio$"; then
    echo "Refreshing MinIO container..."
    docker rm -f minio
fi

docker run -d --name minio \
    -p $MINIO_PORT:9000 -p $MINIO_CONSOLE:9001 \
    -e "MINIO_ROOT_USER=$MINIO_USER" \
    -e "MINIO_ROOT_PASSWORD=$MINIO_PASS" \
    minio/minio server /data --console-address ":9001"

echo "Waiting for MinIO to warm up..."
sleep 5

# Create Bucket using MinIO Client (mc) inside container
docker exec minio mc alias set myminio http://localhost:9000 $MINIO_USER $MINIO_PASS || true
docker exec minio mc mb myminio/$VELERO_BUCKET || true

# --- STEP 2: CREDENTIALS ---
cat <<EOF > credentials-velero
[default]
aws_access_key_id = $MINIO_USER
aws_secret_access_key = $MINIO_PASS
EOF

# --- STEP 3: VELERO INSTALL (Helm) ---
echo -e "${YELLOW}Step 3: Installing Velero Server...${NC}"
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts || true
helm repo update

# Pre-installing CRDs to prevent timeout issues
echo "Applying Velero CRDs..."
kubectl apply -f https://raw.githubusercontent.com/vmware-tanzu/velero/main/config/crd/v1/bases/velero.io_backups.yaml || true

# Helm install without --wait to avoid "context deadline exceeded"
helm upgrade --install velero vmware-tanzu/velero \
  --namespace $VELERO_NS --create-namespace \
  --set "configuration.backupStorageLocation[0].name=default" \
  --set "configuration.backupStorageLocation[0].provider=aws" \
  --set "configuration.backupStorageLocation[0].bucket=$VELERO_BUCKET" \
  --set "configuration.backupStorageLocation[0].config.region=minio" \
  --set "configuration.backupStorageLocation[0].config.s3ForcePathStyle=true" \
  --set "configuration.backupStorageLocation[0].config.s3Url=http://$DOCKER_GATEWAY_IP:$MINIO_PORT" \
  --set credentials.secretContents.cloud="$(cat credentials-velero)" \
  --set snapshotsEnabled=false \
  --set "initContainers[0].name=velero-plugin-for-aws" \
  --set "initContainers[0].image=velero/velero-plugin-for-aws:v1.10.0" \
  --set "initContainers[0].volumeMounts[0].mountPath=/target" \
  --set "initContainers[0].volumeMounts[0].name=plugins"

echo -e "${YELLOW}Waiting for Velero Pod to be ready...${NC}"
kubectl wait --namespace $VELERO_NS \
  --for=condition=ready pod \
  --selector=component=velero \
  --timeout=600s

# --- STEP 4: VERIFICATION ---
echo -e "${GREEN}Verifying Backup Storage Location...${NC}"
sleep 15
kubectl get backupstoragelocation -n $VELERO_NS

# --- STEP 5: TEST BACKUP ---
echo -e "${YELLOW}Step 5: Testing Backup of namespace: $APP_NAMESPACE...${NC}"
# Delete old test backup if exists
velero backup delete my-k8s-backup --confirm || true

velero backup create my-k8s-backup --include-namespaces $APP_NAMESPACE --wait

echo -e "${GREEN}====================================${NC}"
echo "✅ SUCCESS: Velero is ready and Backup is created!"
echo "MinIO Console: http://localhost:$MINIO_CONSOLE"
echo -e "${GREEN}====================================${NC}"
