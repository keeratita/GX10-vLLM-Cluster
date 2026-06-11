#!/bin/bash
# switch-model.sh — Switch Context Length of Qwen3-Coder-Next-FP8 on Master Node
# Usage: bash switch-model.sh [32k|128k]
# ============================================================
set -e

ENV_FILE="/home/<username>/vllm.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: Environment file $ENV_FILE does not exist. Please run deploy-master.sh first."
  exit 1
fi

if [ "$1" == "32k" ]; then
  echo "=== Switching to [Option 1] Qwen3-Coder-Next-FP8 (32k Context Limit) ==="
  cat > "$ENV_FILE" << 'EOF'
# vLLM Coder Service Configuration
# To switch context lengths, run: sudo systemctl restart vllm-coder.service

# [Option 1] Qwen3 Coder Next FP8 (32k Context)
VLLM_MODEL=Qwen/Qwen3-Coder-Next-FP8
VLLM_SERVED_MODEL_NAME=Qwen3-Coder-Next-FP8
VLLM_MAX_MODEL_LEN=32768
EOF

elif [ "$1" == "128k" ]; then
  echo "=== Switching to [Option 2] Qwen3-Coder-Next-FP8 (128k Context Limit) ==="
  cat > "$ENV_FILE" << 'EOF'
# vLLM Coder Service Configuration
# To switch context lengths, run: sudo systemctl restart vllm-coder.service

# [Option 2] Qwen3 Coder Next FP8 (128k Context)
VLLM_MODEL=Qwen/Qwen3-Coder-Next-FP8
VLLM_SERVED_MODEL_NAME=Qwen3-Coder-Next-FP8
VLLM_MAX_MODEL_LEN=131072
EOF

else
  echo "Usage: $0 [32k|128k]"
  echo ""
  echo "Current status of $ENV_FILE:"
  grep -E "^VLLM_MODEL=" "$ENV_FILE" || true
  grep -E "^VLLM_MAX_MODEL_LEN=" "$ENV_FILE" || true
  exit 1
fi

echo "=== Restarting vllm-coder.service to apply changes ==="
sudo systemctl restart vllm-coder.service
echo "  Done. Service restarted. Monitor logs using:"
echo "     sudo journalctl -u vllm-coder.service -f"