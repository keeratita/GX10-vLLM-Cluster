#!/bin/bash
# ============================================================
# GX10 Worker Node Setup Script (Ray-based Cluster with vLLM Image)
# Run on Worker Node (GX10 #2) only
# Usage: bash gx10-setup-worker.sh
# ============================================================
set -e

VLLM_IMAGE=nvcr.io/nvidia/vllm:25.12-py3

echo "=== GX10 Worker Setup (Ray-based Cluster: Qwen 3 Coder) ==="

echo "Step 1: Stop old legacy services if active..."
sudo systemctl stop vllm-worker.service ray-worker.service 2>/dev/null || true
docker rm -f vllm-worker vllm-brain vllm-coder vllm-indexer 2>/dev/null || true

# Kill lingering processes
pkill -f torchrun || true
pkill -f vllm || true
pkill -f ray || true

echo "Step 2: Pulling base v25 image (contains Ray)..."
docker pull "$VLLM_IMAGE"
echo "  -> Image pulled successfully!"

echo "Step 3: Write /home/<username>/start-ray-worker.sh..."
cat > /home/<username>/start-ray-worker.sh << SCRIPT
#!/bin/bash
set -e
VLLM_IMAGE=$VLLM_IMAGE
MN_IF_NAME=enp1s0f0np0
VLLM_HOST_IP=10.0.0.2
HEAD_NODE_IP=10.0.0.1
HF_CACHE=/home/<username>/.cache/huggingface

# Clear old Ray containers
OLD=\$(docker ps -a --format '{{.Names}}' | grep -E '^node-[0-9]+\$' | head -1)
[ -n "\$OLD" ] && docker rm -f "\$OLD" 2>/dev/null || true

# Run Ray worker node connecting to head node
bash /home/<username>/run_cluster.sh "\$VLLM_IMAGE" "\$HEAD_NODE_IP" --worker "\$HF_CACHE" \
  --ipc=host \
  -v /tmp/ray:/tmp/ray \
  -e VLLM_HOST_IP=\$VLLM_HOST_IP \
  -e UCX_NET_DEVICES=\$MN_IF_NAME \
  -e NCCL_SOCKET_IFNAME=\$MN_IF_NAME \
  -e OMPI_MCA_btl_tcp_if_include=\$MN_IF_NAME \
  -e GLOO_SOCKET_IFNAME=\$MN_IF_NAME \
  -e TP_SOCKET_IFNAME=\$MN_IF_NAME \
  -e RAY_memory_monitor_refresh_ms=0 \
  -e MASTER_ADDR=\$HEAD_NODE_IP \
  -e VLLM_TARGET_DEVICE=cuda \
  -e NCCL_DEBUG=INFO \
  -e NCCL_BUFFSIZE=16777216 \
  -e VLLM_DISABLE_PYNCCL=1 \
  -e VLLM_DISABLE_CUSTOM_ALL_REDUCE=1
SCRIPT
chmod +x /home/<username>/start-ray-worker.sh
echo "  -> /home/<username>/start-ray-worker.sh OK"

echo "Step 4: Write /home/<username>/cleanup-vllm.sh..."
cat > /home/<username>/cleanup-vllm.sh << 'EOF'
#!/bin/bash
OLD=$(docker ps -a --format '{{.Names}}' | grep -E '^node-[0-9]+$' | head -1)
[ -n "$OLD" ] && docker rm -f "$OLD" 2>/dev/null || true
docker rm -f vllm-worker vllm-brain vllm-coder vllm-indexer 2>/dev/null || true
pkill -f ray || true
pkill -f python || true
sudo rm -rf /tmp/ray
EOF
chmod +x /home/<username>/cleanup-vllm.sh
echo "  -> /home/<username>/cleanup-vllm.sh OK"

echo "Step 5: Write /etc/systemd/system/ray-worker.service..."
sudo tee /etc/systemd/system/ray-worker.service > /dev/null << 'EOF'
[Unit]
Description=Ray Worker Node Service
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=<username>
ExecStartPre=+/bin/bash -c 'echo "Clearing Page Cache (RAM) before starting Ray Worker..."; sync && sysctl -w vm.drop_caches=3'
ExecStartPre=+/bin/bash -c 'rm -rf /tmp/ray && mkdir -p /tmp/ray && chmod 1777 /tmp/ray'
ExecStart=/bin/bash /home/<username>/start-ray-worker.sh
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
echo "  -> /etc/systemd/system/ray-worker.service OK"

echo "Step 6: Reload systemd and enable new services..."
sudo systemctl daemon-reload
# Disable old Ray-less services if enabled
sudo systemctl disable vllm-worker.service 2>/dev/null || true
# Enable new Ray-based services
sudo systemctl enable ray-worker.service
echo "  -> Services enabled"

echo ""
echo "=== Worker Node Setup Complete ==="
echo "Next steps:"
echo "  1. Start Ray Worker: sudo systemctl restart ray-worker.service"
echo "  2. Monitor logs: sudo journalctl -u ray-worker.service -f"