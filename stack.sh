#!/usr/bin/env bash
# One-command setup for the llm-stack demo on an OVH MKS cluster.
#   ./stack.sh            full setup until apply: KEDA (if missing) -> secrets -> secret -> stack.yaml
#   ./stack.sh url        print the public OpenWebUI URL (waits for the LoadBalancer IP)
#   ./stack.sh check      watch until all llm-stack pods are 1/1, then print the URL
#   ./stack.sh status     show pods and services in llm-stack
#   ./stack.sh secrets    force-regenerate secrets.env
set -euo pipefail
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-$PWD/config.yml}"

NS=llm-stack
MANIFESTS=manifests/stack.yaml

gen_secrets() {
  local pw sk gp
  pw="$(openssl rand -hex 32)"
  sk="$(openssl rand -hex 48)"
  gp="$(openssl rand -hex 24)"
  cat > secrets.env <<EOF
POSTGRES_PASSWORD=${pw}
DATABASE_URL=postgresql://openwebui:${pw}@postgres:5432/openwebui
REDIS_URL=redis://redis:6379/0
WEBUI_SECRET_KEY=${sk}
GRAFANA_ADMIN_PASSWORD=${gp}
EOF
  chmod 600 secrets.env
  echo "generated secrets.env (gitignored, mode 600)"
}

ensure_keda() {
  if kubectl get crd scaledobjects.keda.sh >/dev/null 2>&1; then
    echo "keda: already installed"
  else
    echo "keda: installing (required for the ScaledObject in stack.yaml)..."
    helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
    helm repo update >/dev/null
    helm install keda kedacore/keda --namespace keda --create-namespace >/dev/null
    echo "keda: installed"
  fi
}

ensure_secret() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if [ ! -f secrets.env ]; then
    gen_secrets
  else
    echo "secrets.env exists, reusing it ('./stack.sh secrets' to regenerate)"
  fi
  kubectl create secret generic llm-secrets -n "$NS" \
    --from-env-file=secrets.env --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "secret llm-secrets: applied"
}

check() {
  local timeout="${LLM_CHECK_TIMEOUT:-900}" waited=0 total ready line
  echo "waiting for all pods in $NS to be 1/1 (timeout ${timeout}s)..."
  while [ "$waited" -lt "$timeout" ]; do
    line="$(kubectl get pods -n "$NS" --no-headers 2>/dev/null || true)"
    total="$(echo "$line" | grep -c . || true)"
    ready="$(echo "$line" | awk '{split($2,a,"/"); if ($3=="Running" && a[1]==a[2]) c++} END{print c+0}')"
    echo "  ${ready}/${total} pods ready"
    if [ "$total" -gt 0 ] && [ "$ready" -eq "$total" ]; then
      echo "all pods ready."
      public_url || true
      return 0
    fi
    echo "$line" | awk '{split($2,a,"/"); if ($3!="Running" || a[1]!=a[2]) print "  not ready: "$1" ("$2" "$3")"}'
    sleep 10; waited=$((waited + 10))
  done
  echo "timed out after ${timeout}s — inspect with: kubectl get pods -n $NS" >&2
  return 1
}

public_url() {
  local ip i
  for i in $(seq 1 36); do
    ip="$(kubectl get svc -n "$NS" openwebui -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [ -n "$ip" ]; then echo "http://$ip"; return 0; fi
    sleep 5
  done
  echo "openwebui LoadBalancer IP still pending — run './stack.sh url' again in a minute" >&2
  return 1
}

case "${1:-up}" in
  up)
    ensure_keda
    ensure_secret
    kubectl apply -f "$MANIFESTS"
    echo
    echo "applied. next:"
    echo "  ./stack.sh check                  # watch until all pods 1/1 (vllm downloads the model on first boot)"
    echo "  ./stack.sh url                    # public OpenWebUI URL"
    echo "  ./dash.sh                       # kubernetes dashboard at https://localhost:8443"
    ;;
  url) public_url ;;
  check) check ;;
  status) kubectl get pods,svc -n "$NS" ;;
  secrets)
    echo "WARNING: on an existing cluster this desyncs POSTGRES_PASSWORD unless you"
    echo "also delete the postgres-data PVC first. Regenerate? [y/N]"
    read -r ans
    if [ "${ans:-}" = "y" ]; then gen_secrets; else echo "kept existing secrets.env"; fi
    ;;
  *) echo "usage: $0 [up|url|check|status|secrets]" >&2; exit 1 ;;
esac
