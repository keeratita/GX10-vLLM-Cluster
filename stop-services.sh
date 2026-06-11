#!/bin/bash
# stop-services.sh — Stop services, clean containers, and clear RAM on Master Node
# Usage: bash stop-services.sh
# ==============================================================================

set -e

echo "=== 1. Stopping Systemd Services ==="
sudo systemctl stop vllm-coder.service vllm-indexer.service ray-head.service 2>/dev/null || true
sudo systemctl disable vllm-indexer.service 2>/dev/null || true

echo "=== 2. Cleaning Docker Containers ==="
docker rm -f vllm-coder vllm-indexer 2>/dev/null || true

# Find and remove Ray node-<random> containers
ACTIVE_RAY_NODE=$(docker ps --format '{{.Names}}' | grep -E '^node-[0-9]+$' | head -1 || true)
if [ -n "$ACTIVE_RAY_NODE" ]; then
  echo "Stopping Ray container: $ACTIVE_RAY_NODE..."
  docker stop "$ACTIVE_RAY_NODE" 2>/dev/null || true
  docker rm -f "$ACTIVE_RAY_NODE" 2>/dev/null || true
fi

echo "=== 3. Killing Stray Processes ==="
pkill -f ray || true
pkill -f python || true
pkill -f python3 || true
sudo rm -rf /tmp/ray

echo "=== 4. Clearing Page Cache (RAM) ==="
sync && sudo sysctl -w vm.drop_caches=3

echo "=== Done! All services stopped and VRAM/RAM cleared successfully. ==="