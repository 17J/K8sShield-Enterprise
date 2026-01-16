# 🏗️ K8sShield-Enterprise: End-to-End Secure Kubernetes Stack

## 📋 Prerequisites

### 1. Docker

- **Ubuntu/Debian:**

  ```bash
  sudo apt update
  sudo apt install docker.io -y
  sudo usermod -aG docker $USER  && newgrp docker
  ```

### 2. Kind (Kubernetes IN Docker)

Local Kubernetes cluster

````bash
# Linux/macOS/Windows (with curl)
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64   # macOS: darwin-amd64, Windows: windows-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind


> Verify: `kind version`

### 3. kubectl

```bash
# Linux
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/


> Verify: `kubectl version --client`

### 4. Helm

Package manager for Kubernetes.

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Ya macOS: brew install helm
````

> Verify: `helm version`

---🚀

## 🌟 Key Features

- 🛡️ **Zero-Trust Networking:** Calico-based default-deny policies.
- 🔐 **Hardened RBAC:** Fine-grained permissions for ServiceAccounts.
- 💾 **Disaster Recovery:** Automated backups using Velero & Minio S3 storage.
- 📊 **Full-Stack Monitoring:** Prometheus & Grafana integration with custom ServiceMonitors.
- 🛣️ **Traffic Management:** Nginx Ingress Controller for secure external access.

---

## 🛠️ Quick Start Guide

### Phase 1: Cluster & Networking Setup

```bash
# Create Kind Cluster with Ingress support
cat <<EOF | kind create cluster --name kubesafe-demo --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
  - containerPort: 443
    hostPort: 443
EOF

# Deploy Calico for Network Policies
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/tigera-operator.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/custom-resources.yaml

# FIX: Patch Calico IP Pool for Kind (Avoid CIDR Mismatch)
kubectl patch installation default --type=merge -p '{"spec": {"calicoNetwork": {"ipPools": [{"cidr": "10.244.0.0/16", "encapsulation": "VXLAN"}]}}}'

# Wait for Calico
kubectl wait --for=condition=ready pod -l k8s-app=calico-node -A --timeout=300s
```

### Phase 2: Ingress Controller Setup

```bash
# Install NGINX Ingress Controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# FIX: Delete Validation Webhook (Prevents "Connection Refused" error)
sleep 10
kubectl delete -A ValidatingWebhookConfiguration ingress-nginx-admission

# Wait for Controller
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=120s
```

### Phase 3: Secure Application Deployment

**Nginx (Frontend)** and **Redis (Backend)** deployment phase

```yaml
# Save in app.yml
# 1. Namespace: Logical isolation for the entire application stack
apiVersion: v1
kind: Namespace
metadata:
  name: two-tier-app
---
# 2. ServiceAccount: Provides a dedicated identity for the Nginx pod
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nginx-sa
  namespace: two-tier-app
---
# 3. RBAC Role: Defines specific permissions (ReadOnly access to Pods and Services)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: nginx-role
  namespace: two-tier-app
rules:
  - apiGroups: [""]
    resources: ["services", "pods"]
    verbs: ["get", "list"]
---
# 4. RoleBinding: Grants the defined Role permissions to the Nginx ServiceAccount
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: nginx-rb
  namespace: two-tier-app
subjects:
  - kind: ServiceAccount
    name: nginx-sa
    namespace: two-tier-app
roleRef:
  kind: Role
  name: nginx-role
  apiGroup: rbac.authorization.k8s.io
---
# 5. Redis Backend Deployment: Database/Cache layer for the application
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: two-tier-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis # Target label for NetPol and Monitoring
    spec:
      containers:
        - name: redis
          image: redis:alpine
          ports:
            - containerPort: 6379
---
# 6. Redis Service: Internal service to expose the Redis database
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: two-tier-app
spec:
  selector:
    app: redis
  ports:
    - name: redis-port
      port: 6379
      targetPort: 6379
---
# 7. Nginx Frontend Deployment: Web server layer configured with RBAC identity
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: two-tier-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      serviceAccountName: nginx-sa # Attaching RBAC ServiceAccount
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
---
# 8. Nginx Service: Exposes Frontend with named port 'http' for Prometheus scraping
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: two-tier-app
spec:
  selector:
    app: nginx
  ports:
    - name: http # Port name required for Prometheus ServiceMonitor
      port: 80
      targetPort: 80
---
# 9. Ingress: Routes external HTTP traffic to the Nginx frontend service
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-ingress
  namespace: two-tier-app
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx
                port:
                  number: 80
---
# 10. Network Policy (Default Deny): Implements Zero-Trust by blocking all traffic by default
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: two-tier-app
spec:
  podSelector: {} # Targets all pods in this namespace
  policyTypes: [Ingress, Egress]
---
# 11. NetPol (Allow Ingress): Permits traffic only from the Ingress Controller to Nginx
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-to-nginx
  namespace: two-tier-app
spec:
  podSelector:
    matchLabels:
      app: nginx
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
---
# 12. NetPol (App Isolation): Allows Nginx to communicate with Redis on specific port
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-nginx-to-redis
  namespace: two-tier-app
spec:
  podSelector:
    matchLabels:
      app: redis
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: nginx # Only traffic from pods labeled 'app: nginx' is allowed
      ports:
        - protocol: TCP
          port: 6379
---
# 13. NetPol (DNS Access): Permits pods to perform DNS lookups via CoreDNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: two-tier-app
spec:
  podSelector: {}
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
```

```bash
kubectl apply -f app.yaml
```

### Phase 4: Security & Connection Testing

```bash
# Pod Name Export
export NIC_POD=$(kubectl get pod -l app=nginx -n two-tier-app -o jsonpath='{.items[0].metadata.name}')

# Alpine image uses to install curl
kubectl exec -it $NIC_POD -n two-tier-app -- apk add curl

# 1. Test Redis Connection (ALLOWED)
kubectl exec -it $NIC_POD -n two-tier-app -- curl -v redis:6379

# 2. Test External Connection (BLOCKED by NetPol)
kubectl exec -it $NIC_POD -n two-tier-app -- curl --connect-timeout 5 google.com

# 3. Test RBAC (List Pods via ServiceAccount - ALLOWED)
kubectl exec -it $NIC_POD -n two-tier-app -- sh -c "curl -k -H \"Authorization: Bearer \$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\" https://kubernetes.default/api/v1/namespaces/two-tier-app/pods"
```

### Phase 5: Monitoring (Observability)

````bash
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword=admin \
  --set grafana.service.port=3000


```yml
# nginx-servicemonitor.yml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nginx-sm
  namespace: monitoring
  labels:
    release: monitoring
spec:
  selector:
    matchLabels:
      app: nginx
  namespaceSelector:
    any: false
    matchNames:
      - two-tier-app
  endpoints:
  - port: http
```

# Apply ServiceMonitor to bridge App and Prometheus

kubectl apply -f nginx-servicemonitor.yml

````

### Phase 6: Backup & Disaster Recovery (Velero + Minio)

```bash
# 6.1 Minio Installation (Local Docker)
docker run -d --name minio -p 9000:9000 -p 9001:9001 \
  -e "MINIO_ROOT_USER=minioadmin" -e "MINIO_ROOT_PASSWORD=minioadmin" \
  minio/minio server /data --console-address ":9001"

# Create Bucket
docker exec -it minio mc alias set myminio http://localhost:9000 minioadmin minioadmin
docker exec -it minio mc mb myminio/velero
```

```bash
# Credentials file
cat <<EOF > credentials-velero
[default]
aws_access_key_id = minioadmin
aws_secret_access_key = minioadmin
EOF
```

# Add Helm Chart

```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update
```

# Install Velero

```bash
helm upgrade --install velero vmware-tanzu/velero \
  --namespace velero --create-namespace \
  --set "configuration.backupStorageLocation[0].name=default" \
  --set "configuration.backupStorageLocation[0].provider=aws" \
  --set "configuration.backupStorageLocation[0].bucket=velero" \
  --set "configuration.backupStorageLocation[0].config.region=minio" \
  --set "configuration.backupStorageLocation[0].config.s3ForcePathStyle=true" \
  --set "configuration.backupStorageLocation[0].config.s3Url=http://$(hostname -I | awk '{print $1}'):9000" \
  --set credentials.secretContents.cloud="$(cat credentials-velero)" \
  --set snapshotsEnabled=false \
  --set "initContainers[0].name=velero-plugin-for-aws" \
  --set "initContainers[0].image=velero/velero-plugin-for-aws:v1.10.0" \
  --set "initContainers[0].volumeMounts[0].mountPath=/target" \
  --set "initContainers[0].volumeMounts[0].name=plugins"
```

```bash
# Backup & Restore testing
velero backup-location get
velero backup create my-k8s-backup --include-namespaces two-tier-app
kubectl delete namespace two-tier-app  # Simulate disaster
velero restore create --from-backup my-k8s-backup
kubectl get pods -n two-tier-app  # Verify
```

---

## 🧪 Testing

- **NetPol Check:** `curl google.com` (Should timeout 🚫)
- **RBAC Check:** `curl` to K8s API (Should list pods ✅)
- **DR Check:** `velero backup create` -> `kubectl delete ns` -> `velero restore` (Success ✅)

## 🧹 Cleanup

```bash
kind delete cluster --name kubesafe-demo
docker stop minio && docker rm minio
```
