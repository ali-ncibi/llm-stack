#!/usr/bin/env bash
# Load test for the llm-stack demo.
#   ./loadtest/run.sh   
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG="${KUBECONFIG:-$PWD/config.yml}"

D="loadtest/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$D"
URL="$(./stack.sh url)"
echo "target: $URL  |  artifacts: $D"

TOKEN="$(curl -s -m 15 -X POST "$URL/api/v1/auths/signin" -H 'Content-Type: application/json' \
  -d '{"email":"admin@demo.local","password":"DemoPass123!"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
echo "got auth token"

prom() { 
  kubectl exec -n llm-stack deploy/prometheus -- wget -qO- -T 10 \
    "http://localhost:9090/api/v1/query?query=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$1")" 2>/dev/null \
  | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin); r = d["data"]["result"]; print(r[0]["value"][1] if r else "NaN")
except Exception:
    print("NaN")'
}

watch() {
  echo "ts,running,waiting,keda_trigger,success_rate_1m,kv_usage,ttft_p95,e2e_p95,vllm_replicas,openwebui_replicas,pending_pods,nodes" > "$D/metrics.csv"
  while true; do
    ts=$(date +%s)
    run=$(prom 'sum(vllm:num_requests_running)')
    wai=$(prom 'sum(vllm:num_requests_waiting)')
    trig=$(prom 'sum(vllm:num_requests_running) + sum(vllm:num_requests_waiting)')
    succ=$(prom 'sum(rate(vllm:request_success_total[1m]))')
    kv=$(prom 'max(vllm:kv_cache_usage_perc)')
    ttft=$(prom 'histogram_quantile(0.95, sum by (le) (rate(vllm:time_to_first_token_seconds_bucket[2m])))')
    e2e=$(prom 'histogram_quantile(0.95, sum by (le) (rate(vllm:e2e_request_latency_seconds_bucket[2m])))')
    vrep=$(prom 'kube_deployment_status_replicas{namespace="llm-stack",deployment="vllm"}')
    orep=$(prom 'kube_deployment_status_replicas{namespace="llm-stack",deployment="openwebui"}')
    pend=$(prom 'sum(kube_pod_status_phase{namespace="llm-stack",phase="Pending"})')
    nodes=$(prom 'count(kube_node_info)')
    echo "$ts,$run,$wai,$trig,$succ,$kv,$ttft,$e2e,$vrep,$orep,$pend,$nodes" >> "$D/metrics.csv"
    {
      echo "=== $(date -Iseconds)"
      kubectl get pods -n llm-stack --no-headers
      echo "--- hpa:"; kubectl get hpa -n llm-stack --no-headers
      echo "--- scaledobject:"; kubectl get scaledobject -n llm-stack --no-headers
    } >> "$D/watch.log"
    sleep 15
  done
}

phase() {
  local name=$1 c=$2 dur=$3
  echo "### phase $name: concurrency=$c duration=${dur}s start=$(date -Iseconds)"
  if [ "$c" -gt 0 ]; then
    python3 loadtest/gen.py --url "$URL/api/chat/completions" --token "$TOKEN" \
      --concurrency "$c" --duration "$dur" --max-tokens 16 --prompt "hi" \
      --out "$D/$name.json" | tee -a "$D/phases.log"
  else
    sleep "$dur"
    echo "{\"phase\":\"$name\",\"concurrency\":0,\"duration_s\":$dur,\"note\":\"idle/baseline\"}" | tee -a "$D/phases.log"
  fi
  echo "### phase $name done end=$(date -Iseconds)"
}

watch &
WATCH_PID=$!
trap 'kill $WATCH_PID 2>/dev/null || true' EXIT

PHASES="${PHASES:-baseline:0:90 p1-light:4:180 p2-medium:12:240 p3-heavy:24:240 p4-cooldown:0:240}"
for ph in $PHASES; do
  IFS=: read -r name c dur <<< "$ph"
  phase "$name" "$c" "$dur"
done

kubectl get events -n llm-stack --sort-by=.lastTimestamp > "$D/events.txt"
kubectl get pods -n llm-stack -o wide > "$D/pods-final.txt"
kubectl get nodes -o wide > "$D/nodes-final.txt"
echo "DONE. artifacts in $D"
