#!/usr/bin/env python3
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np
import torch
from PIL import Image

SCRIPT_DIR = Path(__file__).parent
FLUX_FILL_SCRIPT = SCRIPT_DIR / "FLUX-Fill" / "flux_fill_transparent.py"
VIDEOPAINTER_DIR = SCRIPT_DIR / "VideoPainter"

# Add VideoPainter diffusers to path
sys.path.insert(0, str(VIDEOPAINTER_DIR / "diffusers" / "src"))

# Hardcoded parameters
EXPAND_PERCENT = 0.15  # Expand by 15% on each side
MAX_HEIGHT = 1024
MAX_WIDTH = 1024
PROMPT = "fill the missing regions realistically"
STEPS = 40
GUIDANCE = 12.0
SEED = 42
ALPHA_THRESHOLD = 128
DILATE = 7
FEATHER = 5
MAX_SEQ_LENGTH = 512

# VideoPainter parameters
VIDEOPAINTER_MODEL_PATH = os.getenv("VIDEOPAINTER_MODEL_PATH", str(VIDEOPAINTER_DIR / "ckpt" / "CogVideoX-5b-I2V"))
VIDEOPAINTER_BRANCH_PATH = os.getenv("VIDEOPAINTER_BRANCH_PATH", str(VIDEOPAINTER_DIR / "ckpt" / "VideoPainter" / "VideoPainter" / "checkpoints" / "branch"))
VIDEOPAINTER_NUM_STEPS = 50
VIDEOPAINTER_GUIDANCE_SCALE = 6.0
VIDEOPAINTER_FPS = 24


def expand_frame_with_alpha(frame: np.ndarray, expand_percent: float) -> Image.Image:
    """Expand frame on all sides with transparent alpha channel."""
    h, w = frame.shape[:2]
    
    expand_h = int(h * expand_percent)
    expand_w = int(w * expand_percent)
    
    new_h = h + 2 * expand_h
    new_w = w + 2 * expand_w
    
    # Convert BGR to RGB if needed
    if len(frame.shape) == 3 and frame.shape[2] == 3:
        rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    else:
        rgb_frame = frame
    
    # Create RGBA image
    rgba = np.zeros((new_h, new_w, 4), dtype=np.uint8)
    
    # Place original frame in center
    rgba[expand_h:expand_h+h, expand_w:expand_w+w, :3] = rgb_frame
    rgba[expand_h:expand_h+h, expand_w:expand_w+w, 3] = 255  # Full alpha for original
    
    return Image.fromarray(rgba, mode="RGBA")


def resize_if_needed(image: Image.Image, max_h: int, max_w: int) -> Image.Image:
    """Resize image if it exceeds max dimensions, maintaining aspect ratio."""
    w, h = image.size
    if h <= max_h and w <= max_w:
        return image
    
    scale = min(max_h / h, max_w / w)
    new_w = int(w * scale)
    new_h = int(h * scale)
    return image.resize((new_w, new_h), Image.Resampling.LANCZOS)


def expand_frame_to_match(frame: np.ndarray, target_size: tuple) -> Image.Image:
    """Resize frame to match target size, maintaining aspect ratio and padding if needed."""
    h, w = frame.shape[:2]
    target_h, target_w = target_size
    
    # Calculate scale to fit within target while maintaining aspect ratio
    scale = min(target_h / h, target_w / w)
    new_h = int(h * scale)
    new_w = int(w * scale)
    
    # Resize frame
    resized = cv2.resize(frame, (new_w, new_h), interpolation=cv2.INTER_LANCZOS4)
    
    # Convert BGR to RGB if needed
    if len(resized.shape) == 3 and resized.shape[2] == 3:
        rgb_frame = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
    else:
        rgb_frame = resized
    
    # Pad to target size (center the resized frame)
    pad_h = (target_h - new_h) // 2
    pad_w = (target_w - new_w) // 2
    
    # Create expanded image
    expanded = np.zeros((target_h, target_w, 3), dtype=np.uint8)
    expanded[pad_h:pad_h+new_h, pad_w:pad_w+new_w] = rgb_frame
    
    return Image.fromarray(expanded, mode="RGB")


def infill_video_with_videopainter(
    root_dir: Path,
    filled_first_frame_path: Path,
    model_path: str,
    branch_path: str,
    prompt: str = PROMPT,
    num_inference_steps: int = VIDEOPAINTER_NUM_STEPS,
    guidance_scale: float = VIDEOPAINTER_GUIDANCE_SCALE,
    fps: int = VIDEOPAINTER_FPS,
):
    """Use VideoPainter to infill remaining video frames."""
    # Check if running in videopainter environment
    import subprocess
    env_check = subprocess.run(
        ["micromamba", "run", "-n", "videopainter", "python", "-c", "import sys; print(sys.executable)"],
        capture_output=True,
        text=True
    )
    use_videopainter_env = env_check.returncode == 0
    if not use_videopainter_env:
        print(f"Note: videopainter micromamba environment not found (return code: {env_check.returncode})")
        if env_check.stderr:
            print(f"Error message: {env_check.stderr}")
        print("Will attempt to use VideoPainter from current environment...")
    
    try:
        if use_videopainter_env:
            # Run VideoPainter in the videopainter environment
            print("Using VideoPainter micromamba environment: videopainter")
            import subprocess
            script_content = f'''
import sys
sys.path.insert(0, "{VIDEOPAINTER_DIR / "diffusers" / "src"}")

from pathlib import Path
import torch
import numpy as np
from PIL import Image
import cv2
import re

from diffusers import (
    CogVideoXDPMScheduler,
    CogvideoXBranchModel,
    CogVideoXI2VDualInpaintAnyLPipeline,
)
from diffusers.utils import export_to_video

# Your infill_video_with_videopainter code here
root_dir = Path("{root_dir}")
frames_dir = root_dir / "frames"
masks_dir = root_dir / "masks"
infilled_dir = root_dir / "infilled"
output_dir = root_dir / "output"
output_dir.mkdir(exist_ok=True)

filled_first_frame = Image.open("{filled_first_frame_path}").convert("RGB")
target_size = filled_first_frame.size[::-1]

frame_files = sorted(frames_dir.glob("frame_*.png"))
print(f"Loading {{len(frame_files)}} frames...")

video_frames = []
masks = []

for i, frame_file in enumerate(frame_files):
    frame = cv2.imread(str(frame_file))
    if frame is None:
        continue
    
    h, w = frame.shape[:2]
    target_h, target_w = target_size
    pad_h = (target_h - h) // 2
    pad_w = (target_w - w) // 2
    
    expanded = np.zeros((target_h, target_w, 3), dtype=np.uint8)
    expanded[pad_h:pad_h+h, pad_w:pad_w+w] = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    video_frames.append(Image.fromarray(expanded, mode="RGB"))
    
    frame_match = re.search(r'frame_(\\d+)\\.png', frame_file.name)
    if frame_match:
        frame_num = frame_match.group(1)
        mask_path = masks_dir / f"frame_{{frame_num}}.png"
        if mask_path.exists():
            mask = Image.open(mask_path).convert("L")
            if mask.size != filled_first_frame.size:
                mask = mask.resize(filled_first_frame.size, Image.Resampling.LANCZOS)
            mask_array = np.array(mask)
            mask_array = (mask_array > 127).astype(np.uint8) * 255
            mask = Image.fromarray(mask_array, mode="L").convert("RGB")
            masks.append(mask)
        else:
            masks.append(Image.new("RGB", filled_first_frame.size, (0, 0, 0)))

if not video_frames:
    raise RuntimeError("No frames loaded")

print(f"Loaded {{len(video_frames)}} frames and {{len(masks)}} masks")

dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32
device = "cuda" if torch.cuda.is_available() else "cpu"

print(f"Loading VideoPainter model from {model_path}...")
branch = CogvideoXBranchModel.from_pretrained("{branch_path}", torch_dtype=dtype).to(device)
pipe = CogVideoXI2VDualInpaintAnyLPipeline.from_pretrained(
    "{model_path}",
    branch=branch,
    torch_dtype=dtype,
)
pipe.scheduler = CogVideoXDPMScheduler.from_config(pipe.scheduler.config, timestep_spacing="trailing")
pipe.to(device)

image = filled_first_frame
masked_video = video_frames.copy()
masks[0] = Image.new("RGB", filled_first_frame.size, (0, 0, 0))

print(f"Running VideoPainter inference...")
generator = torch.Generator(device=device).manual_seed({SEED})
inpaint_outputs = pipe(
    prompt="{prompt}",
    image=image,
    num_videos_per_prompt=1,
    num_inference_steps={num_inference_steps},
    num_frames=len(video_frames),
    use_dynamic_cfg=True,
    guidance_scale={guidance_scale},
    generator=generator,
    video=masked_video,
    masks=masks,
    strength=1.0,
    replace_gt=False,
    mask_add=True,
    first_frame_gt=True,
    output_type="np"
)

video_generate = inpaint_outputs.frames[0]

output_video_path = output_dir / "infilled_video.mp4"
print(f"Saving infilled video to {{output_video_path}}...")
export_to_video(video_generate, str(output_video_path), fps={fps})

infilled_frames_dir = root_dir / "infilled_frames"
infilled_frames_dir.mkdir(exist_ok=True)

print(f"Saving individual infilled frames...")
for i, frame in enumerate(video_generate):
    frame_img = Image.fromarray(frame)
    frame_img.save(infilled_frames_dir / f"frame_{{i+1:06d}}.png")

print(f"VideoPainter infilling complete!")
'''
            # Write temporary script
            temp_script = root_dir / "_videopainter_infill.py"
            with open(temp_script, "w") as f:
                f.write(script_content)
            
            # Run in videopainter environment
            result = subprocess.run(
                ["micromamba", "run", "-n", "videopainter", "python", str(temp_script)],
                cwd=str(SCRIPT_DIR),
                capture_output=False,
            )
            
            # Clean up
            if temp_script.exists():
                temp_script.unlink()
            
            if result.returncode != 0:
                raise RuntimeError(f"VideoPainter inference failed with return code {result.returncode}")
            
            return output_dir / "infilled_video.mp4"
        else:
            # Fallback to direct import (if running in correct environment)
            from diffusers import (
                CogVideoXDPMScheduler,
                CogvideoXBranchModel,
                CogVideoXI2VDualInpaintAnyLPipeline,
            )
            from diffusers.utils import export_to_video
    except ImportError as e:
        print(f"Error importing VideoPainter: {e}", file=sys.stderr)
        print("Make sure VideoPainter diffusers is installed: cd VideoPainter/diffusers && pip install -e .", file=sys.stderr)
        print("Or activate the videopainter environment: micromamba activate videopainter", file=sys.stderr)
        raise
    
    root_dir = Path(root_dir)
    frames_dir = root_dir / "frames"
    masks_dir = root_dir / "masks"
    infilled_dir = root_dir / "infilled"
    output_dir = root_dir / "output"
    output_dir.mkdir(exist_ok=True)
    
    # Load filled first frame to get target resolution
    filled_first_frame = Image.open(filled_first_frame_path).convert("RGB")
    target_size = filled_first_frame.size[::-1]  # (height, width)
    print(f"Target resolution: {target_size[1]}x{target_size[0]}")
    
    # Load all frames and expand them to match filled frame resolution
    frame_files = sorted(frames_dir.glob("frame_*.png"))
    print(f"\nLoading and expanding {len(frame_files)} frames...")
    
    video_frames = []
    masks = []
    
    for i, frame_file in enumerate(frame_files):
        frame = cv2.imread(str(frame_file))
        if frame is None:
            print(f"Warning: Failed to load {frame_file}, skipping", file=sys.stderr)
            continue
        
        # Expand frame to match filled first frame resolution
        expanded_frame = expand_frame_to_match(frame, target_size)
        video_frames.append(expanded_frame)
        
        # Load corresponding mask
        frame_match = re.search(r'frame_(\d+)\.png', frame_file.name)
        if frame_match:
            frame_num = frame_match.group(1)
            mask_path = masks_dir / f"frame_{frame_num}.png"
            if mask_path.exists():
                mask = Image.open(mask_path).convert("L")  # Convert to grayscale
                # Resize mask if needed
                if mask.size != filled_first_frame.size:
                    mask = mask.resize(filled_first_frame.size, Image.Resampling.LANCZOS)
                # Convert to binary mask (0 or 255) and then to RGB
                mask_array = np.array(mask)
                mask_array = (mask_array > 127).astype(np.uint8) * 255
                mask = Image.fromarray(mask_array, mode="L").convert("RGB")
                masks.append(mask)
            else:
                print(f"Warning: Mask not found for {frame_file.name}, creating empty mask", file=sys.stderr)
                masks.append(Image.new("RGB", filled_first_frame.size, (0, 0, 0)))
        
        if (i + 1) % 50 == 0:
            print(f"  Processed {i + 1}/{len(frame_files)} frames...")
    
    if not video_frames:
        raise RuntimeError("No frames loaded")
    
    print(f"Loaded {len(video_frames)} frames and {len(masks)} masks")
    
    # Load VideoPainter pipeline
    print(f"\nLoading VideoPainter model from {model_path}...")
    print(f"Loading inpainting branch from {branch_path}...")
    
    dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32
    device = "cuda" if torch.cuda.is_available() else "cpu"
    
    branch = CogvideoXBranchModel.from_pretrained(branch_path, torch_dtype=dtype).to(device)
    pipe = CogVideoXI2VDualInpaintAnyLPipeline.from_pretrained(
        model_path,
        branch=branch,
        torch_dtype=dtype,
    )
    pipe.scheduler = CogVideoXDPMScheduler.from_config(pipe.scheduler.config, timestep_spacing="trailing")
    pipe.to(device)
    
    # Prepare inputs: use filled first frame, masked video frames, and masks
    image = filled_first_frame
    masked_video = video_frames.copy()
    
    # Set first frame mask to all zeros (use first frame as ground truth)
    first_mask = Image.new("RGB", filled_first_frame.size, (0, 0, 0))
    masks[0] = first_mask
    
    print(f"\nRunning VideoPainter inference...")
    print(f"  Prompt: {prompt}")
    print(f"  Frames: {len(video_frames)}")
    print(f"  Steps: {num_inference_steps}")
    print(f"  Guidance: {guidance_scale}")
    
    # Run inference
    generator = torch.Generator(device=device).manual_seed(SEED)
    inpaint_outputs = pipe(
        prompt=prompt,
        image=image,
        num_videos_per_prompt=1,
        num_inference_steps=num_inference_steps,
        num_frames=len(video_frames),
        use_dynamic_cfg=True,
        guidance_scale=guidance_scale,
        generator=generator,
        video=masked_video,
        masks=masks,
        strength=1.0,
        replace_gt=False,
        mask_add=True,
        first_frame_gt=True,
        output_type="np"
    )
    
    video_generate = inpaint_outputs.frames[0]
    
    # Save output video
    output_video_path = output_dir / "infilled_video.mp4"
    print(f"\nSaving infilled video to {output_video_path}...")
    export_to_video(video_generate, str(output_video_path), fps=fps)
    
    # Save individual frames
    infilled_frames_dir = root_dir / "infilled_frames"
    infilled_frames_dir.mkdir(exist_ok=True)
    
    print(f"Saving individual infilled frames to {infilled_frames_dir}...")
    for i, frame in enumerate(video_generate):
        frame_img = Image.fromarray(frame)
        frame_img.save(infilled_frames_dir / f"frame_{i+1:06d}.png")
    
    print(f"\nVideoPainter infilling complete!")
    print(f"  Output video: {output_video_path}")
    print(f"  Output frames: {infilled_frames_dir}")
    
    return output_video_path


def process_video_outpainting(
    video_path: str, 
    root_dir: Path, 
    skip_videopainter: bool = False,
    videopainter_model_path: str = None,
    videopainter_branch_path: str = None,
):
    """Process video for outpainting."""
    root_dir = Path(root_dir)
    frames_dir = root_dir / "frames"
    masks_dir = root_dir / "masks"
    infilled_dir = root_dir / "infilled"
    
    masks_dir.mkdir(parents=True, exist_ok=True)
    infilled_dir.mkdir(parents=True, exist_ok=True)
    
    # Read metadata to get FPS
    video_name = Path(video_path).stem
    metadata_file = root_dir / f"{video_name}_metadata.json"
    extraction_fps = VIDEOPAINTER_FPS
    if metadata_file.exists():
        try:
            with open(metadata_file, 'r') as f:
                metadata = json.load(f)
                # Try 'fps' first (new format), fallback to 'extraction_fps' (old format) for compatibility
                extraction_fps = metadata.get("fps") or metadata.get("extraction_fps", VIDEOPAINTER_FPS)
                print(f"Using FPS from metadata: {extraction_fps}")
        except Exception as e:
            print(f"Warning: Failed to read metadata file {metadata_file}: {e}", file=sys.stderr)
            print(f"Using default FPS: {VIDEOPAINTER_FPS}", file=sys.stderr)
    else:
        print(f"Warning: Metadata file not found at {metadata_file}, using default FPS: {VIDEOPAINTER_FPS}", file=sys.stderr)
    
    # Find first frame
    frame_files = sorted(frames_dir.glob("frame_*.png"))
    if not frame_files:
        raise RuntimeError(f"No frames found in {frames_dir}")
    
    first_frame_path = frame_files[0]
    print(f"Processing first frame: {first_frame_path}")
    
    # Load first frame and expand it
    first_frame = cv2.imread(str(first_frame_path))
    if first_frame is None:
        raise RuntimeError(f"Failed to load frame: {first_frame_path}")
    
    expanded_frame = expand_frame_with_alpha(first_frame, EXPAND_PERCENT)
    expanded_frame = resize_if_needed(expanded_frame, MAX_HEIGHT, MAX_WIDTH)
    
    # Save expanded frame temporarily
    expanded_init_path = root_dir / "expanded_init_frame.png"
    expanded_frame.save(expanded_init_path)
    print(f"Saved expanded initial frame to {expanded_init_path}")
    
    # Extract frame number from first frame filename
    frame_match = re.search(r'frame_(\d+)\.png', first_frame_path.name)
    if not frame_match:
        raise RuntimeError(f"Could not extract frame number from {first_frame_path.name}")
    first_frame_num = frame_match.group(1)
    
    # Fill the expanded frame using flux_fill
    print(f"\nFilling expanded frame using FLUX Fill...")
    filled_output_path = infilled_dir / f"frame_{first_frame_num}.png"
    mask_path = masks_dir / f"frame_{first_frame_num}.png"
    
    cmd = [
        sys.executable,
        str(FLUX_FILL_SCRIPT),
        "--input", str(expanded_init_path),
        "--output", str(filled_output_path),
        "--prompt", PROMPT,
        "--steps", str(STEPS),
        "--guidance", str(GUIDANCE),
        "--seed", str(SEED),
        "--alpha-threshold", str(ALPHA_THRESHOLD),
        "--dilate", str(DILATE),
        "--feather", str(FEATHER),
        "--max-seq-length", str(MAX_SEQ_LENGTH),
        "--save-mask",
        "--mask-output", str(mask_path),
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error running flux_fill: {result.stderr}", file=sys.stderr)
        raise RuntimeError(f"Failed to fill frame: {result.stderr}")
    
    print(f"Saved filled frame to {filled_output_path}")
    print(f"Saved mask to {mask_path}")
    
    # Duplicate mask for all frames (same mask applies to all frames)
    print(f"\nDuplicating mask for all {len(frame_files)} frames...")
    for frame_file in frame_files:
        frame_match = re.search(r'frame_(\d+)\.png', frame_file.name)
        if not frame_match:
            print(f"Warning: Could not extract frame number from {frame_file.name}, skipping", file=sys.stderr)
            continue
        
        frame_num = frame_match.group(1)
        
        # Copy mask
        frame_mask_path = masks_dir / f"frame_{frame_num}.png"
        if not frame_mask_path.exists():
            shutil.copy2(mask_path, frame_mask_path)
    
    print(f"Duplicated masks for all frames")
    
    # Use VideoPainter to infill remaining frames
    if not skip_videopainter:
        print(f"\n{'='*60}")
        print("Starting VideoPainter video infilling...")
        print(f"{'='*60}")
        
        try:
            model_path = videopainter_model_path if videopainter_model_path else str(VIDEOPAINTER_MODEL_PATH)
            branch_path = videopainter_branch_path if videopainter_branch_path else str(VIDEOPAINTER_BRANCH_PATH)
            print(f"VideoPainter model path: {model_path}")
            print(f"VideoPainter branch path: {branch_path}")
            infill_video_with_videopainter(
                root_dir=root_dir,
                filled_first_frame_path=filled_output_path,
                model_path=model_path,
                branch_path=branch_path,
                prompt=PROMPT,
                num_inference_steps=VIDEOPAINTER_NUM_STEPS,
                guidance_scale=VIDEOPAINTER_GUIDANCE_SCALE,
                fps=extraction_fps,
            )
        except Exception as e:
            print(f"\n{'='*60}", file=sys.stderr)
            print(f"ERROR: VideoPainter infilling failed: {e}", file=sys.stderr)
            print("First frame infilling completed, but video infilling was skipped.", file=sys.stderr)
            print(f"{'='*60}", file=sys.stderr)
            import traceback
            traceback.print_exc(file=sys.stderr)
            print("\nTo debug:", file=sys.stderr)
            print("1. Check if videopainter environment exists: micromamba env list", file=sys.stderr)
            print("2. Check if model paths exist:", file=sys.stderr)
            print(f"   Model: {model_path}", file=sys.stderr)
            print(f"   Branch: {branch_path}", file=sys.stderr)
    else:
        print("\nSkipping VideoPainter infilling (--skip-videopainter flag set)")
    
    print(f"\nOutput directory: {root_dir}")
    print(f"  - Frames: {frames_dir} ({len(frame_files)} frames)")
    print(f"  - Masks: {masks_dir} ({len(frame_files)} masks)")
    print(f"  - Infilled: {infilled_dir} (1 infilled image for frame {first_frame_num})")


def main():
    parser = argparse.ArgumentParser(
        description="Video outpainting: create outpainting masks, fill first frame, and infill video"
    )
    parser.add_argument("input_video", help="Path to input video file")
    parser.add_argument("root_dir", help="Root output directory (outputs/{name}-{timestamp})")
    parser.add_argument("--videopainter-model", type=str, default=None,
                       help="Path to VideoPainter base model")
    parser.add_argument("--videopainter-branch", type=str, default=None,
                       help="Path to VideoPainter branch model")
    parser.add_argument("--skip-videopainter", action="store_true",
                       help="Skip VideoPainter infilling step")
    args = parser.parse_args()
    
    model_path = args.videopainter_model if args.videopainter_model else str(VIDEOPAINTER_MODEL_PATH)
    branch_path = args.videopainter_branch if args.videopainter_branch else str(VIDEOPAINTER_BRANCH_PATH)
    
    process_video_outpainting(
        args.input_video, 
        args.root_dir, 
        skip_videopainter=args.skip_videopainter,
        videopainter_model_path=model_path,
        videopainter_branch_path=branch_path,
    )


if __name__ == "__main__":
    main()

