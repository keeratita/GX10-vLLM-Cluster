#!/bin/bash
# ============================================================
# GX10 Master Node Setup Script (Ray-based Cluster with vLLM Image)
# Run on Master Node (GX10 #1) only
# Usage: bash gx10-setup-master.sh
# ============================================================
set -e

VLLM_IMAGE=nvcr.io/nvidia/vllm:25.12-py3

echo "=== GX10 Master Setup (Ray-based TP=2 serving: Qwen 3 Coder) ==="

echo "Step 1: Stop old legacy services if active..."
sudo systemctl stop vllm-master.service vllm-brain.service ray-head.service vllm-coder.service vllm-indexer.service 2>/dev/null || true
docker rm -f vllm-master vllm-brain vllm-coder vllm-indexer 2>/dev/null || true

# Kill lingering processes
pkill -f torchrun || true
pkill -f vllm || true
pkill -f ray || true

echo "Step 1.5: Cleaning up legacy model checkpoints to free disk space..."
# Remove old model caches (user: <username>)
sudo rm -rf /home/<username>/.cache/huggingface/hub/models--Qwen--Qwen3-Coder-30B-A3B-Instruct
sudo rm -rf /home/<username>/.cache/huggingface/hub/models--Qwen--Qwen3-Coder-30B-A3B-Instruct-FP8
sudo rm -rf /home/<username>/.cache/huggingface/hub/models--RedHatAI--Qwen2.5-Coder-32B-Instruct-FP8-dynamic
sudo rm -rf /home/<username>/.cache/huggingface/hub/models--Qwen--Qwen2.5-Coder-32B-Instruct
# Clean up worker caches
ssh -o StrictHostKeyChecking=no <username>@10.0.0.2 "sudo rm -rf /home/<username>/.cache/huggingface/hub/models--Qwen--Qwen3-Coder-30B-A3B-Instruct \
  /home/<username>/.cache/huggingface/hub/models--Qwen--Qwen3-Coder-30B-A3B-Instruct-FP8 \
  /home/<username>/.cache/huggingface/hub/models--RedHatAI--Qwen2.5-Coder-32B-Instruct-FP8-dynamic \
  /home/<username>/.cache/huggingface/hub/models--Qwen--Qwen2.5-Coder-32B-Instruct" || true

echo "Step 2: Pulling base v25 image (contains Ray)..."
docker pull "$VLLM_IMAGE"
echo "  -> Image pulled successfully!"

echo "Step 3: Write /home/<username>/start-ray-head.sh..."
cat > /home/<username>/start-ray-head.sh << SCRIPT
#!/bin/bash
set -e
VLLM_IMAGE=$VLLM_IMAGE
MN_IF_NAME=enp1s0f0np0
VLLM_HOST_IP=10.0.0.1
HF_CACHE=/home/<username>/.cache/huggingface

# Clear old Ray containers
OLD=\$(docker ps -a --format '{{.Names}}' | grep -E '^node-[0-9]+\$' | head -1)
[ -n "\$OLD" ] && docker rm -f "\$OLD" 2>/dev/null || true

# Run Ray head node
bash /home/<username>/run_cluster.sh "\$VLLM_IMAGE" "\$VLLM_HOST_IP" --head "\$HF_CACHE" \
  --ipc=host \
  -v /tmp/ray:/tmp/ray \
  -e VLLM_HOST_IP=\$VLLM_HOST_IP \
  -e UCX_NET_DEVICES=\$MN_IF_NAME \
  -e NCCL_SOCKET_IFNAME=\$MN_IF_NAME \
  -e OMPI_MCA_btl_tcp_if_include=\$MN_IF_NAME \
  -e GLOO_SOCKET_IFNAME=\$MN_IF_NAME \
  -e TP_SOCKET_IFNAME=\$MN_IF_NAME \
  -e RAY_memory_monitor_refresh_ms=0 \
  -e MASTER_ADDR=\$VLLM_HOST_IP \
  -e VLLM_TARGET_DEVICE=cuda \
  -e NCCL_DEBUG=INFO \
  -e NCCL_BUFFSIZE=16777216 \
  -e VLLM_DISABLE_PYNCCL=1 \
  -e VLLM_DISABLE_CUSTOM_ALL_REDUCE=1
SCRIPT
chmod +x /home/<username>/start-ray-head.sh
echo "  -> /home/<username>/start-ray-head.sh OK"

echo "Step 4: Write /home/<username>/download-model.sh (with Disk Space Gate)..."
cat > /home/<username>/download-model.sh << 'EOF'
#!/bin/bash
set -e

# Usage: ./download-model.sh <hf_token> [model_name]
HF_TOKEN="$1"
CODER_MODEL="${2:-Qwen/Qwen3-Coder-Next-FP8}"

echo "=== Running Disk Space Gate ==="
FREE_SPACE_KB=$(df -P /home/<username> | awk 'NR==2 {print $4}')
FREE_SPACE_GB=$((FREE_SPACE_KB / 1024 / 1024))

if [ "$FREE_SPACE_GB" -lt 150 ]; then
  echo "ERROR: Disk Space Too Low (${FREE_SPACE_GB} GB free). Minimum 150 GB required."
  exit 1
fi
echo "Disk Space Gate Passed: ${FREE_SPACE_GB} GB free space available."

if [ -n "$HF_TOKEN" ]; then
  echo "=== HuggingFace Login ==="
  docker run --rm \
    -v /home/<username>/.cache/huggingface:/root/.cache/huggingface \
    nvcr.io/nvidia/vllm:25.12-py3 \
    hf login --token "$HF_TOKEN"
fi

echo "=== Downloading Model: $CODER_MODEL ==="
docker run --rm \
  -v /home/<username>/.cache/huggingface:/root/.cache/huggingface \
  nvcr.io/nvidia/vllm:25.12-py3 \
  python3 -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='$CODER_MODEL')"

echo "=== Model Download Complete ==="
EOF
chmod +x /home/<username>/download-model.sh
echo "  -> /home/<username>/download-model.sh OK"

echo "Step 5: Write /home/<username>/vllm.env and /etc/systemd/system/ray-head.service..."
cat > /home/<username>/vllm.env.tmp << 'EOF'
# vLLM Coder Service Configuration
# Qwen3-Coder-Next-FP8 (128k Context)
VLLM_MODEL=Qwen/Qwen3-Coder-Next-FP8
VLLM_SERVED_MODEL_NAME=Qwen3-Coder-Next-FP8
VLLM_MAX_MODEL_LEN=131072
EOF

if [ ! -f /home/<username>/vllm.env ]; then
  mv /home/<username>/vllm.env.tmp /home/<username>/vllm.env
  echo "  -> Created /home/<username>/vllm.env (Default: 128k)"
else
  rm -f /home/<username>/vllm.env.tmp
  echo "  -> /home/<username>/vllm.env already exists, preserving current settings."
fi

echo "Step 6: Write /etc/systemd/system/ray-head.service..."
sudo tee /etc/systemd/system/ray-head.service > /dev/null << 'EOF'
[Unit]
Description=Ray Head Node Service
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=<username>
ExecStartPre=+/bin/bash -c 'echo "Clearing Page Cache (RAM) before starting Ray..."; sync && sysctl -w vm.drop_caches=3'
ExecStartPre=+/bin/bash -c 'rm -rf /tmp/ray && mkdir -p /tmp/ray && chmod 1777 /tmp/ray'
ExecStart=/bin/bash /home/<username>/start-ray-head.sh
ExecStop=/bin/bash -c 'OLD=$(docker ps -a --format "{{.Names}}" | grep -E "^node-[0-9]+$" | head -1); [ -n "$OLD" ] && docker stop "$OLD" || true'
ExecStopPost=/bin/bash -c 'OLD=$(docker ps -a --format "{{.Names}}" | grep -E "^node-[0-9]+$" | head -1); [ -n "$OLD" ] && docker rm -f "$OLD" || true'
Restart=on-failure
RestartSec=15
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
echo "  -> /etc/systemd/system/ray-head.service OK"

echo "Step 7: Write /etc/systemd/system/vllm-coder.service..."
sudo tee /etc/systemd/system/vllm-coder.service > /dev/null << SCRIPT
[Unit]
Description=vLLM Coder (TP=2 via Ray Cluster)
After=network-online.target docker.service ray-head.service
Wants=network-online.target
Requires=docker.service ray-head.service

[Service]
Type=simple
User=<username>
EnvironmentFile=/home/<username>/vllm.env
ExecStartPre=+/bin/bash -c 'echo "Clearing Page Cache (RAM) to free Unified Memory..."; sync && sysctl -w vm.drop_caches=3'
ExecStartPre=/bin/bash -c 'echo "Ensuring no port conflicts on 8000..."; fuser -k 8000/tcp 2>/dev/null || true; sleep 2'
ExecStartPre=/bin/bash -c '\\
  C=\$(docker ps --format "{{.Names}}" | grep -E "^node-[0-9]+\$" | head -1); \\
  until docker exec "\$C" ray status 2>/dev/null | grep -q "GPU"; do \\
    echo "Waiting for Ray cluster to start..."; sleep 10; \\
  done; \\
  sleep 5'
ExecStart=docker run --rm --name vllm-coder \\
  --gpus all \\
  --network=host \\
  --ipc=host \\
  -v /home/<username>/.cache/huggingface:/root/.cache/huggingface \\
  -v /tmp/ray:/tmp/ray \\
  -e RAY_ADDRESS=10.0.0.1:6379 \\
  -e VLLM_HOST_IP=10.0.0.1 \\
  -e GLOO_SOCKET_IFNAME=enp1s0f0np0 \\
  -e NCCL_SOCKET_IFNAME=enp1s0f0np0 \\
  -e TP_SOCKET_IFNAME=enp1s0f0np0 \\
  -e UCX_NET_DEVICES=enp1s0f0np0 \\
  -e PYTORCH_ALLOC_CONF=expandable_segments:True \\
  -e VLLM_TARGET_DEVICE=cuda \\
  -e NCCL_DEBUG=INFO \\
  -e NCCL_BUFFSIZE=16777216 \\
  -e CUDA_MODULE_LOADING=LAZY \\
  -e VLLM_DISABLE_PYNCCL=1 \\
  -e VLLM_DISABLE_CUSTOM_ALL_REDUCE=1 \\
  -e VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 \\
  $VLLM_IMAGE \\
  vllm serve \$VLLM_MODEL \\
    --served-model-name \$VLLM_SERVED_MODEL_NAME \\
    --host 0.0.0.0 \\
    --port 8000 \\
    --tensor-parallel-size 2 \\
    --gpu-memory-utilization 0.80 \\
    --max-model-len \$VLLM_MAX_MODEL_LEN \\
    --enable-chunked-prefill \\
    --kv-cache-dtype fp8 \\
    --enable-auto-tool-choice \\
    --tool-call-parser qwen3_coder \\
    --trust-remote-code
ExecStop=/usr/bin/docker stop vllm-coder
ExecStopPost=/usr/bin/docker rm -f vllm-coder
Restart=on-failure
RestartSec=15
LimitNOFILE=65536
TimeoutStartSec=infinity
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SCRIPT
echo "  -> /etc/systemd/system/vllm-coder.service OK"

echo "Step 8: Clean up old Indexer / Proxy services..."
sudo systemctl stop vllm-indexer.service vllm-indexer-proxy.service 2>/dev/null || true
sudo systemctl disable vllm-indexer.service vllm-indexer-proxy.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/vllm-indexer.service /etc/systemd/system/vllm-indexer-proxy.service /home/<username>/nginx-indexer-proxy.conf 2>/dev/null || true

echo "Step 9: Reload systemd and enable new services..."
sudo systemctl daemon-reload
# Disable old services if enabled
sudo systemctl disable vllm-master.service vllm-brain.service 2>/dev/null || true
# Enable new services
sudo systemctl enable ray-head.service vllm-coder.service
echo "  -> Services enabled"

echo ""
echo "=== Master Node Setup Complete ==="
echo "Next steps:"
echo "  1. Run gx10-setup-worker.sh on Worker Node (GX10 #2)"
echo "  2. Start Ray Head: sudo systemctl restart ray-head.service"
echo "  3. Start Coder (Port 8000): sudo systemctl restart vllm-coder.service"
echo "  4. Monitor logs: sudo journalctl -u vllm-coder.service -f"