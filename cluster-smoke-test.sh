#!/usr/bin/env bash
# Kubernetes cluster smoke test (also works with single-node Kind clusters).
# Requirements: Bash 4+, kubectl, python3, and a kubeconfig with cluster-admin access.
# Usage: ./cluster-smoke-test.sh [--keep] [--nodeport]
# --keep: retain this run's namespace for debugging.
# --nodeport: additionally test NodePort from this machine (requires curl and
#             connectivity to each node's InternalIP; often NOT available in Kind/WSL).
# Environment: TIMEOUT=180s IMAGE=busybox:1.36
# Exit codes: 0 = all executed checks passed; 1 = failure; 2 = usage/prerequisites.
set -Eeuo pipefail

KEEP=0
NODEPORT=0
CREATED=0
PASSES=0
NS="cluster-test-$(date +%s)-${RANDOM}"
TIMEOUT=${TIMEOUT:-180s}
IMAGE=${IMAGE:-busybox:1.36}

for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --nodeport) NODEPORT=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

for cmd in kubectl python3; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 2; }
done
if (( NODEPORT )); then
  command -v curl >/dev/null || { echo 'Missing dependency: curl' >&2; exit 2; }
fi

k() { kubectl --request-timeout=30s "$@"; }
n() { k -n "$NS" "$@"; }
pass() { PASSES=$((PASSES+1)); echo "[PASS] $*"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

cleanup() {
  local rc=$?
  trap - EXIT
  if (( CREATED )); then
    if (( rc != 0 )); then
      echo '[INFO] Test stopped. Diagnostics:' >&2
      n get pods -o wide >&2 || true
      n get svc -o wide >&2 || true
      n get endpointslices >&2 || true
      n get events --sort-by=.metadata.creationTimestamp >&2 || true
      n describe pods >&2 || true
    fi
    if (( KEEP )); then
      echo "Retained namespace: $NS"
      echo "Cleanup: kubectl delete namespace $NS"
    elif ! k delete namespace "$NS" --wait=false; then
      echo "[FAIL] Cleanup failed. Delete namespace $NS manually." >&2
      rc=1
    fi
  fi
  if (( rc == 0 )); then
    echo "RESULT: PASS ($PASSES checks). This is a smoke test, not full conformance."
  else
    echo "RESULT: FAIL (exit $rc; $PASSES checks passed)." >&2
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'echo "[FAIL] Unexpected command error at line $LINENO: $BASH_COMMAND" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Context: $(k config current-context)"
echo "Namespace: $NS"
echo 'Using current kubeconfig; existing workloads and node settings are not modified.'
k get --raw=/readyz
echo
pass 'API server ready'

# Ensure every node is Ready; distinguish unhealthy from deliberately excluded.
NODES=$(k get nodes -o json)
printf '%s' "$NODES" | python3 -c '
import json, sys
nodes = json.load(sys.stdin)["items"]
if not nodes:
    sys.exit("[FAIL] No nodes found")
bad = [n["metadata"]["name"] for n in nodes if not any(
    c["type"] == "Ready" and c["status"] == "True"
    for c in n["status"].get("conditions", [])
)]
if bad:
    sys.exit("[FAIL] Nodes not Ready: " + ", ".join(bad))
print("Ready nodes: " + ", ".join(n["metadata"]["name"] for n in nodes))
'
pass 'All nodes Ready'

# DaemonSet test targets Ready nodes that are uncordoned and have no blocking taints.
ELIGIBLE=$(printf '%s' "$NODES" | python3 -c '
import json, sys
for node in json.load(sys.stdin)["items"]:
    reasons = []
    if node.get("spec", {}).get("unschedulable"):
        reasons.append("cordoned")
    if any(t.get("effect") in ("NoSchedule", "NoExecute")
           for t in node.get("spec", {}).get("taints", [])):
        reasons.append("tainted")
    if reasons:
        print("[SKIP] " + node["metadata"]["name"] + ": " + ", ".join(reasons), file=sys.stderr)
    else:
        print(node["metadata"]["name"])
')
[[ -n "$ELIGIBLE" ]] || fail 'No eligible nodes for ordinary workloads.'
EXPECTED=$(printf '%s\n' "$ELIGIBLE" | wc -l | tr -d ' ')

k create namespace "$NS"
CREATED=1

# Run a small HTTP server on each eligible node.
# Use scheduler placement; restrict to known eligible node names via affinity.
n apply -f - <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: net-test
spec:
  selector:
    matchLabels: {app: net-test}
  template:
    metadata:
      labels: {app: net-test}
    spec:
      terminationGracePeriodSeconds: 1
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchFields:
              - key: metadata.name
                operator: In
                values:
$(printf '%s\n' "$ELIGIBLE" | sed 's/^/                - /')
      containers:
      - name: web
        image: $IMAGE
        command: [sh, -c]
        args: ['mkdir -p /tmp/www; hostname > /tmp/www/index.html; exec httpd -f -p 8080 -h /tmp/www']
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet: {path: /, port: 8080}
          initialDelaySeconds: 1
          periodSeconds: 2
        resources:
          requests: {cpu: 10m, memory: 16Mi}
          limits: {memory: 64Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector: {app: net-test}
  ports:
  - port: 80
    targetPort: 8080
YAML

n rollout status daemonset/net-test --timeout="$TIMEOUT"
PODS=$(n get pods -l app=net-test -o json)
ROWS=$(printf '%s' "$PODS" | python3 -c '
import json, sys
for pod in json.load(sys.stdin)["items"]:
    if not pod["metadata"].get("deletionTimestamp"):
        print(pod["metadata"]["name"], pod["spec"]["nodeName"], pod["status"].get("podIP", ""))
')
ACTUAL=$(printf '%s\n' "$ROWS" | wc -l | tr -d ' ')
[[ "$ACTUAL" == "$EXPECTED" ]] || fail "Expected $EXPECTED test pods, found $ACTUAL."
n get pods -o wide
pass "Image pull, scheduling and HTTP readiness on $EXPECTED eligible node(s)"

SERVICE_IP=$(n get svc web -o jsonpath='{.spec.clusterIP}')
[[ -n "$SERVICE_IP" && "$SERVICE_IP" != None ]] || fail 'web Service has no ClusterIP.'
# Kind uses the standard Kubernetes cluster domain, cluster.local.
# The trailing dot makes this an absolute DNS name (no search-suffix expansion).
DNS_NAME="web.${NS}.svc.cluster.local."

# BusyBox nslookup may return exit status 1 even after showing a valid A-record
# answer when additional search candidates fail. Check the actual returned
# Service IP instead of relying on the nslookup process status.
dns_check() {
  local client=$1 attempt output rc
  for attempt in {1..10}; do
    rc=0
    output=$(n exec "$client" -- nslookup "$DNS_NAME" 2>&1) || rc=$?
    if printf '%s\n' "$output" | grep -Fq -- "$SERVICE_IP"; then
      return 0
    fi
    if (( attempt == 10 )); then
      echo "[FAIL] DNS lookup did not return expected Service IP $SERVICE_IP (exit status $rc):" >&2
      printf '%s\n' "$output" >&2
      echo '[INFO] Pod /etc/resolv.conf:' >&2
      n exec "$client" -- cat /etc/resolv.conf >&2 || true
      return 1
    fi
    sleep 2
  done
}

# HTTP test retries also allow Service EndpointSlice / kube-proxy convergence.
# Expected direct requests return the target pod name; Service requests must
# return any known test pod name.
http_check() {
  local client=$1 url=$2 expected=${3:-} result attempt
  for attempt in {1..10}; do
    if result=$(n exec "$client" -- wget -T 5 -qO- "$url" 2>&1); then
      if [[ -n "$expected" ]]; then
        [[ "$result" == "$expected" ]] && return 0
      elif printf '%s\n' "$ROWS" | awk '{print $1}' | grep -Fxq -- "$result"; then
        return 0
      fi
    fi
    sleep 2
  done
  echo "[FAIL] HTTP request from $client to $url failed or returned an unexpected response:" >&2
  printf '%s\n' "$result" >&2
  return 1
}

# Check DNS, all ordered Pod-IP paths (including self), Service IP and short name.
while read -r client source_node source_ip; do
  [[ -n "$client" ]] || continue
  dns_check "$client" || fail "DNS from $source_node"
  pass "DNS from $source_node"

  while read -r server dest_node dest_ip; do
    [[ -n "$server" ]] || continue
    [[ -n "$dest_ip" ]] || fail "Missing Pod IP for $server"
    if [[ "$dest_ip" == *:* ]]; then dest_ip="[$dest_ip]"; fi
    http_check "$client" "http://$dest_ip:8080" "$server" || fail "Direct HTTP: $source_node -> $dest_node"
    pass "Direct HTTP: $source_node -> $dest_node"
  done <<< "$ROWS"

  SERVICE_URL_IP=$SERVICE_IP
  [[ "$SERVICE_URL_IP" == *:* ]] && SERVICE_URL_IP="[$SERVICE_URL_IP]"
  http_check "$client" "http://$SERVICE_URL_IP" || fail "Service IP HTTP from $source_node"
  http_check "$client" 'http://web' || fail "Service short-name HTTP from $source_node"
  pass "Service IP and short-name HTTP from $source_node"
done <<< "$ROWS"

if (( EXPECTED < 2 )); then
  echo '[SKIP] Cross-node networking (fewer than two eligible nodes; expected for single-node Kind).'
fi

# Verify that a Deployment recreates a deleted replica.
n create deployment recovery --image="$IMAGE" --replicas=2 -- sleep 3600
n rollout status deployment/recovery --timeout="$TIMEOUT"
OLD=$(n get pods -l app=recovery -o jsonpath='{.items[0].metadata.name}')
[[ -n "$OLD" ]] || fail 'No recovery pod found.'
n delete pod "$OLD" --wait=true --timeout="$TIMEOUT"
n rollout status deployment/recovery --timeout="$TIMEOUT"
RECOVERY_OK=0
for attempt in {1..60}; do
  if n get pods -l app=recovery -o json | python3 -c '
import json, sys
old = sys.argv[1]
pods = [p for p in json.load(sys.stdin)["items"] if not p["metadata"].get("deletionTimestamp")]
assert len(pods) == 2, "Expected exactly two pods"
assert all(p["metadata"]["name"] != old for p in pods), "Old pod remains"
assert all(any(c["type"] == "Ready" and c["status"] == "True"
               for c in p["status"].get("conditions", [])) for p in pods), "Pods not Ready"
' "$OLD" 2>/dev/null; then
    RECOVERY_OK=1
    break
  fi
  sleep 2
done
[[ "$RECOVERY_OK" == 1 ]] || fail 'Deployment did not restore two Ready replicas after deletion.'
pass 'Deployment restored two Ready replicas after pod deletion'

if (( NODEPORT )); then
  n patch svc web -p '{"spec":{"type":"NodePort"}}'
  PORT=$(n get svc web -o jsonpath='{.spec.ports[0].nodePort}')
  while read -r node; do
    [[ -n "$node" ]] || continue
    IP=$(k get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')
    [[ -n "$IP" ]] || fail "Missing InternalIP for $node"
    [[ "$IP" == *:* ]] && IP="[$IP]"
    RESPONSE=$(curl --noproxy '*' --fail --silent --show-error --connect-timeout 5 --max-time 10 --retry 3 --retry-delay 1 "http://$IP:$PORT") || fail "NodePort unreachable from this host: $node:$PORT"
    printf '%s\n' "$ROWS" | awk '{print $1}' | grep -Fxq -- "$RESPONSE" || fail "Unexpected NodePort response from $node"
    pass "NodePort from script host -> $node:$PORT"
  done <<< "$ELIGIBLE"
else
  echo '[SKIP] External/NodePort access (optional --nodeport; Kind/WSL host routing may prevent it).'
fi

echo '[SKIP] Storage, ingress, NetworkPolicy, upgrades, and node/control-plane failure recovery are outside this smoke test.'
