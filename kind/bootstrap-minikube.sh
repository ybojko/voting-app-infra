#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "ERROR: .env file not found at ${ENV_FILE}"
  echo "Copy .env.example to .env and fill in values:"
  echo "  cp ${SCRIPT_DIR}/.env.example ${ENV_FILE}"
  exit 1
fi

source "${ENV_FILE}"

CLUSTER_NAME="voting-app-local"
GITOPS_REPO="https://github.com/ybojko/voting-app-gitops.git"
GATEWAY_API_VERSION="v1.2.0"
ENVOY_GATEWAY_VERSION="v1.2.0"
CERT_MANAGER_VERSION="v1.16.5"

echo "=== Phase 1: Start minikube ==="
MINIKUBE_STATUS=$(minikube status -p "${CLUSTER_NAME}" --format='{{.Host}}' 2>/dev/null || echo "Stopped")

if [ "${MINIKUBE_STATUS}" = "Running" ]; then
  echo "Minikube cluster ${CLUSTER_NAME} already running"
else
  minikube start \
    -p "${CLUSTER_NAME}" \
    --cpus=3 \
    --memory=6144 \
    --kubernetes-version=v1.31.0 \
    --addons=ingress \
    --addons=metrics-server
  echo "Minikube cluster started"
fi

kubectl config use-context "${CLUSTER_NAME}"

echo "=== Phase 2: Install Gateway API CRDs + Envoy Gateway ==="
if kubectl get gatewayclass eg &>/dev/null 2>&1; then
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

echo "=== Phase 3: Install cert-manager (self-signed) ==="
if kubectl get ns cert-manager &>/dev/null 2>&1; then
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

  kubectl create namespace voting --dry-run=client -o yaml | kubectl apply -f -

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
  commonName: "*.voting.local"
  dnsNames:
    - "*.voting.local"
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
EOF

  kubectl wait --for=condition=ready certificate local-tls -n voting --timeout=60s
  echo "Self-signed cert-manager installed"
fi

echo "=== Phase 4: Create cluster secrets ==="
kubectl create namespace voting --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username="${GHCR_USERNAME}" \
  --docker-password="${GITHUB_TOKEN}" \
  -n voting --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic postgres-password \
  --from-literal=postgres-password="${POSTGRES_PASSWORD}" \
  -n voting --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic postgres-password \
  --from-literal=postgres-password="${POSTGRES_PASSWORD}" \
  -n keycloak --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic grafana-oauth-creds \
  --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="${GRAFANA_OAUTH_CLIENT_SECRET}" \
  -n monitoring --dry-run=client -o yaml | kubectl apply -f -

echo "=== Phase 5: Install ArgoCD ==="
if kubectl get deploy argocd-server -n argocd &>/dev/null 2>&1; then
  echo "ArgoCD already installed"
else
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl wait --namespace argocd --for=condition=ready pod -l app.kubernetes.io/name=argocd-server --timeout=300s

  kubectl scale deployment -n argocd argocd-dex-server --replicas=0 2>/dev/null || true
  kubectl scale deployment -n argocd argocd-applicationset-controller --replicas=0 2>/dev/null || true
  kubectl scale deployment -n argocd argocd-notifications-controller --replicas=0 2>/dev/null || true
fi

kubectl create secret generic repo-voting-app-gitops \
  --from-literal=type=git \
  --from-literal=url="${GITOPS_REPO}" \
  --from-literal=username=ybojko \
  --from-literal=password="${GITHUB_TOKEN}" \
  -n argocd --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret repo-voting-app-gitops -n argocd argocd.argoproj.io/secret-type=repository --overwrite

echo "=== Phase 6: Deploy root-app-local ==="
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

echo "=== Phase 7: Wait for sync ==="
sleep 10

for i in $(seq 1 60); do
  STATUS=$(kubectl get application root-app-local -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  HEALTH=$(kubectl get application root-app-local -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
  echo "[${i}/60] root-app-local: sync=${STATUS} health=${HEALTH}"
  if [ "${STATUS}" = "Synced" ] && [ "${HEALTH}" = "Healthy" ]; then
    break
  fi
  sleep 10
done

echo ""
echo "=== Phase 8: Start minikube tunnel (LB IP) ==="
echo ""
echo "OPEN A SEPARATE TERMINAL and run:"
echo "  minikube tunnel -p ${CLUSTER_NAME}"
echo ""
echo "This gives the Envoy Gateway Service a routable IP."
echo "Keep it running while you use the cluster."
echo ""

echo "=== Waiting for LoadBalancer IP (tunnel must be running) ==="
for i in $(seq 1 30); do
  LB_IP=$(kubectl get svc envoy-proxy -n envoy-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [ -n "${LB_IP}" ]; then
    break
  fi
  echo "[${i}/30] Waiting for tunnel to assign LB IP..."
  sleep 5
done

if [ -n "${LB_IP}" ]; then
  echo ""
  echo "================================================================"
  echo "  CLUSTER READY"
  echo "================================================================"
  echo ""
  echo "  Add to C:\\Windows\\System32\\drivers\\etc\\hosts (as admin):"
  echo "  ${LB_IP} vote.voting.local result.voting.local grafana.voting.local keycloak.voting.local"
  echo ""
  echo "  Vote:     http://vote.voting.local"
  echo "  Result:   http://result.voting.local"
  echo "  Grafana:  http://grafana.voting.local"
  echo "  Keycloak: http://keycloak.voting.local"
  echo ""
  echo "  Keycloak admin: admin / (get from: kubectl get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d)"
  echo "  Keycloak user:  testuser / test1234"
else
  echo ""
  echo "================================================================"
  echo "  CLUSTER READY (NO LB IP)"
  echo "================================================================"
  echo ""
  echo "  Run minikube tunnel in another terminal first, then:"
  echo ""
  echo "  ArgoCD:    kubectl port-forward -n argocd svc/argocd-server 8443:443"
  echo "  Vote:      kubectl port-forward -n voting svc/vote 8080:80"
  echo "  Result:    kubectl port-forward -n voting svc/result 8081:80"
  echo "  Grafana:   kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80"
  echo "  Keycloak:  kubectl port-forward -n keycloak svc/keycloak 8082:8080"
fi

echo ""
echo "  ArgoCD:    http://localhost:8443"
ARGOCD_PASS=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "N/A")
echo "  ArgoCD admin pass: ${ARGOCD_PASS}"
echo ""
echo "  To teardown: minikube delete -p ${CLUSTER_NAME}"
echo "================================================================"
