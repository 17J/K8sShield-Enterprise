#!/usr/bin/env bash

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

CLUSTER_NAME="kubesafe-demo"
APP_NAMESPACE="two-tier-app"
# FIX: Host port 9005 use kar rahe hain kyunki 9000 pe SonarQube hai
MINIO_PORT=9005 
MINIO_CONSOLE=9001
MINIO_USER="minioadmin"
MINIO_PASS="minioadmin"
VELERO_BUCKET="velero"
VELERO_NS="velero"

# BEST FIX for Kind: Use Docker's default gateway IP for MinIO communication
DOCKER_GATEWAY_IP=$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}')

echo -e "${GREEN}=== KubeSafe Backup Setup (MinIO + Velero) ===${NC}"
echo "MinIO API: http://localhost:$MINIO_PORT (SonarQube safe)"

# --- VELERO CLI INSTALLATION ---
if ! command -v velero >/dev/null 2>&1; then
    echo -e "${YELLOW}Velero CLI not found. Installing latest version...${NC}"
    VELERO_VERSION=$(curl -s https://api.github.com/repos/vmware-tanzu/velero/releases/latest | grep tag_name | cut -d '"' -f 4)
    curl -LO "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz"
    tar -xvf "velero-${VELERO_VERSION}-linux-amd64.tar.gz"
    sudo mv "velero-${VELERO_VERSION}-linux-amd64/velero" /usr/local/bin/
    rm -rf "velero-${VELERO_VERSION}-linux-amd64" "velero-${VELERO_VERSION}-linux-amd64.tar.gz"
    echo -e "${GREEN}Velero CLI installed successfully!${NC}"
fi

# Step 1: MinIO Start (Force recreate to fix port conflicts)
echo -e "${YELLOW}Step 1: Starting MinIO (Docker)...${NC}"
if docker ps -a --format '{{.Names}}' | grep -q "^minio$"; then
    echo "Removing old MinIO container to update ports..."
    docker rm -f minio
fi

docker run -d --name minio \
    -p $MINIO_PORT:9000 -p $MINIO_CONSOLE:9001 \
    -e "MINIO_ROOT_USER=$MINIO_USER" \
    -e "MINIO_ROOT_PASSWORD=$MINIO_PASS" \
    minio/minio server /data --console-address ":9001"

echo "Waiting for MinIO..."
sleep 5

# Create Bucket (Internal container communication uses 9000)
docker exec minio mc alias set myminio http://localhost:9000 $MINIO_USER $MINIO_PASS || true
docker exec minio mc mb myminio/$VELERO_BUCKET || true

# Step 2: Credentials
cat <<EOF > credentials-velero
[default]
aws_access_key_id = $MINIO_USER
aws_secret_access_key = $MINIO_PASS
EOF

# Step 3: Velero Install
echo -e "${YELLOW}Step 3: Installing Velero Server (Helm)...${NC}"
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts || true
helm repo update

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
  --set "initContainers[0].volumeMounts[0].name=plugins" \
  --wait --timeout=300s

# Step 4: Verification
echo -e "${GREEN}Verifying Backup Location Status...${NC}"
sleep 10
kubectl get backupstoragelocation -n $VELERO_NS

echo -e "${YELLOW}Step 5: Testing Backup of $APP_NAMESPACE...${NC}"
velero backup delete my-k8s-backup --confirm || true
velero backup create my-k8s-backup --include-namespaces $APP_NAMESPACE --wait

echo -e "${GREEN}✅ Backup created. Ready for disaster simulation!${NC}"
