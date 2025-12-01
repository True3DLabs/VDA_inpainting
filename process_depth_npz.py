#!/usr/bin/env python3
"""
Process depth.npz file: apply Gaussian blur and ln(x+1) transformation,
then encode to processed_depth.mp4 video.
"""

import argparse
import numpy as np
from pathlib import Path
import imageio
from scipy import ndimage

# Constants
DEFAULT_BLUR_SIGMA = 5.0  # Gaussian blur sigma in pixels
LOG_BASE = 4.0  # Natural logarithm base (e)


def process_depth_npz(
    input_npz: Path,
    output_video: Path,
    blur_sigma: float = DEFAULT_BLUR_SIGMA,
    fps: float = 24.0,
) -> None:
    """
    Process depth.npz file and save as video.
    
    Args:
        input_npz: Path to input depth.npz file
        output_video: Path to output video file
        blur_sigma: Gaussian blur sigma in pixels (default: 5.0)
        fps: Frames per second for output video (default: 24.0)
    """
    print(f"Loading depth data from: {input_npz}")
    
    # Load depth data
    data = np.load(input_npz)
    if 'depth' not in data:
        raise ValueError(f"No 'depth' key found in {input_npz}. Available keys: {list(data.keys())}")
    
    depths = data['depth']
    print(f"Loaded depth array shape: {depths.shape}")
    print(f"Depth range: [{np.min(depths):.4f}, {np.max(depths):.4f}]")
    
    # Handle different depth array shapes
    if depths.ndim == 2:
        # Single frame - add frame dimension
        depths = depths[np.newaxis, ...]
        print("Single frame detected, adding frame dimension")
    elif depths.ndim == 3:
        # Multiple frames: (frames, height, width) or (height, width, frames)
        # Check if last dimension is much smaller (likely frames)
        if depths.shape[2] < depths.shape[0] and depths.shape[2] < depths.shape[1]:
            # Shape is (height, width, frames) - transpose to (frames, height, width)
            depths = np.transpose(depths, (2, 0, 1))
            print("Transposed from (H, W, F) to (F, H, W)")
    elif depths.ndim != 3:
        raise ValueError(f"Unsupported depth array shape: {depths.shape}")
    
    num_frames, height, width = depths.shape
    print(f"Processing {num_frames} frames at {width}x{height} resolution")
    
    # Process each frame
    processed_frames = []
    for frame_idx, depth_frame in enumerate(depths):
        if frame_idx % 10 == 0:
            print(f"Processing frame {frame_idx + 1}/{num_frames}...")
        
        # Apply Gaussian blur
        blurred = ndimage.gaussian_filter(depth_frame, sigma=blur_sigma)
        
        # Apply log_base(x+1) transformation
        # Using natural log (base e) via log1p, then convert to desired base if needed
        if LOG_BASE == np.e:
            processed = np.log1p(blurred)  # ln(x+1) = log1p(x)
        else:
            processed = np.log1p(blurred) / np.log(LOG_BASE)  # log_base(x+1)
        
        processed_frames.append(processed)
    
    processed_frames = np.stack(processed_frames, axis=0)
    
    # Normalize to 0-255 for video encoding
    p_min = np.min(processed_frames)
    p_max = np.max(processed_frames)
    print(f"Processed depth range: [{p_min:.4f}, {p_max:.4f}]")
    
    depth_range = max(p_max - p_min, 1e-6)
    normalized = ((processed_frames - p_min) / depth_range * 255.0).clip(0, 255).astype(np.uint8)
    
    # Create video writer
    print(f"Encoding video to: {output_video}")
    output_video.parent.mkdir(parents=True, exist_ok=True)
    
    writer = imageio.get_writer(
        str(output_video),
        fps=fps,
        macro_block_size=1,
        codec='libx264',
        ffmpeg_params=['-crf', '18', '-pix_fmt', 'gray']
    )
    
    for frame in normalized:
        writer.append_data(frame)
    
    writer.close()
    print(f"Successfully saved processed depth video to: {output_video}")


def main():
    parser = argparse.ArgumentParser(
        description="Process depth.npz file: apply Gaussian blur and ln(x+1), encode to video"
    )
    parser.add_argument(
        "input_npz",
        type=str,
        help="Path to input depth.npz file"
    )
    parser.add_argument(
        "--blur-sigma",
        type=float,
        default=DEFAULT_BLUR_SIGMA,
        help=f"Gaussian blur sigma in pixels (default: {DEFAULT_BLUR_SIGMA})"
    )
    parser.add_argument(
        "--fps",
        type=float,
        default=None,
        help="Frames per second for output video (default: detect from reference video or 24.0)"
    )
    parser.add_argument(
        "--reference-video",
        type=str,
        default=None,
        help="Reference video to match FPS, duration, and frame count (default: detect from input directory)"
    )
    parser.add_argument(
        "--output",
        type=str,
        default=None,
        help="Output video path (default: processed_depth.mp4 in same directory as input)"
    )
    
    args = parser.parse_args()
    
    input_npz = Path(args.input_npz)
    if not input_npz.exists():
        raise FileNotFoundError(f"Input file not found: {input_npz}")
    
    # Determine output path
    if args.output:
        output_video = Path(args.output)
    else:
        output_video = input_npz.parent / "processed_depth.mp4"
    
    # Determine FPS - try to match reference video if available
    fps = args.fps
    if fps is None:
        # Try to find reference video in same directory
        reference_video = None
        if args.reference_video:
            reference_video = Path(args.reference_video)
        else:
            # Look for reference.mp4 or rgb.mp4 in same directory
            for ref_name in ["reference.mp4", "rgb.mp4"]:
                ref_path = input_npz.parent / ref_name
                if ref_path.exists():
                    reference_video = ref_path
                    break
        
        if reference_video and reference_video.exists():
            # Extract FPS from reference video
            import subprocess
            try:
                cmd = [
                    'ffprobe', '-v', 'error',
                    '-select_streams', 'v:0',
                    '-show_entries', 'stream=r_frame_rate',
                    '-of', 'default=noprint_wrappers=1:nokey=1',
                    str(reference_video)
                ]
                result = subprocess.run(cmd, capture_output=True, text=True, check=True)
                rate_str = result.stdout.strip()
                if '/' in rate_str:
                    num, den = map(float, rate_str.split('/'))
                    if den > 0:
                        fps = num / den
                        print(f"Detected FPS from {reference_video.name}: {fps:.6f}")
                else:
                    fps = float(rate_str)
            except Exception as e:
                print(f"Warning: Could not detect FPS from reference video: {e}")
                fps = 24.0
        else:
            fps = 24.0
            if reference_video:
                print(f"Warning: Reference video not found: {reference_video}, using default FPS")
    
    process_depth_npz(
        input_npz=input_npz,
        output_video=output_video,
        blur_sigma=args.blur_sigma,
        fps=fps,
    )


if __name__ == "__main__":
    main()

