#!/usr/bin/env bash

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== KubeSafe Simple Cleanup ===${NC}"
echo "This script will:"
echo "1. Delete the Kind cluster 'kubesafe-demo'"
echo "2. Stop and remove the MinIO Docker container"
echo ""
read -p "Are you sure? Everything will be deleted (y/n): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo -e "${YELLOW}Cleanup cancelled.${NC}"
  exit 0
fi

echo -e "${YELLOW}Deleting Kind cluster 'kubesafe-demo'...${NC}"
kind delete cluster --name kubesafe-demo || echo -e "${YELLOW}Cluster not found – it may already be deleted.${NC}"

echo ""
echo -e "${YELLOW}Stopping & removing MinIO container...${NC}"
if docker ps -q -f name=minio >/dev/null; then
  docker stop minio
  docker rm minio
  echo -e "${GREEN}MinIO removed.${NC}"
else
  echo -e "${YELLOW}MinIO container is not running.${NC}"
fi

echo ""
echo -e "${GREEN}Cleanup complete!${NC}"
echo -e "${GREEN}====================================${NC}"