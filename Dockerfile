
# LTX-2.5: text/image to video with audio, up to native high resolutions
# ComfyUI on RunPod Serverless
# All model weights baked into the image.

ARG BASE_IMAGE=nvidia/cuda:13.0.3-base-ubuntu24.04
FROM ${BASE_IMAGE} AS base

ARG COMFYUI_VERSION=v0.39.0
ARG PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu130
ARG TORCH_VERSION=2.14.1
ARG TORCHVISION_VERSION=0.29.1

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_INPUT=1
ENV PIP_NO_CACHE_DIR=1
ENV UV_NO_CACHE=1

# Make the system C/C++ compilers available to Triton.
ENV CC=/usr/bin/gcc
ENV CXX=/usr/bin/g++

# Install Python, compilers, and system dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    git \
    wget \
    ca-certificates \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && gcc --version \
    && g++ --version \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install uv and create the Python virtual environment.
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv --python /usr/bin/python3.12 /opt/venv

ENV PATH="/opt/venv/bin:${PATH}"

# Triton compiles against Python.h on the worker; fail the build if gcc cannot find it.
RUN echo '#include <Python.h>' | gcc -fsyntax-only -x c \
    -I"$(python -c 'import sysconfig; print(sysconfig.get_paths()["include"])')" -

# Install pinned ComfyUI release.
RUN git clone --depth 1 --branch "${COMFYUI_VERSION}" \
    https://github.com/Comfy-Org/ComfyUI.git /comfyui

# Install CUDA 13.0 PyTorch first.
RUN uv pip install \
    "torch==${TORCH_VERSION}" \
    "torchvision==${TORCHVISION_VERSION}" \
    --index-url "${PYTORCH_INDEX_URL}"

# Install ComfyUI and worker dependencies.
RUN uv pip install \
    -r /comfyui/requirements.txt \
    "transformers>=4.50.3,<5" \
    "huggingface-hub<1.0" \
    runpod==1.7.13 \
    requests==2.32.4 \
    websocket-client==1.8.0 \
    boto3==1.40.21

# Verify Python dependencies and ComfyUI startup.
RUN cd /comfyui && timeout 300 \
    python main.py --quick-test-for-ci --cpu

# The official Lightricks/LTX-2.5 repo is gated, and RunPod's builder cannot be
# given a Hugging Face token. The weights therefore come from an ungated copy of
# the same files. Both repos are pinned to a commit, so the content cannot change.
# Declared here, not at the top, so the layers above stay cached when these move.
ARG LTX_REPO=https://huggingface.co/osantinello/LTX25_Models/resolve/a2faa81527c7d8e66dc7e233282ab3b98f352597
ARG GEMMA_REPO=https://huggingface.co/Comfy-Org/gemma-4/resolve/63d0f7c476756b88910170c1df75e2384ea1af31/text_encoders

# Download the LTX-2.5 diffusion model.
RUN set -e; \
    fetch() { \
      mkdir -p "/comfyui/models/$1"; \
      wget -nv --tries=5 \
        -O "/comfyui/models/$1/$2" \
        "$3/$2"; \
    }; \
    fetch diffusion_models ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors "${LTX_REPO}"

# Download the text encoders, video/audio VAEs and latent upscaler.
RUN set -e; \
    fetch() { \
      mkdir -p "/comfyui/models/$1"; \
      wget -nv --tries=5 \
        -O "/comfyui/models/$1/$2" \
        "$3/$2"; \
    }; \
    fetch text_encoders gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors "${LTX_REPO}" & p1=$!; \
    fetch text_encoders gemma4_e2b_it_int8_convrot.safetensors "${GEMMA_REPO}" & p2=$!; \
    fetch vae ltx-2.5-video-vae-bf16.safetensors "${LTX_REPO}" & p3=$!; \
    fetch vae ltx-2.5-audio-vae-bf16.safetensors "${LTX_REPO}" & p4=$!; \
    fetch latent_upscale_models ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors "${LTX_REPO}" & p5=$!; \
    wait "$p1"; \
    wait "$p2"; \
    wait "$p3"; \
    wait "$p4"; \
    wait "$p5"

WORKDIR /

# Add the RunPod handler and startup script.
ADD src/start.sh handler.py test_input.json ./
RUN chmod +x /start.sh

CMD ["/start.sh"]
