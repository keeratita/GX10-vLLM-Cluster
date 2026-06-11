#!/bin/bash
# clean-containers.sh — Remove unrelated Docker containers and images to free space
# Usage: bash clean-containers.sh
# ==============================================================================
# 
# IMPORTANT: Before running this script, review and edit the PRESERVED_IMAGES
# list below if you have custom images you want to keep (e.g., different vLLM
# versions or other Docker images).
#
# Lines to edit (lines 8-12):
#   # Define images to preserve (even if not running)
#   PRESERVED_IMAGES=(
#     "nvcr.io/nvidia/vllm:25.12-py3"
#   )
#
# Add additional images to preserve by adding them to the list:
#   PRESERVED_IMAGES=(
#     "nvcr.io/nvidia/vllm:25.12-py3"
#     "myregistry/myimage:latest"
#     "another-image:tag"
#   )
#
# ==============================================================================

set -e

# Define images to preserve (even if not running)
PRESERVED_IMAGES=(
  "nvcr.io/nvidia/vllm:25.12-py3"
)

echo "=== Checking and removing unrelated Docker containers ==="

# Get all container names
ALL_CONTAINERS=$(docker ps -a --format '{{.Names}}')

for container in $ALL_CONTAINERS; do
  # 1. Skip main model service containers (vllm-coder and vllm-indexer)
  if [[ "$container" == "vllm-coder" ]] || [[ "$container" == "vllm-indexer" ]]; then
    echo "PRESERVE: $container (main model service container)"
    continue
  fi

  # 2. Skip Ray cluster node containers (e.g., node-12345)
  if [[ "$container" =~ ^node-[0-9]+$ ]]; then
    echo "PRESERVE: $container (Ray Cluster node container)"
    continue
  fi

  # 3. Otherwise, remove the unrelated container
  echo "REMOVING: $container (unrelated container)"
  docker stop "$container" 2>/dev/null || true
  docker rm -f "$container" 2>/dev/null || true
done

# Prune stopped containers
docker container prune -f

echo ""
echo "=== Checking and removing unrelated Docker images ==="

# Get all images
ALL_IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}')

# Get currently active container images
ACTIVE_CONTAINER_IMAGES=$(docker ps -a --format '{{.Image}}' | sort -u)

while read -r image_info; do
  [ -z "$image_info" ] && continue
  
  image_name=$(echo "$image_info" | awk '{print $1}')
  image_id=$(echo "$image_info" | awk '{print $2}')
  
  # 1. Check if in preserved list
  PRESERVE=false
  for preserved in "${PRESERVED_IMAGES[@]}"; do
    if [[ "$image_name" == "$preserved" ]]; then
      PRESERVE=true
      break
    fi
  done
  
  # 2. Check if used by active containers
  if [ "$PRESERVE" = false ]; then
    for active_img in $ACTIVE_CONTAINER_IMAGES; do
      if [[ "$active_img" == "$image_name" ]] || [[ "$active_img" == "$image_id" ]]; then
        PRESERVE=true
        break
      fi
    done
  fi
  
  if [ "$PRESERVE" = true ]; then
    echo "PRESERVE: $image_name ($image_id) (system image or in use)"
  else
    echo "REMOVING: $image_name ($image_id)"
    docker rmi -f "$image_id" 2>/dev/null || docker rmi -f "$image_name" 2>/dev/null || true
  fi
done <<< "$ALL_IMAGES"

# Remove dangling images and cache
echo "RUNNING: docker image prune to clear cache and dangling images..."
docker image prune -f

echo "=== Clean up complete! ==="