#!/bin/bash
# Watch a detached triage run; exit 0 when it completes, 1 if it dies early.
# Only trusts log lines written AFTER this monitor started (logs are appended
# across reruns) and only watches the triage process for THIS label.
LOGF="$1"
LABEL=$(basename "$LOGF" .triage.log)
BASE=$(wc -l < "$LOGF" 2>/dev/null || echo 0)
new_lines() { tail -n +"$((BASE + 1))" "$LOGF" 2>/dev/null; }
alive() { pgrep -f "40_triage_carved.sh.*${LABEL}" >/dev/null 2>&1; }

for i in $(seq 1 1440); do   # up to 12h
  if new_lines | grep -q "sorted tree:"; then
    echo "=== TRIAGE COMPLETE $(date) ==="
    exit 0
  fi
  if ! alive; then
    sleep 15   # grace: distinguish between-passes gap from real death
    new_lines | grep -q "sorted tree:" && { echo "=== TRIAGE COMPLETE $(date) ==="; exit 0; }
    alive || { echo "=== TRIAGE PROCESS DIED $(date) ==="; tail -3 "$LOGF"; exit 1; }
  fi
  sleep 30
done
echo "=== TIMEOUT 12h ==="
exit 1
