#!/usr/bin/env bash
# mtv-migration-stats.sh
# Extracts completed migration timings from MTV and calculates per-GB metrics
# Usage: ./mtv-migration-stats.sh [-n NAMESPACE] [-o format]
#   -n  MTV namespace (default: openshift-mtv)
#   -o  output format: table (default) | csv | json

set -euo pipefail

MTV_NS="openshift-mtv"
OUTPUT="table"

while getopts "n:o:" opt; do
  case $opt in
    n) MTV_NS="$OPTARG" ;;
    o) OUTPUT="$OPTARG" ;;
    *) echo "Usage: $0 [-n namespace] [-o table|csv|json]"; exit 1 ;;
  esac
done

for cmd in oc jq bc; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: '$cmd' not found."; exit 1; }
done

echo "[INFO] Collecting migrations in namespace '$MTV_NS'..." >&2

MIGRATIONS_JSON=$(oc get migration -n "$MTV_NS" -o json 2>/dev/null)

# Phase is determined by .status.conditions[type=Succeeded, status=True]
COMPLETED=$(echo "$MIGRATIONS_JSON" | jq '[
  .items[] |
  select(
    .status.conditions[]? |
    .type == "Succeeded" and .status == "True"
  )
]')

COUNT=$(echo "$COMPLETED" | jq 'length')

if [[ "$COUNT" -eq 0 ]]; then
  echo "[WARN] No migrations with Succeeded=True found in '$MTV_NS'." >&2
  exit 0
fi

echo "[INFO] $COUNT completed migration(s) found." >&2

iso_to_epoch() {
  date -d "$1" +%s 2>/dev/null || python3 -c "
import sys, datetime
s = sys.argv[1].replace('Z','+00:00')
print(int(datetime.datetime.fromisoformat(s).timestamp()))
" "$1"
}

duration_min() {
  local s="$1" e="$2"
  [[ -z "$s" || -z "$e" ]] && echo "N/A" && return
  local es ee
  es=$(iso_to_epoch "$s")
  ee=$(iso_to_epoch "$e")
  echo "scale=2; ($ee - $es) / 60" | bc
}

RESULTS=()

while IFS= read -r migration; do
  MIGRATION_NAME=$(echo "$migration" | jq -r '.metadata.name')
  PLAN_NAME=$(echo "$migration" | jq -r '.spec.plan.name // "N/A"')
  MIG_STARTED=$(echo "$migration" | jq -r '.status.started // empty')
  MIG_COMPLETED=$(echo "$migration" | jq -r '.status.completed // empty')
  TOTAL_MIN=$(duration_min "$MIG_STARTED" "$MIG_COMPLETED")

  while IFS= read -r vm; do
    VM_NAME=$(echo "$vm" | jq -r '.name // "unknown"')

    # DiskTransfer: initial transfer from VMware (unit MB in .progress.total)
    DT=$(echo "$vm" | jq -c '.pipeline[]? | select(.name == "DiskTransfer")')
    DT_START=$(echo "$DT" | jq -r '.started // empty')
    DT_END=$(echo "$DT"   | jq -r '.completed // empty')
    DT_MIN=$(duration_min "$DT_START" "$DT_END")
    DISK_MB=$(echo "$DT"  | jq -r '.progress.total // 0')
    DISK_GB=$(echo "scale=2; $DISK_MB / 1024" | bc)

    # ImageConversion: virt-v2v
    IC=$(echo "$vm" | jq -c '.pipeline[]? | select(.name == "ImageConversion")')
    IC_START=$(echo "$IC" | jq -r '.started // empty')
    IC_END=$(echo "$IC"   | jq -r '.completed // empty')
    IC_MIN=$(duration_min "$IC_START" "$IC_END")

    # DiskTransferV2v: post-conversion copy to PVC
    DTV=$(echo "$vm" | jq -c '.pipeline[]? | select(.name == "DiskTransferV2v")')
    DTV_START=$(echo "$DTV" | jq -r '.started // empty')
    DTV_END=$(echo "$DTV"   | jq -r '.completed // empty')
    DTV_MIN=$(duration_min "$DTV_START" "$DTV_END")

    # GB/min rate based on DiskTransfer
    RATE="N/A"
    if [[ "$DISK_GB" != "0" && "$DT_MIN" != "N/A" && "$DT_MIN" != "0" ]]; then
      RATE=$(echo "scale=3; $DISK_GB / $DT_MIN" | bc)
    fi

    # Minutes per GB (total migration time)
    MIN_PER_GB="N/A"
    if [[ "$DISK_GB" != "0" && "$TOTAL_MIN" != "N/A" ]]; then
      MIN_PER_GB=$(echo "scale=3; $TOTAL_MIN / $DISK_GB" | bc)
    fi

    RESULTS+=("${MIGRATION_NAME}|${PLAN_NAME}|${VM_NAME}|${TOTAL_MIN}|${DT_MIN}|${IC_MIN}|${DTV_MIN}|${DISK_GB}|${RATE}|${MIN_PER_GB}")
  done < <(echo "$migration" | jq -c '.status.vms[]? // empty')

done < <(echo "$COMPLETED" | jq -c '.[]')

# --- Output ---
HEADER="MIGRATION|PLAN|VM|TOTAL_MIN|DISK_XFER_MIN|CONV_MIN|XFER_V2V_MIN|DISK_GB|GB_PER_MIN|MIN_PER_GB"

case "$OUTPUT" in
  csv)
    echo "$HEADER"
    for r in "${RESULTS[@]}"; do echo "$r"; done
    ;;
  json)
    echo "["
    LAST=$((${#RESULTS[@]} - 1))
    for i in "${!RESULTS[@]}"; do
      IFS='|' read -r MIG PLAN VM TOTAL DT IC DTV GB RATE MPG <<< "${RESULTS[$i]}"
      COMMA=","; [[ $i -eq $LAST ]] && COMMA=""
      printf '  {"migration":"%s","plan":"%s","vm":"%s","total_min":%s,"disk_xfer_min":"%s","conv_min":"%s","xfer_v2v_min":"%s","disk_gb":%s,"gb_per_min":"%s","min_per_gb":"%s"}%s\n' \
        "$MIG" "$PLAN" "$VM" "$TOTAL" "$DT" "$IC" "$DTV" "$GB" "$RATE" "$MPG" "$COMMA"
    done
    echo "]"
    ;;
  table|*)
    echo ""
    printf "%-28s %-22s %-20s %10s %13s %10s %13s %9s %10s %10s\n" \
      "MIGRATION" "PLAN" "VM" "TOTAL_MIN" "DISK_XFER_MIN" "CONV_MIN" "XFER_V2V_MIN" "DISK_GB" "GB/MIN" "MIN/GB"
    printf '%0.s-' {1..155}; echo ""

    for r in "${RESULTS[@]}"; do
      IFS='|' read -r MIG PLAN VM TOTAL DT IC DTV GB RATE MPG <<< "$r"
      printf "%-28s %-22s %-20s %10s %13s %10s %13s %9s %10s %10s\n" \
        "$MIG" "$PLAN" "$VM" "$TOTAL" "$DT" "$IC" "$DTV" "$GB" "$RATE" "$MPG"
    done
    echo ""

    # Summary min/GB
    VALID_MPG=()
    for r in "${RESULTS[@]}"; do
      IFS='|' read -r _ _ _ _ _ _ _ _ _ MPG <<< "$r"
      [[ "$MPG" != "N/A" && -n "$MPG" ]] && VALID_MPG+=("$MPG")
    done

    if [[ ${#VALID_MPG[@]} -gt 0 ]]; then
      SUM=0; MIN_VAL="${VALID_MPG[0]}"; MAX_VAL="${VALID_MPG[0]}"
      for v in "${VALID_MPG[@]}"; do
        SUM=$(echo "$SUM + $v" | bc)
        (( $(echo "$v < $MIN_VAL" | bc -l) )) && MIN_VAL="$v"
        (( $(echo "$v > $MAX_VAL" | bc -l) )) && MAX_VAL="$v"
      done
      AVG=$(echo "scale=3; $SUM / ${#VALID_MPG[@]}" | bc)
      echo "=== SUMMARY (min/GB) ============================"
      printf "  Samples  : %s VMs\n" "${#VALID_MPG[@]}"
      printf "  Average  : %s min/GB\n" "$AVG"
      printf "  Minimum  : %s min/GB\n" "$MIN_VAL"
      printf "  Maximum  : %s min/GB\n" "$MAX_VAL"
      echo ""
      echo "=== ESTIMATES (based on average) ==============="
      for gb in 50 100 200 500; do
        MIN_EST=$(echo "scale=1; $AVG * $gb" | bc)
        H_EST=$(echo "scale=1; $MIN_EST / 60" | bc)
        printf "  %4d GB  =>  %6s min  (~%s h)\n" "$gb" "$MIN_EST" "$H_EST"
      done
      echo ""
    else
      echo "[WARN] Insufficient data to calculate min/GB." >&2
    fi
    ;;
esac
