ARG BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04
FROM ${BASE_IMAGE} AS base

ARG COMFYUI_VERSION=
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8 \
    PIP_NO_INPUT=1

# =============================================================================
# 2. SYSTEM DEPENDENCIES
# =============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    git \
    wget \
    curl \
    ca-certificates \
    build-essential \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3.12 /usr/bin/python

# =============================================================================
# 3. FAST PYTHON ENVIRONMENT WITH UV
# =============================================================================
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx

# Create the primary virtual environment that ComfyUI and RunPod WILL BOTH USE
RUN uv venv /comfyui/.venv
ENV PATH="/comfyui/.venv/bin:${PATH}"

# Install core infrastructure tools rapidly using uv
RUN uv pip install comfy-cli runpod requests websocket-client

# =============================================================================
# 4. COMFYUI & TARGET PYTORCH INSTALLATION (Single Pass)
# =============================================================================
# Install target PyTorch 12.6 wheels FIRST so comfy-cli doesn't download the wrong ones
RUN uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu126

# Install ComfyUI without forcing its own python/cuda reinstall loops
RUN if [ -n "${COMFYUI_VERSION:-}" ]; then \
        /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --skip-pip; \
    else \
        /usr/bin/yes | comfy --workspace /comfyui install --skip-pip; \
    fi

ENV COMFYUI_DIR=/comfyui
WORKDIR /

# =============================================================================
# 5. RUNPOD INFRASTRUCTURE
# =============================================================================
ADD src/extra_model_paths.yaml /comfyui/extra_model_paths.yaml
ADD src/extra_model_paths.yaml /comfyui/ComfyUI/extra_model_paths.yaml

ADD src/start.sh src/network_volume.py src/handler.py ./
COPY src/workflow.json /workflow.json
RUN chmod +x /start.sh

COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

# =============================================================================
# 6. CUSTOM NODES DEPENDENCIES (Speed optimized via UV)
# =============================================================================
RUN mkdir -p /comfyui/custom_nodes

# Fast multi-threaded installation of heavy math dependencies
RUN uv pip install \
    opencv-python-headless \
    imageio-ffmpeg \
    accelerate \
    diffusers \
    peft \
    einops \
    sentencepiece \
    protobuf \
    pyloudnorm \
    gguf \
    ftfy \
    color-matcher \
    matplotlib \
    mss \
    onnxruntime-gpu \
    transformers \
    sageattention

# KJNodes
RUN git clone --depth 1 https://github.com/kijai/ComfyUI-KJNodes.git /comfyui/custom_nodes/ComfyUI-KJNodes && \
    if [ -f /comfyui/custom_nodes/ComfyUI-KJNodes/requirements.txt ]; then \
        uv pip install -r /comfyui/custom_nodes/ComfyUI-KJNodes/requirements.txt; \
    fi

# VideoHelperSuite
RUN git clone --depth 1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git /comfyui/custom_nodes/ComfyUI-VideoHelperSuite && \
    if [ -f /comfyui/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt ]; then \
        uv pip install -r /comfyui/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt; \
    fi

# WanVideoWrapper
RUN git clone --depth 1 https://github.com/kijai/ComfyUI-WanVideoWrapper.git /comfyui/custom_nodes/ComfyUI-WanVideoWrapper && \
    if [ -f /comfyui/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt ]; then \
        uv pip install -r /comfyui/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt; \
    fi

# Logic Nodes
RUN git clone --depth 1 https://github.com/theUpsider/ComfyUI-Logic.git /comfyui/custom_nodes/ComfyUI-Logic && \
    if [ -f /comfyui/custom_nodes/ComfyUI-Logic/requirements.txt ]; then \
        uv pip install -r /comfyui/custom_nodes/ComfyUI-Logic/requirements.txt; \
    fi

# SVI Pro FLF
RUN git clone --depth 1 https://github.com/Well-Made/ComfyUI-Wan-SVI2Pro-FLF.git /comfyui/custom_nodes/ComfyUI-Wan-SVI2Pro-FLF && \
    if [ -f /comfyui/custom_nodes/ComfyUI-Wan-SVI2Pro-FLF/requirements.txt ]; then \
        uv pip install -r /comfyui/custom_nodes/ComfyUI-Wan-SVI2Pro-FLF/requirements.txt; \
    fi

# =============================================================================
# 8. INPUT ASSETS
# =============================================================================
RUN mkdir -p /comfyui/input
RUN wget --progress=dot:giga \
    -O '/comfyui/input/first-frame.png' \
    "https://cool-anteater-319.convex.cloud/api/storage/0c172877-f42a-4fa0-89ea-d40d82991fa6"

ENTRYPOINT ["/bin/bash", "/start.sh"]
