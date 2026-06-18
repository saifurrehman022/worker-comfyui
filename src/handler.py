import os
import time
import json
import base64
import requests
import runpod

COMFY_HOST = os.environ.get("COMFY_HOST", "127.0.0.1")
COMFY_PORT = int(os.environ.get("COMFY_PORT", "8188"))
COMFY_BASE = f"http://{COMFY_HOST}:{COMFY_PORT}"
COMFY_READY_TIMEOUT = int(os.environ.get("COMFY_READY_TIMEOUT", "1800"))

SUPABASE_URL    = os.environ.get("SUPABASE_URL", "https://yaiygjwbtzevjpxncvzu.supabase.co")
SUPABASE_KEY    = os.environ.get("SUPABASE_KEY", "")
SUPABASE_BUCKET = os.environ.get("SUPABASE_BUCKET", "videos")

DEFAULT_WORKFLOW_PATH = "/workflow.json"

COMFY_OUTPUT_DIRS = [
    "/comfyui/output",
    "/comfyui/ComfyUI/output",
    "/root/comfyui/output",
]

OUTPUT_NODE_TYPES = {
    "SaveImage", "SaveAnimatedWEBP", "SaveAnimatedPNG",
    "SaveAnimatedGIF", "SaveVideo", "VHS_VideoCombine", "PreviewImage",
}

# The final VHS_VideoCombine node — contains ALL 40 scenes stitched together
FINAL_VHS_NODE_ID = "1227"

# LoadImage node — the starting input image
LOAD_IMAGE_NODE_ID = "58"

# BasicScheduler/WanVideoSampler steps — applies to all 40 samplers
DEFAULT_STEPS = 8

_comfy_ready = False


# ===========================================================================
# SUPABASE
# ===========================================================================

def supabase_upload(local_path: str, remote_filename: str) -> str:
    if not SUPABASE_KEY:
        raise RuntimeError("SUPABASE_KEY env var not set.")
    url = f"{SUPABASE_URL}/storage/v1/object/{SUPABASE_BUCKET}/{remote_filename}"
    with open(local_path, "rb") as f:
        resp = requests.post(
            url,
            headers={
                "Authorization": f"Bearer {SUPABASE_KEY}",
                "Content-Type": "video/mp4",
                "x-upsert": "true",
            },
            data=f,
            timeout=300,
        )
    if resp.status_code not in (200, 201):
        raise RuntimeError(f"Supabase upload failed {resp.status_code}: {resp.text}")
    public_url = f"{SUPABASE_URL}/storage/v1/object/public/{SUPABASE_BUCKET}/{remote_filename}"
    print(f"[supabase] -> {public_url}")
    return public_url


# ===========================================================================
# COMFY HELPERS
# ===========================================================================

def wait_for_comfy():
    global _comfy_ready
    if _comfy_ready:
        return
    start = time.time()
    last_err = None
    while time.time() - start < COMFY_READY_TIMEOUT:
        try:
            r = requests.get(f"{COMFY_BASE}/system_stats", timeout=3)
            if r.status_code == 200:
                _comfy_ready = True
                return
        except Exception as e:
            last_err = e
        time.sleep(1.0)
    raise RuntimeError(f"ComfyUI not ready: {last_err}")


def comfy_get(path):
    r = requests.get(f"{COMFY_BASE}{path}", timeout=30)
    r.raise_for_status()
    return r.json()


def load_default_workflow():
    with open(DEFAULT_WORKFLOW_PATH) as f:
        return json.load(f)


def find_output_dir():
    for d in COMFY_OUTPUT_DIRS:
        if os.path.isdir(d):
            return d
    return COMFY_OUTPUT_DIRS[0]


def fetch_image_from_url(url: str, filename: str = "input_image.png") -> str:
    resp = requests.get(url, timeout=60)
    resp.raise_for_status()
    image_bytes = resp.content
    ct = resp.headers.get("Content-Type", "")
    if "jpeg" in ct or "jpg" in ct:
        filename = filename.replace(".png", ".jpg")
    elif "webp" in ct:
        filename = filename.replace(".png", ".webp")
    upload_resp = requests.post(
        f"{COMFY_BASE}/upload/image",
        files={"image": (filename, image_bytes, ct or "image/png")},
        data={"overwrite": "true"},
        timeout=60,
    )
    upload_resp.raise_for_status()
    return upload_resp.json().get("name", filename)


def upload_images_to_comfy(images):
    uploaded = []
    for img in images:
        name = img["name"]
        b64 = img["image"]
        if "," in b64:
            b64 = b64.split(",", 1)[1]
        image_bytes = base64.b64decode(b64)
        resp = requests.post(
            f"{COMFY_BASE}/upload/image",
            files={"image": (name, image_bytes, "image/png")},
            data={"overwrite": "true"},
            timeout=60,
        )
        resp.raise_for_status()
        uploaded.append(resp.json().get("name", name))
    return uploaded


def resolve_input_image(payload: dict):
    for key in ("image_url", "source_url", "target_url"):
        url = payload.get(key)
        if url:
            return fetch_image_from_url(url, f"{key.replace('_url','')}_image.png")
    images = payload.get("images", [])
    if images:
        uploaded = upload_images_to_comfy(images)
        if uploaded:
            return uploaded[0]
    return None


def submit_prompt(prompt, client_id="runpod"):
    r = requests.post(
        f"{COMFY_BASE}/prompt",
        json={"prompt": prompt, "client_id": client_id},
        timeout=60,
    )
    r.raise_for_status()
    return r.json()


def wait_for_history(prompt_id, poll_interval=2.0, timeout=28800):
    """8 hour timeout — 40 scenes can take a very long time."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            r = requests.get(f"{COMFY_BASE}/history/{prompt_id}", timeout=30)
            r.raise_for_status()
            data = r.json()
            if prompt_id in data:
                return data[prompt_id]
        except requests.exceptions.ConnectionError:
            print("[wait_for_history] Connection dropped, retrying in 5s...")
            time.sleep(5)
            continue
        time.sleep(poll_interval)
    raise RuntimeError(f"Prompt {prompt_id} did not finish within {timeout}s")


def get_output_filepaths(history):
    output_dir = find_output_dir()
    files = []
    for _, node_output in history.get("outputs", {}).items():
        for key in ("images", "videos", "gifs", "files"):
            for item in node_output.get(key, []):
                if item.get("type") == "temp":
                    continue
                fname     = item.get("filename", "")
                subfolder = item.get("subfolder", "")
                fpath = (
                    os.path.join(output_dir, subfolder, fname)
                    if subfolder else
                    os.path.join(output_dir, fname)
                )
                if os.path.isfile(fpath):
                    size = os.path.getsize(fpath)
                    files.append({"filename": fname, "filepath": fpath, "size": size})
                    print(f"[output] Found: {fname} ({size/1024/1024:.1f} MB)")
    files.sort(key=lambda x: x["size"], reverse=True)
    return files


def workflow_has_output_node(workflow):
    return any(
        isinstance(node, dict) and node.get("class_type") in OUTPUT_NODE_TYPES
        for node in workflow.values()
    )


# ===========================================================================
# WORKFLOW PATCHING
# Patches the baked 40-scene workflow:
#   - LoadImage (node 58) -> starting image
#   - All WanVideoTextEncode nodes -> per-scene prompts (in node-ID order)
#   - All WanVideoSampler nodes -> steps override
#   - Final VHS_VideoCombine (node 1227) -> save_output=True, frame_rate
# ===========================================================================

def get_ordered_text_encode_nodes(workflow):
    """Return WanVideoTextEncode node IDs sorted by node ID (matches scene order)."""
    nodes = [
        k for k, v in workflow.items()
        if isinstance(v, dict) and v.get("class_type") == "WanVideoTextEncode"
    ]
    return sorted(nodes, key=lambda x: int(x))


def get_all_sampler_nodes(workflow):
    return [
        k for k, v in workflow.items()
        if isinstance(v, dict) and v.get("class_type") == "WanVideoSampler"
    ]


def patch_workflow(workflow, uploaded_filename=None, prompts=None,
                   negative_prompt=None, sampling_steps=None, fps=None):
    """
    prompts: list of strings — one per scene. If fewer than 40 given,
             remaining scenes keep their original baked-in prompt.
             If more than 40 given, extras are ignored (workflow only has 40 slots).
    """
    # 1. Patch starting image
    if uploaded_filename:
        if LOAD_IMAGE_NODE_ID in workflow:
            workflow[LOAD_IMAGE_NODE_ID]["inputs"]["image"] = uploaded_filename

    # 2. Patch per-scene prompts in node-ID order
    text_nodes = get_ordered_text_encode_nodes(workflow)
    print(f"[patch] Found {len(text_nodes)} scene prompt nodes")

    if prompts:
        for i, node_id in enumerate(text_nodes):
            if i < len(prompts):
                workflow[node_id]["inputs"]["positive_prompt"] = prompts[i]
            if negative_prompt:
                workflow[node_id]["inputs"]["negative_prompt"] = negative_prompt
    elif negative_prompt:
        for node_id in text_nodes:
            workflow[node_id]["inputs"]["negative_prompt"] = negative_prompt

    # 3. Patch sampling steps on all WanVideoSampler nodes
    if sampling_steps is not None:
        sampler_nodes = get_all_sampler_nodes(workflow)
        for node_id in sampler_nodes:
            workflow[node_id]["inputs"]["steps"] = int(sampling_steps)
        print(f"[patch] Set steps={sampling_steps} on {len(sampler_nodes)} samplers")

    # 4. Ensure final output node actually saves to disk
    if FINAL_VHS_NODE_ID in workflow:
        workflow[FINAL_VHS_NODE_ID]["inputs"]["save_output"] = True
        if fps:
            workflow[FINAL_VHS_NODE_ID]["inputs"]["frame_rate"] = int(fps)

    return workflow


# ===========================================================================
# MAIN HANDLER
# ===========================================================================

def handler(job):
    payload = job.get("input") or {}
    action  = payload.get("action")

    if action == "ping":
        return {"status": "ok"}
    if action == "comfy_system_stats":
        wait_for_comfy()
        return comfy_get("/system_stats")

    wait_for_comfy()

    workflow = payload.get("workflow") or payload.get("prompt")
    if workflow:
        if isinstance(workflow, str):
            workflow = json.loads(workflow)
    else:
        workflow = load_default_workflow()

    if not workflow_has_output_node(workflow):
        raise RuntimeError("Workflow has no output node.")

    uploaded_filename = resolve_input_image(payload)

    # Prompts: list of up to 40 strings, one per scene
    prompts = payload.get("prompts")
    if prompts and not isinstance(prompts, list):
        prompts = [prompts]

    negative_prompt = payload.get("negative_prompt")
    sampling_steps   = payload.get("sampling_steps", DEFAULT_STEPS)
    fps              = payload.get("fps", 16)

    print(f"[handler] Patching workflow: image={uploaded_filename}, "
          f"prompts={len(prompts) if prompts else 0} scenes, steps={sampling_steps}")

    workflow = patch_workflow(
        workflow,
        uploaded_filename=uploaded_filename,
        prompts=prompts,
        negative_prompt=negative_prompt,
        sampling_steps=sampling_steps,
        fps=fps,
    )

    result    = submit_prompt(workflow, payload.get("client_id", "runpod"))
    prompt_id = result.get("prompt_id")
    if not prompt_id:
        raise RuntimeError(f"No prompt_id from ComfyUI: {result}")

    print(f"[handler] Submitted prompt_id={prompt_id}, waiting for 40-scene render "
          f"(this can take hours)...")

    history = wait_for_history(prompt_id, timeout=28800)
    files   = get_output_filepaths(history)

    if not files:
        raise RuntimeError("Job completed but no output files found.")

    # Largest file = final stitched 40-scene video
    final_path     = files[0]["filepath"]
    job_id         = job.get("id", f"job_{int(time.time())}")
    final_filename = f"{job_id}_final.mp4"

    final_url = supabase_upload(final_path, final_filename)
    print(f"[handler] Final video -> {final_url}")

    return {
        "status":          "success",
        "prompt_id":        prompt_id,
        "final_video_url":  final_url,
        "total_scenes":     len(get_ordered_text_encode_nodes(workflow)),
    }


runpod.serverless.start({"handler": handler})
