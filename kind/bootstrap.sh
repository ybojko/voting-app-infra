#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "ERROR: .env file not found at ${ENV_FILE}"
  echo "Copy .env.example to .env and fill in values:"
  echo "  cp ${SCRIPT_DIR}/.env.example ${ENV_FILE}"
  echo "  # edit ${ENV_FILE}"
  exit 1
fi

source "${ENV_FILE}"

CLUSTER_NAME="voting-app-local"
GITOPS_REPO="https://github.com/ybojko/voting-app-gitops.git"
METALLB_VERSION="v0.14.9"
GATEWAY_API_VERSION="v1.2.0"
ENVOY_GATEWAY_VERSION="v1.2.0"
CERT_MANAGER_VERSION="v1.16.5"

echo "=== Phase 1: Create kind cluster ==="
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster ${CLUSTER_NAME} already exists, skipping creation"
else
  kind create cluster --config "${SCRIPT_DIR}/kind-config.yaml"
fi

kubectl config use-context kind-${CLUSTER_NAME}

echo "=== Phase 2: Install MetalLB ==="
if kubectl get ns metallb-system &>/dev/null; then
  echo "MetalLB already installed"
else
  kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
  kubectl wait --namespace metallb-system --for=condition=ready pod -l app=metallb --timeout=120s

  # Get kind network CIDR and allocate IP range
  KIND_NET=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo "172.18.0.0/16")
  # Use upper portion of the subnet for LB IPs
  SUBNET_PREFIX=$(echo "${KIND_NET}" | cut -d'.' -f1-2)
  LB_RANGE="${SUBNET_PREFIX}.255.200-${SUBNET_PREFIX}.255.250"

  kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: pool
  namespace: metallb-system
spec:
  addresses:
    - ${LB_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2advert
  namespace: metallb-system
EOF
  echo "MetalLB configured with range: ${LB_RANGE}"
fi

echo "=== Phase 3: Install Gateway API CRDs + Envoy Gateway ==="
if kubectl get gatewayclass eg &>/dev/null; then
  echo "Gateway API / Envoy Gateway already installed"
else
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version "${ENVOY_GATEWAY_VERSION}" \
    -n envoy-gateway --create-namespace --skip-crds

  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF

  kubectl wait --namespace envoy-gateway --for=condition=ready pod -l app.kubernetes.io/name=gateway-helm --timeout=180s
  echo "Envoy Gateway installed"
fi

echo "=== Phase 4: Install cert-manager (self-signed) ==="
if kubectl get ns cert-manager &>/dev/null; then
  echo "cert-manager already installed"
else
  helm repo add jetstack https://charts.jetstack.io --force-update
  helm upgrade --install cert-manager jetstack/cert-manager \
    -n cert-manager --create-namespace \
    --set installCRDs=true \
    --set webhook.enabled=false \
    --set cainjector.enabled=false \
    --version "${CERT_MANAGER_VERSION}"

  kubectl wait --namespace cert-manager --for=condition=ready pod -l app.kubernetes.io/name=cert-manager --timeout=120s

  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: local-tls
  namespace: voting
spec:
  secretName: local-tls
  commonName: "*.local"
  dnsNames:
    - "*.local"
    - "*.nip.io"
    - "*.sslip.io"
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
EOF
  kubectl create namespace voting --dry-run=client -o yaml | kubectl apply -f -
  kubectl wait --for=condition=ready certificate local-tls -n voting --timeout=60s
  echo "Self-signed cert-manager installed"
fi

echo "=== Phase 5: Create cluster secrets ==="

kubectl create namespace voting --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# GHCR image pull secret
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username="${GHCR_USERNAME}" \
  --docker-password="${GITHUB_TOKEN}" \
  -n voting --dry-run=client -o yaml | kubectl apply -f -

# PostgreSQL password
kubectl create secret generic postgres-password \
  --from-literal=postgres-password="${POSTGRES_PASSWORD}" \
  -n voting --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic postgres-password \
  --from-literal=postgres-password="${POSTGRES_PASSWORD}" \
  -n keycloak --dry-run=client -o yaml | kubectl apply -f -

# Grafana OAuth client secret
kubectl create secret generic grafana-oauth-creds \
  --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="${GRAFANA_OAUTH_CLIENT_SECRET}" \
  -n monitoring --dry-run=client -o yaml | kubectl apply -f -

echo "=== Phase 6: Install ArgoCD ==="
if kubectl get ns argocd &>/dev/null && kubectl get deploy argocd-server -n argocd &>/dev/null; then
  echo "ArgoCD already installed"
else
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl wait --namespace argocd --for=condition=ready pod -l app.kubernetes.io/name=argocd-server --timeout=300s

  # Scale down non-essential
  kubectl scale deployment -n argocd argocd-dex-server --replicas=0 2>/dev/null || true
  kubectl scale deployment -n argocd argocd-applicationset-controller --replicas=0 2>/dev/null || true
  kubectl scale deployment -n argocd argocd-notifications-controller --replicas=0 2>/dev/null || true
fi

# ArgoCD repo secret (for private gitops repo)
kubectl create secret generic repo-voting-app-gitops \
  --from-literal=type=git \
  --from-literal=url="${GITOPS_REPO}" \
  --from-literal=username=ybojko \
  --from-literal=password="${GITHUB_TOKEN}" \
  -n argocd --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret repo-voting-app-gitops -n argocd argocd.argoproj.io/secret-type=repository --overwrite

echo "=== Phase 7: Deploy root-app-local (App-of-Apps) ==="
# Wait for ArgoCD to be fully ready
kubectl wait --namespace argocd --for=condition=ready pod -l app.kubernetes.io/name=argocd-application-controller --timeout=120s

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app-local
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GITOPS_REPO}
    targetRevision: master
    path: apps-local
    directory:
      recurse: true
      include: '*.yaml'
      exclude: 'root-app-local.yaml'
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

echo "=== Phase 8: Wait for sync ==="
echo "Waiting for root-app-local to sync..."
sleep 10

for i in {1..60}; do
  STATUS=$(kubectl get application root-app-local -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  HEALTH=$(kubectl get application root-app-local -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
  echo "[${i}/60] root-app-local: sync=${STATUS} health=${HEALTH}"
  if [ "${STATUS}" = "Synced" ] && [ "${HEALTH}" = "Healthy" ]; then
    break
  fi
  sleep 10
done

echo ""
echo "=== Waiting for LoadBalancer IP ==="
for i in {1..30}; do
  LB_IP=$(kubectl get svc envoy-proxy -n envoy-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [ -n "${LB_IP}" ]; then
    break
  fi
  echo "[${i}/30] Waiting for Envoy proxy LB IP..."
  sleep 5
done

if [ -z "${LB_IP}" ]; then
  echo "WARNING: Could not get LB IP. Using port-forward fallback."
fi

echo ""
echo "================================================================"
echo "  LOCAL CLUSTER READY"
echo "================================================================"
echo ""
echo "  ArgoCD:       https://localhost:8443  (admin / see below)"

ARGOCD_PASS=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "N/A")
echo "  Admin pass:   ${ARGOCD_PASS}"
echo ""

if [ -n "${LB_IP}" ]; then
  echo "  Vote:         http://vote.voting.local"
  echo "  Result:       http://result.voting.local"
  echo "  Grafana:      http://grafana.voting.local"
  echo "  Keycloak:     http://keycloak.voting.local"
  echo ""
  echo "  Add this line to your /etc/hosts (or use port-forwards below):"
  echo "  ${LB_IP} vote.voting.local result.voting.local grafana.voting.local keycloak.voting.local"
  echo ""
  echo "  Keycloak admin:  admin / (see keycloak-initial-admin secret in keycloak ns)"
  echo "  Keycloak user:   testuser / test1234"
else
  echo "  Run port-forwards to access services:"
  echo "  kubectl port-forward -n argocd svc/argocd-server 8443:443"
  echo "  kubectl port-forward -n envoy-gateway svc/envoy-proxy 8080:80"
fi

echo ""
echo "  To teardown: kind delete cluster --name ${CLUSTER_NAME}"
echo "================================================================"
