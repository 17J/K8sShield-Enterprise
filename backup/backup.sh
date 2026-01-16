#!/usr/bin/env bash

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

CLUSTER_NAME="kubesafe-demo"          # Change if different
APP_NAMESPACE="two-tier-app"          # Your app namespace (from earlier)
MINIO_PORT=9000
MINIO_CONSOLE=9001
MINIO_USER="minioadmin"
MINIO_PASS="minioadmin"
VELERO_BUCKET="velero"
VELERO_NS="velero"
HOST_IP=$(hostname -I | awk '{print $1}')  # Kind host IP (usually works)

echo -e "${GREEN}=== KubeSafe Backup Setup Script (MinIO + Velero) ===${NC}"
echo "MinIO: http://$HOST_IP:$MINIO_PORT"
echo "Bucket: $VELERO_BUCKET"
echo "App NS to backup: $APP_NAMESPACE"
echo ""

# Check prereqs
command -v docker >/dev/null 2>&1 || { echo -e "${RED}Docker not found${NC}"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo -e "${RED}Helm not found${NC}"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}kubectl not found${NC}"; exit 1; }
kubectl config current-context | grep -q "kind-$CLUSTER_NAME" || { echo -e "${RED}Not in Kind cluster context${NC}"; exit 1; }

echo -e "${YELLOW}Step 1: Starting MinIO (Docker)...${NC}"
if docker ps -q -f name=minio >/dev/null; then
  echo "MinIO already running."
else
  docker run -d --name minio \
    -p $MINIO_PORT:9000 -p $MINIO_CONSOLE:$MINIO_CONSOLE \
    -e "MINIO_ROOT_USER=$MINIO_USER" \
    -e "MINIO_ROOT_PASSWORD=$MINIO_PASS" \
    minio/minio server /data --console-address ":$MINIO_CONSOLE"

  echo "Waiting 5s for MinIO to start..."
  sleep 5
fi

echo -e "${YELLOW}Creating alias & bucket '$VELERO_BUCKET'...${NC}"
docker exec minio mc alias set myminio http://localhost:$MINIO_PORT $MINIO_USER $MINIO_PASS || true
docker exec minio mc mb myminio/$VELERO_BUCKET || true

echo -e "${YELLOW}Step 2: Creating credentials-velero file...${NC}"
cat <<EOF > credentials-velero
[default]
aws_access_key_id = $MINIO_USER
aws_secret_access_key = $MINIO_PASS
EOF

echo -e "${YELLOW}Step 3: Adding/updating Helm repo...${NC}"
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts || true
helm repo update

echo -e "${YELLOW}Step 4: Installing/Upgrading Velero with MinIO config...${NC}"
helm upgrade --install velero vmware-tanzu/velero \
  --namespace $VELERO_NS --create-namespace \
  --set "configuration.backupStorageLocation[0].name=default" \
  --set "configuration.backupStorageLocation[0].provider=aws" \
  --set "configuration.backupStorageLocation[0].bucket=$VELERO_BUCKET" \
  --set "configuration.backupStorageLocation[0].config.region=minio" \
  --set "configuration.backupStorageLocation[0].config.s3ForcePathStyle=true" \
  --set "configuration.backupStorageLocation[0].config.s3Url=http://$HOST_IP:$MINIO_PORT" \
  --set credentials.secretContents.cloud="$(cat credentials-velero)" \
  --set snapshotsEnabled=false \
  --set "initContainers[0].name=velero-plugin-for-aws" \
  --set "initContainers[0].image=velero/velero-plugin-for-aws:v1.10.0" \
  --set "initContainers[0].volumeMounts[0].mountPath=/target" \
  --set "initContainers[0].volumeMounts[0].name=plugins" \
  --wait --timeout=300s

echo -e "${GREEN}Velero installed! Checking backup location...${NC}"
velero backup-location get

echo ""
echo -e "${YELLOW}Step 5: Testing Backup & Restore (simulate disaster)...${NC}"
echo "Creating test backup of namespace: $APP_NAMESPACE"

velero backup create my-k8s-backup --include-namespaces $APP_NAMESPACE --wait

echo "Simulating disaster: Deleting namespace $APP_NAMESPACE"
kubectl delete namespace $APP_NAMESPACE --force --grace-period=0 || true

sleep 5

echo "Restoring from backup..."
velero restore create --from-backup my-k8s-backup --wait

echo "Verifying pods after restore:"
kubectl get pods -n $APP_NAMESPACE || echo "Namespace restored – check pods"

echo -e "${GREEN}====================================${NC}"
echo "Backup setup & test complete!"
echo "MinIO Console: http://$HOST_IP:$MINIO_CONSOLE (user/pass: minioadmin/minioadmin)"
echo "To cleanup MinIO: docker stop minio && docker rm minio"
echo "To delete Velero: helm uninstall velero -n $VELERO_NS"
echo -e "${GREEN}====================================${NC}"