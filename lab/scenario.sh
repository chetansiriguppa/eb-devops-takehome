#!/usr/bin/env bash
# Debug lab driver — Enterprise Bot DevOps take-home, Part 4.
#
#   ./scenario.sh up       install the lab (cluster-state + broken chart)
#   ./scenario.sh verify   check the goal state; exit code = number of failures
#   ./scenario.sh reset    remove the lab completely (then `up` to start over)
#
# Requires: kubectl and helm pointed at a local cluster (kind or minikube).
# The same checks `verify` runs are the ones our grading harness runs — when
# this is green, that part of your submission is done.

set -u
cd "$(dirname "$0")"

NS=debug-lab
RELEASE=debug-lab

C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ${C_GREEN}PASS${C_OFF}  $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ${C_RED}FAIL${C_OFF}  $*"; }

up() {
  echo "==> applying cluster environment (cluster-state/)"
  kubectl apply -f cluster-state/
  echo "==> installing the broken chart"
  if ! helm upgrade --install "$RELEASE" ./broken-chart -n "$NS"; then
    echo ""
    echo "${C_DIM}helm reported an error. That is not your machine misbehaving —${C_OFF}"
    echo "${C_DIM}it is part of the exercise. Read the error; it is evidence.${C_OFF}"
  fi
  echo ""
  echo "Lab is (partially) installed. Investigate with kubectl, fix the chart,"
  echo "re-run './scenario.sh up' to apply your fixes, and './scenario.sh verify'"
  echo "to check progress."
}

# One throwaway busybox pod runs all in-cluster probes in a single pass.
incluster_probe() {
  kubectl -n "$NS" run eb-verify-probe --rm -i --restart=Never \
    --image=busybox:1.36 --quiet --pod-running-timeout=90s --command -- sh -c '
      wget -q -O- -T 4 http://backend:8080/healthz >/dev/null 2>&1 \
        && echo PROBE_BACKEND=ok || echo PROBE_BACKEND=fail
      GW=$(wget -q -O- -T 6 http://gateway.debug-lab.svc/status 2>/dev/null)
      echo "PROBE_GATEWAY_BODY=$GW"
      RP=$(wget -q -O- -T 6 http://reporter:8080/report 2>/dev/null)
      echo "PROBE_REPORTER_BODY=$RP"
      nslookup backend >/dev/null 2>&1 \
        && echo PROBE_DNS=ok || echo PROBE_DNS=fail
    ' 2>/dev/null
}

verify() {
  echo "==> verifying goal state in namespace $NS"

  # 1. migration Job ran to completion
  if [ "$(kubectl -n "$NS" get job migrate -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ]; then
    ok "migrate Job completed"
  else
    bad "migrate Job has not completed (does it exist? did the chart even install cleanly?)"
  fi

  # 2. every Deployment fully Ready
  for d in backend gateway worker reporter metrics; do
    want=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    have=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    if [ -n "$want" ] && [ "${have:-0}" = "$want" ]; then
      ok "deployment $d: $have/$want ready"
    else
      bad "deployment $d: ${have:-0}/${want:-?} ready"
    fi
  done

  # 3. nothing is crash-looping
  loops=$(kubectl -n "$NS" get pods \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
    | grep -c CrashLoopBackOff)
  if [ "${loops:-0}" -eq 0 ]; then
    ok "no pods in CrashLoopBackOff"
  else
    bad "$loops pod(s) in CrashLoopBackOff"
  fi

  # 4. the reporter ServiceAccount really may list pods
  if kubectl auth can-i list pods -n "$NS" \
      --as="system:serviceaccount:${NS}:reporter" >/dev/null 2>&1; then
    ok "ServiceAccount ${NS}/reporter can list pods"
  else
    bad "ServiceAccount ${NS}/reporter cannot list pods"
  fi

  # 5. in-cluster behaviour: backend serves, gateway aggregates, reporter reports
  probe=$(incluster_probe)
  case "$probe" in *PROBE_BACKEND=ok*) ok "backend answers on http://backend:8080/healthz";;
                   *) bad "backend does not answer on http://backend:8080/healthz";; esac
  case "$probe" in *'"backend":"ok"'*) ok "gateway /status reports backend=ok";;
                   *) bad "gateway /status does not report backend=ok";; esac
  if printf '%s' "$probe" | grep -q 'PROBE_REPORTER_BODY=.*"pods":[1-9]'; then
    ok "reporter /report sees pods in the namespace"
  else
    bad "reporter /report does not return a pod count"
  fi

  echo ""
  if [ "$FAIL" -eq 0 ]; then
    echo "${C_GREEN}ALL GREEN${C_OFF} — $PASS/$((PASS+FAIL)) checks passed. This part is done."
  else
    echo "${C_RED}$FAIL check(s) failing${C_OFF}, $PASS passing. Keep digging — every failure is a symptom."
  fi
  exit "$FAIL"
}

reset() {
  echo "==> removing the lab"
  helm uninstall "$RELEASE" -n "$NS" 2>/dev/null || true
  kubectl delete namespace "$NS" --ignore-not-found --wait=true
  echo "Removed. Note: this does NOT restore the chart files — use git for that."
}

case "${1:-}" in
  up)     up ;;
  verify) verify ;;
  reset)  reset ;;
  *) echo "usage: $0 up|verify|reset"; exit 2 ;;
esac
