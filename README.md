# ASUS GX10 AI Cluster — Ray-based Distributed Model Serving

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![vLLM](https://img.shields.io/badge/vLLM-25.12--py3-blue.svg)](https://github.com/vllm-project/vllm)
[![Ray](https://img.shields.io/badge/Ray-Cluster-3498db.svg)](https://docs.ray.io/)

## 🤔 So... Why Made This?

A quick story: remember when AI subscriptions used to last nearly a whole month? 😅 These days? They're gone in just a few days — sometimes *within a single day*! With all the token multiplication rates going up so much, it's gotten completely out of hand (lol, just kidding... sort of 😄).

I started crunching numbers and realized: if I keep using AI heavily every day without worrying about optimization (just go wild! 😜), the annual cost would be... well, let's just say it's getting painful. So I decided to figure out if running my own cluster would be more cost-effective.

Turns out, it might just be! 🎉 Beyond saving money, I now have *abundant* AI power at my fingertips and learned a ton along the way. I hope this script helps you skip the multi-day research phase I went through and jump straight to having fun with your own AI cluster! 🚀

## Overview

This repository contains deployment scripts for running a distributed AI inference cluster using **ASUS GX10** dual-stack systems with **Ray-based Tensor Parallelism (TP=2)**.

### What's Inside

| File | Purpose |
|------|---------|
| `gx10-setup-master.sh` | One-time setup script for Master Node |
| `gx10-setup-worker.sh` | One-time setup script for Worker Node |
| `deploy-master.sh` | Deploy Ray Head + vLLM services on Master |
| `deploy-worker.sh` | Deploy Ray Worker service on Worker Node |
| `run_cluster.sh` | Launch Ray cluster inside Docker containers |
| `clean-containers.sh` | Clean up unused Docker containers and images |
| `stop-services.sh` | Stop services and clear RAM |
| `switch-model.sh` | Switch model context length (32k/128k) |
| `test_nccl.py` | Test NCCL connectivity between nodes |

### Architecture

```
[Developer PC / Laptop]
         |  (Wi-Fi — API Port 8000)
         v
[Master Node (GX10 #1)] <===== QSFP Direct Link =====> [Worker Node (GX10 #2)]
  - Ray Head Node               (High Speed, <0.1ms)   - Ray Worker Node
  - vLLM Coder (TP=2)                                  - GPU Compute Worker
```

| Machine | Role | IP Address | Services |
|---------|------|------------|----------|
| GX10 #1 | Ray Head + vLLM API | 10.0.0.1 | `ray-head.service`, `vllm-coder.service` |
| GX10 #2 | Ray Worker | 10.0.0.2 | `ray-worker.service` |

> [!IMPORTANT]
> **Replace `<username>` placeholder** in all scripts before running them on your nodes.
> The placeholder `<username>` must be replaced with your actual Linux username (e.g., `ubuntu`, `asus`, `admin`, etc.).
>
> To replace across all files on your local PC:
> ```bash
> sed -i 's/<username>/your_actual_username/g' *.sh
> ```

---

## Quick Start

### Prerequisites

- Two ASUS GX10 systems (Master and Worker)
- 100Gbps QSFP network cable between nodes
- Minimum 150GB free disk space per node
- Ubuntu Linux with Docker and systemd

### One-Time Setup

**1. Configure Network (on both nodes)**

Set static IP addresses for the QSFP interface (`enp1s0f0np0`):

```yaml
# /etc/netplan/99-qsfp-static.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp1s0f0np0:
      dhcp4: false
      addresses:
        - 10.0.0.1/24  # Use 10.0.0.2/24 on Worker
```

```bash
sudo chmod 600 /etc/netplan/99-qsfp-static.yaml && sudo netplan apply
ping -c 3 10.0.0.2   # Test connection to Worker
```

**2. Setup SSH and Sudoers (Master → Worker)**

```bash
# On Master Node
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -C "master" -f ~/.ssh/id_ed25519 -N ""
ssh-copy-id <username>@10.0.0.2
ssh <username>@10.0.0.2 "hostname"   # Should not prompt for password
```

**3. Copy Scripts from Local PC to Nodes**

```bash
# Send all scripts to Master Node
scp *.sh <username>@master.local:/home/<username>/

# Send essential scripts to Worker Node
scp gx10-setup-worker.sh deploy-worker.sh run_cluster.sh <username>@worker01.local:/home/<username>/
```

**4. Run Setup Scripts (directly on each node's Terminal)**

```bash
# On Master Node
chmod +x /home/<username>/*.sh
bash /home/<username>/gx10-setup-master.sh

# On Worker Node
chmod +x /home/<username>/*.sh
bash /home/<username>/gx10-setup-worker.sh
```

### Usage

**1. Download Model (on Master)**

The setup script creates `/home/<username>/download-model.sh` which includes a Disk Gate (minimum 150GB required):

```bash
bash /home/<username>/download-model.sh "" Qwen/Qwen3-Coder-Next-FP8
```

**2. Sync Model Cache to Worker (via QSFP)**

Use `aes128-gcm` cipher for fast huggingface cache transfer:

```bash
rsync -avh --progress -e "ssh -c aes128-gcm@openssh.com" \
  /home/<username>/.cache/huggingface/ \
  <username>@10.0.0.2:/home/<username>/.cache/huggingface/
```

**3. Start Cluster**

```bash
# Start Ray Head (Master)
sudo systemctl start ray-head.service

# Start Ray Worker (Worker)
sudo systemctl start ray-worker.service

# Verify GPU resources (Master)
C=$(docker ps --format "{{.Names}}" | grep -E "^node-[0-9]+$" | head -1)
docker exec -it "$C" ray status
# Expected: GPU: 2.0

# Start vLLM API (Master)
sudo systemctl start vllm-coder.service
```

**4. Test Inference API**

```bash
# Check available models
curl http://master.local:8000/v1/models

# Test coding/reasoning query
curl http://master.local:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3-Coder-Next-FP8",
    "messages": [{"role": "user", "content": "Write a quicksort function in Python."}],
    "max_tokens": 200
  }'
```

---

## Advanced Configuration

### NCCL Optimizations for Blackwell Architecture

For stable, high-performance multi-node communication over QSFP:

1. **Enable RoCE/InfiniBand and P2P** (remove `NCCL_IB_DISABLE=1` and `NCCL_P2P_DISABLE=1`) to allow ConnectX-7 cards to communicate via RDMA over QSFP

2. **Increase NCCL buffer size** (`NCCL_BUFFSIZE=16777216`, `CUDA_MODULE_LOADING=LAZY`) for 100Gbps network efficiency

3. **Bypass PyNCCL** using `VLLM_DISABLE_PYNCCL=1` and `VLLM_DISABLE_CUSTOM_ALL_REDUCE=1` to use `torch.distributed` C++ backend

4. **Enable Serving Optimizations** (`--enable-chunked-prefill`, `--kv-cache-dtype fp8`) for improved throughput

### Context Length Switching

Switch between 32k and 128k context lengths:

```bash
# Switch to 32k context
bash /home/<username>/switch-model.sh 32k

# Switch to 128k context
bash /home/<username>/switch-model.sh 128k
```

### Monitoring & Logs

```bash
# Real-time log monitoring
sudo journalctl -u ray-head.service -f       # Ray logs (Master)
sudo journalctl -u vllm-coder.service -f     # vLLM API logs (Master)
sudo journalctl -u ray-worker.service -f     # Ray Worker logs (Worker)
```

### Stopping Services

```bash
# On Master:
sudo systemctl stop vllm-coder.service
sudo systemctl stop ray-head.service

# On Worker:
sudo systemctl stop ray-worker.service
```

### Docker Cleanup

Clean up unused containers and images:

```bash
bash /home/<username>/clean-containers.sh
```

---

## Key Optimizations

- **RoCE/InfiniBand enabled** on ConnectX-7 cards via QSFP
- **NCCL buffer size**: 16MB for 100Gbps efficiency
- **Pynccl bypassed**: Uses `torch.distributed` C++ backend
- **Chunked prefill**: Improved throughput for variable-length inputs
- **FP8 KV-cache**: Reduced memory footprint

---

## References

- [vLLM Distributed Serving](https://docs.vllm.ai/en/latest/serving/distributed_serving.html)
- [NVIDIA Spark Documentation](https://build.nvidia.com/spark)
- [Ray Documentation](https://docs.ray.io/)

---

## License

MIT