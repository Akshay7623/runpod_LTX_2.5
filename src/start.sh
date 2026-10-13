#!/usr/bin/env bash

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

# This image ships a cu130 PyTorch, which needs NVIDIA driver >= 580. On an older
# host ComfyUI would die on its first GPU call and the handler would only report
# "ComfyUI server not reachable", so check here and fail with the real cause.
echo "worker-comfyui: Checking GPU availability..."
if ! GPU_CHECK=$(python -c "
import torch
try:
    torch.cuda.init()
    name = torch.cuda.get_device_name(0)
    _ = (torch.zeros(8, device='cuda') + 1).sum().item()
    torch.cuda.synchronize()
    print(f'OK: {name}, torch {torch.__version__}, cuda {torch.version.cuda}')
except Exception as e:
    print(f'FAIL: {e}')
    exit(1)
" 2>&1); then
    echo "worker-comfyui: GPU is not usable with this PyTorch build: $GPU_CHECK"
    echo "worker-comfyui: Set 'Allowed CUDA Versions' to 13.0 on the endpoint so workers get a host with driver >= 580."
    exit 1
fi
echo "worker-comfyui: GPU available - $GPU_CHECK"

echo "worker-comfyui: Starting ComfyUI"

# Allow operators to tweak verbosity; default is DEBUG.
: "${COMFY_LOG_LEVEL:=DEBUG}"

# Serve the API and don't shutdown the container
if [ "$SERVE_API_LOCALLY" == "true" ]; then
    python -u /comfyui/main.py --disable-auto-launch --disable-metadata --listen --verbose "${COMFY_LOG_LEVEL}" --log-stdout &

    echo "worker-comfyui: Starting RunPod Handler"
    python -u /handler.py --rp_serve_api --rp_api_host=0.0.0.0
else
    python -u /comfyui/main.py --disable-auto-launch --disable-metadata --verbose "${COMFY_LOG_LEVEL}" --log-stdout &

    echo "worker-comfyui: Starting RunPod Handler"
    python -u /handler.py
fi
