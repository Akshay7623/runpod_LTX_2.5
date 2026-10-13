#!/usr/bin/env bash

# Download the LTX-2.5 model files that are not on disk yet.
#
#   download_models.sh <store_dir> [folder ...]
#
# This runs at build time to bake the models into the image, and again at worker
# start to fetch whatever the image does not hold. Files are kept in <store_dir>
# under ComfyUI's folder names. When that is not /comfyui/models itself (a
# network volume, say), each file is linked into /comfyui/models.
#
# Naming folders limits the run to those folders, which lets the Dockerfile
# spread the models over more than one layer.
set -uo pipefail

COMFY_MODELS=/comfyui/models

# Both repos are pinned to a commit so a rebuild cannot pick up changed files.
LTX_REPO=https://huggingface.co/Lightricks/LTX-2.5/resolve/49b093a39c19169a8a81721dcc541e07e945232f
GEMMA_REPO=https://huggingface.co/Comfy-Org/gemma-4/resolve/63d0f7c476756b88910170c1df75e2384ea1af31

# "<repo> <path>". The path is the same inside the repo and under models/.
MODELS=(
    "${LTX_REPO} diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors"
    "${LTX_REPO} text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors"
    "${LTX_REPO} vae/ltx-2.5-video-vae-bf16.safetensors"
    "${LTX_REPO} vae/ltx-2.5-audio-vae-bf16.safetensors"
    "${LTX_REPO} latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors"
    # Prompt enhancer. A public repo; only loaded when a request turns prompt_enhance on.
    "${GEMMA_REPO} text_encoders/gemma4_e2b_it_int8_convrot.safetensors"
)

if [ "$#" -lt 1 ]; then
    echo "usage: download_models.sh <store_dir> [folder ...]" >&2
    exit 2
fi
STORE="$1"
shift
FOLDERS=("$@")

# True when the path is in one of the requested folders, or none were named.
wanted() {
    [ "${#FOLDERS[@]}" -eq 0 ] && return 0
    local folder
    for folder in "${FOLDERS[@]}"; do
        [ "${1%%/*}" = "${folder}" ] && return 0
    done
    return 1
}

fetch() {
    local url="$1" dest="$2"
    # Download under a temporary name: a file that has its final name is always
    # complete, even if a worker was killed mid-transfer. The hostname keeps two
    # workers that share a volume from writing to the same temporary file.
    local partial="${dest}.${HOSTNAME}.partial"
    local auth=()
    [ -n "${HF_TOKEN:-}" ] && auth=(--header="Authorization: Bearer ${HF_TOKEN}")

    mkdir -p "$(dirname "${dest}")"
    if wget -nv --tries=5 "${auth[@]}" -O "${partial}" "${url}"; then
        mv -f "${partial}" "${dest}"
    else
        rm -f "${partial}"
        echo "download_models: failed to download ${url}" >&2
        return 1
    fi
}

missing=()
for entry in "${MODELS[@]}"; do
    read -r repo path <<< "${entry}"
    wanted "${path}" || continue
    # Already in the image, or linked in by an earlier run.
    [ -e "${COMFY_MODELS}/${path}" ] && continue
    missing+=("${entry}")
done

if [ "${#missing[@]}" -eq 0 ]; then
    exit 0
fi

to_fetch=()
for entry in "${missing[@]}"; do
    read -r repo path <<< "${entry}"
    [ -e "${STORE}/${path}" ] || to_fetch+=("${entry}")
done

for entry in "${to_fetch[@]}"; do
    read -r repo path <<< "${entry}"
    if [ "${repo}" = "${LTX_REPO}" ] && [ -z "${HF_TOKEN:-}" ]; then
        echo "download_models: ${path} is missing and HF_TOKEN is not set." >&2
        echo "download_models: Lightricks/LTX-2.5 is a gated repo. Accept the license at" >&2
        echo "download_models: https://huggingface.co/Lightricks/LTX-2.5 and set HF_TOKEN to a read token for that account." >&2
        exit 1
    fi
done

if [ "${#to_fetch[@]}" -gt 0 ]; then
    echo "download_models: downloading ${#to_fetch[@]} file(s) to ${STORE}"
    pids=()
    for entry in "${to_fetch[@]}"; do
        read -r repo path <<< "${entry}"
        fetch "${repo}/${path}" "${STORE}/${path}" &
        pids+=("$!")
    done

    failed=0
    for pid in "${pids[@]}"; do
        wait "${pid}" || failed=1
    done
    if [ "${failed}" -ne 0 ]; then
        echo "download_models: a 401 or 403 above means HF_TOKEN is wrong, or its account has not accepted the license at https://huggingface.co/Lightricks/LTX-2.5" >&2
        exit 1
    fi
fi

if [ "${STORE}" != "${COMFY_MODELS}" ]; then
    for entry in "${missing[@]}"; do
        read -r repo path <<< "${entry}"
        mkdir -p "$(dirname "${COMFY_MODELS}/${path}")"
        ln -sf "${STORE}/${path}" "${COMFY_MODELS}/${path}"
    done
fi

echo "download_models: all model files are in place"
