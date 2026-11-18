#!/usr/bin/env bash
# One-command Kubernetes Dashboard access for this demo cluster.
#   ./dash.sh          start port-forward + print login URL and a fresh token
#   ./dash.sh token    print a fresh short-lived token only
#   ./dash.sh stop     stop the port-forward
set -euo pipefail
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-$PWD/config.yml}"

NS=kubernetes-dashboard
PORT=8443
PIDFILE=.dash.pid
TOKENFILE=.dash-token

fresh_token() {
  kubectl apply -f manifests/dash.yaml >/dev/null
  local t
  t="$(kubectl -n "$NS" create token admin-user --duration=12h)"
  echo "$t" > "$TOKENFILE"
  chmod 600 "$TOKENFILE"
  echo "$t"
}

case "${1:-open}" in
  token)
    fresh_token
    ;;
  stop)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      kill "$(cat "$PIDFILE")" && rm -f "$PIDFILE" && echo "port-forward stopped"
    else
      rm -f "$PIDFILE"; echo "no port-forward running"
    fi
    ;;
  open)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "port-forward already running (pid $(cat "$PIDFILE"))"
    else
      nohup kubectl -n "$NS" port-forward svc/kubernetes-dashboard "$PORT:443" >/dev/null 2>&1 &
      echo $! > "$PIDFILE"
      sleep 2
      echo "port-forward started (pid $(cat "$PIDFILE"))"
    fi
    T="$(fresh_token)"
    echo
    echo "Dashboard URL:  https://localhost:$PORT"
    echo "Login option 1: 'Kubeconfig' -> select ./config.yml (no token needed)"
    echo "Login option 2: 'Token' -> paste this (valid 12h, also saved in .dash-token):"
    echo "$T"
    ;;
  *)
    echo "usage: $0 [open|token|stop]" >&2; exit 1 ;;
esac
