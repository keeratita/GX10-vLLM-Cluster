import os
import torch
import torch.distributed as dist

# Retrieves distributed job information from environment variables
rank = int(os.environ.get("RANK", 0))
world_size = int(os.environ.get("WORLD_SIZE", 2))
local_rank = int(os.environ.get("LOCAL_RANK", 0))

print(f"=== Rank {rank} / World Size {world_size} ===")
print(f"Initializing process group via NCCL...")

# Performs rendezvous via NCCL
dist.init_process_group(backend="nccl")
print(f"Rank {rank}: Process group initialized successfully!")

# Sets GPU device
device = torch.device(f"cuda:{local_rank}")
torch.cuda.set_device(device)

# Creates a tensor on GPU (Master = 1.0, Worker = 2.0)
tensor = torch.ones(10, device=device) * (rank + 1)
print(f"Rank {rank}: Before All-Reduce (self value) -> {tensor}")

# Performs All-Reduce Sum operation
dist.all_reduce(tensor, op=dist.ReduceOp.SUM)

# After all-reduce, all ranks get the sum (1.0 + 2.0 = 3.0)
print(f"Rank {rank}: After All-Reduce (sum result: 3.0) -> {tensor}")

dist.destroy_process_group()
print(f"Rank {rank}: NCCL test passed! ✅")
