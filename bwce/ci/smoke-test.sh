#!/usr/bin/env bash
# After a Helm deploy: wait for the rollout, then call /_ping/ on every pod from
# a throwaway curl pod inside the namespace and require "Application is running"
# (Kubernetes probes only see the HTTP status, not the Impaired/StartFailed body).
#
# Usage: ./ci/smoke-test.sh <helm-release> <namespace>
# Env:   CURL_IMAGE (default curlimages/curl:8.10.1), HEALTH_PORT (default 7777)
set -euo pipefail

[[ $# -eq 2 ]] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
release="$1"; ns="$2"
curl_image="${CURL_IMAGE:-curlimages/curl:8.10.1}"
port="${HEALTH_PORT:-7777}"
sel="app.kubernetes.io/instance=$release"

deploy="$(kubectl -n "$ns" get deploy -l "$sel" -o name | head -n1)"
[[ -n "$deploy" ]] || { echo "ERROR: no Deployment with $sel in $ns" >&2; exit 1; }
kubectl -n "$ns" rollout status "$deploy" --timeout=10m

ips="$(kubectl -n "$ns" get pods -l "$sel" --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.status.podIP}{" "}{end}')"
[[ -n "${ips// }" ]] || { echo "ERROR: no running pods for $release" >&2; exit 1; }

# shellcheck disable=SC2016  # $ip/$body expand inside the curl pod
script='rc=0; for ip in '"$ips"'; do
  body=$(curl -s -m 10 http://$ip:'"$port"'/_ping/); echo "$ip: $body"
  case "$body" in *"Application is running"*) ;; *) rc=1 ;; esac
done; exit $rc'

pod="smoke-${release}-$(date +%s)"
kubectl -n "$ns" run "$pod" --image="$curl_image" --restart=Never --rm -i --quiet \
  --labels=app.kubernetes.io/managed-by=bwce-ci --command -- sh -c "$script"
echo "Smoke test passed for $release"
