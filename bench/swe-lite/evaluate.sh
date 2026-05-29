#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCES="$SCRIPT_DIR/instances.json"
RESULTS_DIR="$SCRIPT_DIR/results"
WORK_DIR="/tmp/swe-lite-bench"
PREDICTIONS_DIR="$WORK_DIR/predictions"

mkdir -p "$PREDICTIONS_DIR"

W='\033[1;37m' G='\033[0;32m' R='\033[0;31m' C='\033[0;36m' Y='\033[0;33m' D='\033[0;90m' N='\033[0m'

printf "\n${W}═══════════════════════════════════════════════════════${N}\n"
printf "${W}  SWE-bench Lite — Patch Evaluation${N}\n"
printf "${W}═══════════════════════════════════════════════════════${N}\n\n"

# Check Docker
if ! docker info >/dev/null 2>&1; then
  printf "${R}  Error: Docker is not running. Start Docker and retry.${N}\n\n"
  exit 1
fi

# Install swebench if needed
if ! python3 -c "import swebench" 2>/dev/null; then
  printf "  ${C}installing swebench...${N}\n"
  pip3 install swebench 2>&1 | tail -2
fi

INSTANCE_COUNT=$(python3 -c "import json; print(len(json.load(open('$INSTANCES'))))")

# Convert patches to swebench prediction format
for VARIANT in codedb baseline; do
  PRED_FILE="$PREDICTIONS_DIR/predictions_${VARIANT}.jsonl"
  > "$PRED_FILE"

  for IDX in $(seq 0 $((INSTANCE_COUNT - 1))); do
    INSTANCE_ID=$(python3 -c "import json; print(json.load(open('$INSTANCES'))[$IDX]['instance_id'])")
    PATCH_FILE="$RESULTS_DIR/${INSTANCE_ID}_${VARIANT}.patch"

    if [ -s "$PATCH_FILE" ]; then
      python3 -c "
import json
with open('$PATCH_FILE') as f:
    patch = f.read()
pred = {
    'instance_id': '$INSTANCE_ID',
    'model_name_or_path': 'sonnet-4.6-${VARIANT}',
    'model_patch': patch
}
print(json.dumps(pred))
" >> "$PRED_FILE"
    else
      python3 -c "
import json
pred = {
    'instance_id': '$INSTANCE_ID',
    'model_name_or_path': 'sonnet-4.6-${VARIANT}',
    'model_patch': ''
}
print(json.dumps(pred))
" >> "$PRED_FILE"
    fi
  done

  printf "  ${G}wrote %s${N}\n" "$PRED_FILE"
done

# Run swebench evaluation for each variant
for VARIANT in codedb baseline; do
  PRED_FILE="$PREDICTIONS_DIR/predictions_${VARIANT}.jsonl"
  RUN_ID="swe-lite-${VARIANT}-$(date +%Y%m%d)"

  printf "\n${C}  Evaluating ${VARIANT} patches...${N}\n"
  python3 -m swebench.harness.run_evaluation \
    --dataset_name princeton-nlp/SWE-bench_Lite \
    --predictions_path "$PRED_FILE" \
    --max_workers 4 \
    --run_id "$RUN_ID" \
    --namespace '' \
    2>&1 | tee "$RESULTS_DIR/eval_${VARIANT}.log" || true
done

# Parse results and print comparison
printf "\n${W}═══════════════════════════════════════════════════════${N}\n"
printf "${W}  Final Results${N}\n"
printf "${W}═══════════════════════════════════════════════════════${N}\n\n"

python3 << 'PYEOF'
import json, glob, os

results_dir = os.environ.get("RESULTS_DIR", "results")
for variant in ["codedb", "baseline"]:
    log_file = f"{results_dir}/eval_{variant}.log"
    if os.path.exists(log_file):
        with open(log_file) as f:
            content = f.read()
        # Look for resolved count in swebench output
        for line in content.split('\n'):
            if 'resolved' in line.lower() or 'pass' in line.lower():
                print(f"  {variant}: {line.strip()}")
PYEOF

printf "\n  ${D}Full logs in: %s${N}\n\n" "$RESULTS_DIR"
