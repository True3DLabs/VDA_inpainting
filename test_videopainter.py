#!/usr/bin/env python3
"""Test script to run VideoPainter on existing dev_cinema output"""
import sys
from pathlib import Path
import torch
import numpy as np
from PIL import Image
import cv2
import re

# Add VideoPainter diffusers to path
SCRIPT_DIR = Path(__file__).parent
VIDEOPAINTER_DIR = SCRIPT_DIR / "VideoPainter"
sys.path.insert(0, str(VIDEOPAINTER_DIR / "diffusers" / "src"))

from diffusers import (
    CogVideoXDPMScheduler,
    CogvideoXBranchModel,
    CogVideoXI2VDualInpaintAnyLPipeline,
)
from diffusers.utils import export_to_video

# Parameters
PROMPT = "fill the missing regions realistically"
NUM_STEPS = 50
GUIDANCE_SCALE = 6.0
FPS = 8
SEED = 42

if __name__ == "__main__":
    root_dir = Path("outputs/dev_cinema-1763749773")
    filled_first_frame_path = root_dir / "infilled" / "frame_000001.png"
    model_path = str(VIDEOPAINTER_DIR / "ckpt" / "CogVideoX-5b-I2V")
    branch_path = str(VIDEOPAINTER_DIR / "ckpt" / "VideoPainter" / "VideoPainter" / "checkpoints" / "branch")
    
    if not filled_first_frame_path.exists():
        print(f"Error: Filled first frame not found at {filled_first_frame_path}")
        sys.exit(1)
    
    print(f"Testing VideoPainter on {root_dir}")
    print(f"Filled first frame: {filled_first_frame_path}")
    print(f"Model path: {model_path}")
    print(f"Branch path: {branch_path}")
    
    frames_dir = root_dir / "frames"
    masks_dir = root_dir / "masks"
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
        
        # Resize frame to match filled first frame resolution (maintaining aspect ratio, then padding)
        h, w = frame.shape[:2]
        target_h, target_w = target_size
        
        # Calculate scale to fit within target while maintaining aspect ratio
        scale = min(target_h / h, target_w / w)
        new_h = int(h * scale)
        new_w = int(w * scale)
        
        # Resize frame
        resized = cv2.resize(frame, (new_w, new_h), interpolation=cv2.INTER_LANCZOS4)
        resized_rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
        
        # Pad to target size (center the resized frame)
        pad_h = (target_h - new_h) // 2
        pad_w = (target_w - new_w) // 2
        
        expanded = np.zeros((target_h, target_w, 3), dtype=np.uint8)
        expanded[pad_h:pad_h+new_h, pad_w:pad_w+new_w] = resized_rgb
        video_frames.append(Image.fromarray(expanded, mode="RGB"))
        
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
    print(f"Using device: {device}, dtype: {dtype}")
    
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
    print(f"  Prompt: {PROMPT}")
    print(f"  Frames: {len(video_frames)}")
    print(f"  Steps: {NUM_STEPS}")
    print(f"  Guidance: {GUIDANCE_SCALE}")
    
    # Run inference
    generator = torch.Generator(device=device).manual_seed(SEED)
    # Set first frame mask to all zeros before calling pipeline (this makes it use first frame as GT)
    # The pipeline handles first_frame_gt internally based on mask values
    inpaint_outputs = pipe(
        prompt=PROMPT,
        image=image,
        num_videos_per_prompt=1,
        num_inference_steps=NUM_STEPS,
        num_frames=len(video_frames),
        use_dynamic_cfg=True,
        guidance_scale=GUIDANCE_SCALE,
        generator=generator,
        video=masked_video,
        masks=masks,
        strength=1.0,
        replace_gt=False,
        mask_add=True,
        output_type="np"
    )
    
    video_generate = inpaint_outputs.frames[0]
    
    # Save output video
    output_video_path = output_dir / "infilled_video.mp4"
    print(f"\nSaving infilled video to {output_video_path}...")
    export_to_video(video_generate, str(output_video_path), fps=FPS)
    
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
