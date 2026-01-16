#!/usr/bin/env bash

set -euo pipefail

# Colors for better output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== KubeSafe Prerequisites Installation Script ===${NC}"
echo "This script installs: Docker, Kind, kubectl, Helm"
echo "Best for Ubuntu/Debian Linux. Run as regular user (sudo will be asked where needed)."
echo "Current date: $(date)"
echo ""

# Function to check if command exists
cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_docker() {
  if cmd_exists docker; then
    echo -e "${YELLOW}Docker already installed. Skipping...${NC}"
    docker --version
    return
  fi

  echo -e "${YELLOW}Installing Docker...${NC}"
  sudo apt update -y
  sudo apt install -y docker.io
  sudo usermod -aG docker jenkins
  sudo chown jenkins:docker /var/run/docker.sock
  sudo chmod 666 /var/run/docker.sock

  echo -e "${YELLOW}Docker installed. Please log out and log back in (or run 'newgrp docker') for group change to take effect.${NC}"
  echo "Verify later: docker --version"
}

install_kind() {
  if cmd_exists kind; then
    echo -e "${YELLOW}Kind already installed. Skipping...${NC}"
    kind version
    return
  fi

  echo -e "${YELLOW}Installing latest Kind (v0.31.0 as of 2026)...${NC}"
  # For Linux amd64 - change to darwin-amd64 for macOS, windows-amd64 for Windows
  curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
  chmod +x ./kind
  sudo mv ./kind /usr/local/bin/kind

  echo -e "${GREEN}Kind installed.${NC}"
  kind version
}

install_kubectl() {
  if cmd_exists kubectl; then
    echo -e "${YELLOW}kubectl already installed. Skipping...${NC}"
    kubectl version --client
    return
  fi

  echo -e "${YELLOW}Installing latest stable kubectl...${NC}"
  # Get latest stable version dynamically
  K8S_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
  curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
  chmod +x kubectl
  sudo mv kubectl /usr/local/bin/

  echo -e "${GREEN}kubectl installed.${NC}"
  kubectl version --client
}

install_helm() {
  if cmd_exists helm; then
    echo -e "${YELLOW}Helm already installed. Skipping...${NC}"
    helm version
    return
  fi

  echo -e "${YELLOW}Installing Helm 3...${NC}"
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

  echo -e "${GREEN}Helm installed.${NC}"
  helm version
}

# Main execution
echo -e "${YELLOW}Step 1: Docker${NC}"
install_docker

echo ""
echo -e "${YELLOW}Step 2: Kind${NC}"
install_kind

echo ""
echo -e "${YELLOW}Step 3: kubectl${NC}"
install_kubectl

echo ""
echo -e "${YELLOW}Step 4: Helm${NC}"
install_helm

echo ""
echo -e "${GREEN}====================================${NC}"
echo -e "${GREEN}All tools installed successfully!${NC}"
echo "Now you can run your Kind cluster setup."
echo "Tip: After Docker group change, run 'newgrp docker' or logout/login."
echo -e "${GREEN}====================================${NC}"
