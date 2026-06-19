
ARG BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04
FROM ${BASE_IMAGE} AS base
# Ensure PyTorch is installed in ComfyUI's own venv
RUN /comfyui/.venv/bin/python -m pip install --upgrade pip && \
    /comfyui/.venv/bin/python -m pip install torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu126
# Define build-time  --build-arg during build)
ARG COMFYUI_VERSION=
ARG CUDA_VERSION_FOR_COMFY
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL

# Configure foundational system environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8

# ==========================
# =============================================================================
# Installs core Linux utilities and heavy graphics libraries required by OpenCV (cv2) and FFmpeg
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
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip
# Clean up apt caches to save space and minimize final Docker image size
RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# =============================================================================
# 3. PYTHON ENVIRONMENT MANAGEMENT (UV & CORE VENV)
# =============================================================================
# Download and install 'uv' (an extremely fast alternative to pip) and initialize a master venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

# Force the container environment to prioritize the newly created virtual environment
ENV PATH="/opt/venv/bin:${PATH}"

# Upgrade foundational installation primitives inside the core virtual environment
RUN /opt/venv/bin/python -m ensurepip --upgrade \
    && /opt/venv/bin/python -m pip install --upgrade pip setuptools wheel

# =============================================================================
# 4. COMFYUI FRAMEWORK INSTALLATION
# =============================================================================
# Install the ComfyUI command-line utility globally inside our virtual environment
RUN /opt/venv/bin/python -m pip install comfy-cli

# Conditional installation script blocks to install ComfyUI with specified parameters
RUN set -eux; \
    if [ -n "${CUDA_VERSION_FOR_COMFY:-}" ]; then \
        if [ -n "${COMFYUI_VERSION:-}" ]; then \
            /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
        else \
            /usr/bin/yes | comfy --workspace /comfyui install --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
        fi; \
    else \
        if [ -n "${COMFYUI_VERSION:-}" ]; then \
            /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
        else \
            /usr/bin/yes | comfy --workspace /comfyui install --nvidia; \
        fi; \
    fi

# Upgrades PyTorch if a custom index URL is specified (useful for aligning cutting-edge CUDA runtimes)
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
    /opt/venv/bin/python -m pip install --force-reinstall torch torchvision torchaudio --index-url ${PYTORCH_INDEX_URL}; \
    fi

ENV COMFYUI_DIR=/comfyui

# =============================================================================
# 5. RUNPOD SPECIFIC INFRASTRUCTURE SETUP
# =============================================================================
# Add custom extra model paths to direct ComfyUI's model loaders to correct structural paths
ADD src/extra_model_paths.yaml /comfyui/extra_model_paths.yaml
ADD src/extra_model_paths.yaml /comfyui/ComfyUI/extra_model_paths.yaml

WORKDIR /

# Install foundational Python infrastructure required for RunPod serverless handlers
RUN /opt/venv/bin/python -m pip install runpod requests websocket-client

# Add RunPod specific application code, server hooks, and scripts
ADD src/start.sh src/network_volume.py src/handler.py ./
COPY src/workflow.json /workflow.json
RUN chmod +x /start.sh

COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

ENV PIP_NO_INPUT=1

COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

# =============================================================================
# 6. CUSTOM NODES SETUP (WANVIDEO & SVI WORKFLOW DEPENDENCIES)
# =============================================================================
RUN mkdir -p /comfyui/custom_nodes

# Step A: Upgrade python installation managers within ComfyUI's internal workspace environment
RUN /comfyui/.venv/bin/python -m pip install --no-cache-dir --upgrade pip setuptools wheel

# Step B: Install exhaustive python prerequisite packages required by modern video architectures
RUN /comfyui/.venv/bin/python -m pip install --no-cache-dir \
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
    transformers\
    sageattention

# Step C: Clone Required Custom Nodes and check for internal secondary dependencies
# Clone KJNodes (Handles core math logic, image transformations, and structural loaders)
RUN git clone --depth 1 https://github.com/kijai/ComfyUI-KJNodes.git /comfyui/custom_nodes/ComfyUI-KJNodes && \
    if [ -f /comfyui/custom_nodes/ComfyUI-KJNodes/requirements.txt ]; then \
        /comfyui/.venv/bin/python -m pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-KJNodes/requirements.txt; \
    fi

# Clone VideoHelperSuite (Provides video compilation, tracking arrays, and frames extraction hooks)
RUN git clone --depth 1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git /comfyui/custom_nodes/ComfyUI-VideoHelperSuite && \
    if [ -f /comfyui/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt ]; then \
        /comfyui/.venv/bin/python -m pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt; \
    fi

# Clone WanVideoWrapper (Implements foundational wrappers for running the WanVideo model suite natively)
RUN git clone --depth 1 https://github.com/kijai/ComfyUI-WanVideoWrapper.git /comfyui/custom_nodes/ComfyUI-WanVideoWrapper && \
    if [ -f /comfyui/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt ]; then \
        /comfyui/.venv/bin/python -m pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt; \
    fi

# Clone Logic Nodes (Provides SetNode/GetNode primitives to process non-linear global variable graphs)
RUN git clone --depth 1 https://github.com/theUpsider/ComfyUI-Logic.git /comfyui/custom_nodes/ComfyUI-Logic && \
    if [ -f /comfyui/custom_nodes/ComfyUI-Logic/requirements.txt ]; then \
        /comfyui/.venv/bin/python -m pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-Logic/requirements.txt; \
    fi
RUN git clone --depth 1 https://github.com/Well-Made/ComfyUI-Wan-SVI2Pro-FLF.git /comfyui/custom_nodes/ComfyUI-Wan-SVI2Pro-FLF && \
    if [ -f /comfyui/custom_nodes/ComfyUI-Wan-SVI2Pro-FLF/requirements.txt ]; then \
        /comfyui/.venv/bin/python -m pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-Wan-SVI2Pro-FLF/requirements.txt; \
    fi
# =============================================================================
# 7. MODEL DOWNLOAD LAYER (WITH RE-TRY BACKOFF LOOP STRATEGY)
# =============================================================================
# Note: Every command runs a looped sequence of up to 5 attempts with incremental backoffs (10s -> 20s -> 30s...) 
# to shield the image build from random Hugging Face connection drops.


# =============================================================================
# 8. INPUT ASSET SEEDING & ENTRYPOINT RUNTIME
# =============================================================================
# Generate baseline input file paths and seed the default initialization source image
RUN mkdir -p /comfyui/input
RUN wget --progress=dot:giga \
    -O '/comfyui/input/Gemini_Generated_Image_jk7o1njk7o1njk7o.png' \
    "https://cool-anteater-319.convex.cloud/api/storage/0c172877-f42a-4fa0-89ea-d40d82991fa6"

# Setup the RunPod entrypoint file execution array
ENTRYPOINT ["/bin/bash", "/start.sh"]
