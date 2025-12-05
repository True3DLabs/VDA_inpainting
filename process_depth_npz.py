#!/usr/bin/env python3
"""
Process depth.npz file: apply Gaussian blur and ln(x+1) transformation,
then encode to processed_depth.mp4 video.
Also updates metadata.json with postprocessing info and creates export.zip.
"""

import argparse
import json
import numpy as np
from pathlib import Path
import subprocess
import tempfile
import zipfile
import os
from scipy import ndimage

# Constants
DEFAULT_BLUR_SIGMA = 7.0  # Gaussian blur sigma in pixels
LOG_BASE = 10.0  # Natural logarithm base (e)
SHARPEN = 0.4


def process_depth_npz(
    input_npz: Path,
    output_video: Path,
    blur_sigma: float = DEFAULT_BLUR_SIGMA,
    fps: float = 24.0,
    target_frames: int = None,
    target_duration: float = None,
    log_base: float = LOG_BASE,
    sharpen: float = SHARPEN,
    scene_timestamps: list = None,
) -> dict:
    """
    Process depth.npz file and save as video.
    
    Args:
        input_npz: Path to input depth.npz file
        output_video: Path to output video file
        blur_sigma: Gaussian blur sigma in pixels (default: 5.0)
        fps: Frames per second for output video (default: 24.0)
        target_frames: Target number of frames (if None, uses all frames from npz)
        target_duration: Target duration in seconds (if None, calculated from frames and fps)
        scene_timestamps: List of scene start timestamps for per-scene normalization
    
    Returns:
        dict with processed scene statistics (min_depths, max_depths, screen_dists)
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
        if frame_idx % 100 == 0:
            print(f"Processing frame {frame_idx + 1}/{num_frames}...")
        
        # Apply Gaussian blur
        blurred = ndimage.gaussian_filter(depth_frame, sigma=blur_sigma)
        
        # Apply log_base(x+1) transformation
        # Using natural log (base e) via log1p, then convert to desired base if needed
        if log_base == np.e:
            logged = np.log1p(blurred)  # ln(x+1) = log1p(x)
        else:
            logged = np.log1p(blurred) / np.log(log_base)  # log_base(x+1)
        
        # Sharpen by blending original with blurred: sharpen * original + (1 - sharpen) * blurred
        # Note: original here refers to the blurred depth before log, logged refers to log(blurred)
        if sharpen > 0:
            original_logged = np.log1p(depth_frame) if log_base == np.e else np.log1p(depth_frame) / np.log(log_base)
            processed = sharpen * original_logged + (1 - sharpen) * logged
        else:
            processed = logged
        
        processed_frames.append(processed)
    
    processed_frames = np.stack(processed_frames, axis=0)
    
    # Compute per-scene statistics on processed frames (before normalization)
    processed_scene_stats = {
        'min_depths': [],
        'max_depths': [],
        'screen_dists': []  # 35th percentile
    }
    
    if scene_timestamps and len(scene_timestamps) > 0:
        scene_frame_indices_stats = [int(ts * fps) for ts in scene_timestamps]
        scene_frame_indices_stats.append(num_frames)  # Add end boundary
        
        for scene_idx in range(len(scene_timestamps)):
            start_frame = scene_frame_indices_stats[scene_idx]
            end_frame = scene_frame_indices_stats[scene_idx + 1]
            
            start_frame = max(0, min(start_frame, num_frames))
            end_frame = max(0, min(end_frame, num_frames))
            
            if start_frame >= end_frame:
                processed_scene_stats['min_depths'].append(0.0)
                processed_scene_stats['max_depths'].append(1.0)
                processed_scene_stats['screen_dists'].append(0.35)
                continue
            
            scene_data = processed_frames[start_frame:end_frame]
            p_min = float(np.min(scene_data))
            p_max = float(np.max(scene_data))
            p_35 = float(np.percentile(scene_data, 35))
            
            processed_scene_stats['min_depths'].append(p_min)
            processed_scene_stats['max_depths'].append(p_max)
            processed_scene_stats['screen_dists'].append(p_35)
        
        print(f"Computed processed scene statistics for {len(scene_timestamps)} scenes")
    
    # Normalize to 0-255 for video encoding
    # Use per-scene normalization if scene_timestamps provided, otherwise global
    if scene_timestamps and len(scene_timestamps) > 1:
        print(f"Using per-scene normalization ({len(scene_timestamps)} scenes)")
        
        # Convert timestamps to frame indices
        scene_frame_indices = [int(ts * fps) for ts in scene_timestamps]
        scene_frame_indices.append(num_frames)  # Add end boundary
        
        normalized = np.zeros_like(processed_frames, dtype=np.uint8)
        
        for scene_idx in range(len(scene_timestamps)):
            start_frame = scene_frame_indices[scene_idx]
            end_frame = scene_frame_indices[scene_idx + 1]
            
            # Clamp to valid range
            start_frame = max(0, min(start_frame, num_frames))
            end_frame = max(0, min(end_frame, num_frames))
            
            if start_frame >= end_frame:
                continue
            
            scene_data = processed_frames[start_frame:end_frame]
            p_min = np.min(scene_data)
            p_max = np.max(scene_data)
            depth_range = max(p_max - p_min, 1e-6)
            
            normalized[start_frame:end_frame] = (
                (scene_data - p_min) / depth_range * 255.0
            ).clip(0, 255).astype(np.uint8)
            
            if scene_idx % 10 == 0:
                print(f"  Scene {scene_idx + 1}: frames {start_frame}-{end_frame}, range [{p_min:.4f}, {p_max:.4f}]")
    else:
        print("Using global normalization")
        p_min = np.min(processed_frames)
        p_max = np.max(processed_frames)
        print(f"Processed depth range: [{p_min:.4f}, {p_max:.4f}]")
        
        depth_range = max(p_max - p_min, 1e-6)
        normalized = ((processed_frames - p_min) / depth_range * 255.0).clip(0, 255).astype(np.uint8)
    
    # Adjust frame count to match target if specified
    if target_frames is not None and target_frames != num_frames:
        if target_frames > num_frames:
            # Repeat last frame to match target
            last_frame = normalized[-1:]
            frames_to_add = target_frames - num_frames
            normalized = np.concatenate([normalized, np.repeat(last_frame, frames_to_add, axis=0)], axis=0)
            print(f"Extended frames from {num_frames} to {target_frames} to match reference")
        else:
            # Sample frames to match target
            indices = np.linspace(0, num_frames - 1, target_frames).astype(int)
            normalized = normalized[indices]
            print(f"Sampled frames from {num_frames} to {target_frames} to match reference")
        num_frames = target_frames
    
    # Encode video using ffmpeg directly for precise control
    print(f"Encoding video to: {output_video}")
    output_video.parent.mkdir(parents=True, exist_ok=True)
    
    # Calculate exact duration from frame count and fps
    if target_duration is not None:
        duration = target_duration
    else:
        duration = num_frames / fps
    
    height, width = normalized.shape[1:3]
    
    # Build ffmpeg command to encode from numpy arrays via pipe
    # Use h264 codec with exact FPS matching
    ffmpeg_cmd = [
        'ffmpeg',
        '-y',
        '-f', 'rawvideo',
        '-vcodec', 'rawvideo',
        '-s', f'{width}x{height}',
        '-pix_fmt', 'gray',
        '-r', str(fps),
        '-i', '-',
        '-an',  # No audio
        '-c:v', 'libx264',
        '-pix_fmt', 'yuv420p',
        '-crf', '18',
        '-r', str(fps),  # Output frame rate (must match input rate for exact timing)
    ]
    
    if target_duration is not None:
        ffmpeg_cmd.extend(['-t', str(target_duration)])
    
    ffmpeg_cmd.append(str(output_video))
    
    # Prepare all frame data as bytes
    frame_bytes = b''.join(frame.tobytes() for frame in normalized)
    
    # Run ffmpeg with frame data piped in
    result = subprocess.run(
        ffmpeg_cmd,
        input=frame_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg encoding failed: {result.stderr.decode()}")
    
    print(f"Successfully saved processed depth video to: {output_video}")
    print(f"  Frames: {num_frames}, FPS: {fps:.6f}, Duration: {duration:.6f}s")
    
    return processed_scene_stats


def update_metadata_with_postprocessing(
    metadata_file: Path,
    blur_sigma: float,
    log_base: float,
    sharpen: float,
    processed_scene_stats: dict = None
) -> None:
    """Update metadata.json with postprocessing section and processed scene stats."""
    if not metadata_file.exists():
        raise FileNotFoundError(f"Metadata file not found: {metadata_file}")
    
    with open(metadata_file, 'r') as f:
        metadata = json.load(f)
    
    metadata['postprocessing'] = {
        'blur_sigma': blur_sigma,
        'log_base': log_base,
        'sharpen': sharpen
    }
    
    # Add processed scene statistics if provided
    if processed_scene_stats:
        if processed_scene_stats.get('min_depths'):
            metadata['processed_scene_min_depths'] = processed_scene_stats['min_depths']
        if processed_scene_stats.get('max_depths'):
            metadata['processed_scene_max_depths'] = processed_scene_stats['max_depths']
        if processed_scene_stats.get('screen_dists'):
            metadata['processed_scene_screen_dists'] = processed_scene_stats['screen_dists']
    
    with open(metadata_file, 'w') as f:
        json.dump(metadata, f, indent=2)
    
    print(f"Updated metadata.json with postprocessing section")
    if processed_scene_stats and processed_scene_stats.get('min_depths'):
        print(f"  Added processed scene stats for {len(processed_scene_stats['min_depths'])} scenes")


def create_export_zip(output_dir: Path, rgb_video: Path, depth_video: Path, metadata_file: Path) -> None:
    """Create or update export.zip with rgb.mp4, depth.mp4, and metadata.json."""
    export_zip = output_dir / "export.zip"
    
    print(f"Creating export.zip at: {export_zip}")
    
    with zipfile.ZipFile(export_zip, 'w', zipfile.ZIP_DEFLATED) as zipf:
        # Add metadata.json
        zipf.write(metadata_file, os.path.basename(metadata_file))
        
        # Add rgb video as rgb.mp4
        zipf.write(rgb_video, "rgb.mp4")
        
        # Add processed depth video as depth.mp4
        zipf.write(depth_video, "depth.mp4")
    
    print(f"Export complete: {export_zip}")
    print("Contents:")
    with zipfile.ZipFile(export_zip, 'r') as zipf:
        for info in zipf.infolist():
            print(f"  {info.filename} ({info.file_size} bytes)")


def main():
    parser = argparse.ArgumentParser(
        description="Process depth.npz file: apply Gaussian blur and ln(x+1), encode to video, update metadata, and create export.zip"
    )
    parser.add_argument(
        "input_folder",
        type=str,
        help="Path to input folder containing depth.npz and metadata.json"
    )
    parser.add_argument(
        "--blur-sigma",
        type=float,
        default=DEFAULT_BLUR_SIGMA,
        help=f"Gaussian blur sigma in pixels (default: {DEFAULT_BLUR_SIGMA})"
    )
    parser.add_argument(
        "--log-base",
        type=float,
        default=LOG_BASE,
        help=f"Logarithm base for log(x+1) transformation (default: {LOG_BASE})"
    )
    parser.add_argument(
        "--sharpen",
        type=float,
        default=SHARPEN,
        help=f"Sharpen amount (0.0-1.0, default: {SHARPEN})"
    )
    parser.add_argument(
        "--fps",
        type=float,
        default=None,
        help="Frames per second for output video (default: detect from reference video or metadata.json)"
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
        help="Output video path (default: processed_depth.mp4 in input folder)"
    )
    parser.add_argument(
        "--export",
        action="store_true",
        help="Create export.zip with rgb.mp4, depth.mp4, and metadata.json"
    )
    
    args = parser.parse_args()
    
    input_folder = Path(args.input_folder)
    if not input_folder.exists() or not input_folder.is_dir():
        raise FileNotFoundError(f"Input folder not found: {input_folder}")
    
    # Find required files in the folder
    input_npz = input_folder / "depth.npz"
    metadata_file = input_folder / "metadata.json"
    
    if not input_npz.exists():
        raise FileNotFoundError(f"depth.npz not found in {input_folder}")
    if not metadata_file.exists():
        raise FileNotFoundError(f"metadata.json not found in {input_folder}")
    
    # Find RGB video (rgb.mp4 or reference.mp4)
    rgb_video = None
    if args.reference_video:
        rgb_video = Path(args.reference_video)
    else:
        for rgb_name in ["rgb.mp4", "reference.mp4"]:
            rgb_path = input_folder / rgb_name
            if rgb_path.exists():
                rgb_video = rgb_path
                break
    
    if rgb_video is None or not rgb_video.exists():
        raise FileNotFoundError(f"RGB video (rgb.mp4 or reference.mp4) not found in {input_folder}")
    
    # Determine output path
    if args.output:
        output_video = Path(args.output)
    else:
        output_video = input_folder / "processed_depth.mp4"
    
    # Determine FPS - try metadata.json first, then reference video
    fps = args.fps
    target_frames = None
    target_duration = None
    
    # Load metadata for FPS and scene timestamps
    scene_timestamps = None
    try:
        with open(metadata_file, 'r') as f:
            metadata = json.load(f)
            if fps is None:
                fps = metadata.get('fps')
            scene_timestamps = metadata.get('scene_timestamps')
            if scene_timestamps:
                print(f"Loaded {len(scene_timestamps)} scene timestamps from metadata.json")
    except Exception as e:
        print(f"Warning: Could not read metadata.json: {e}")
    
    if fps is None and rgb_video.exists():
        # Extract FPS, duration, and frame count from reference video
        try:
            # Get FPS
            cmd = [
                'ffprobe', '-v', 'error',
                '-select_streams', 'v:0',
                '-show_entries', 'stream=r_frame_rate',
                '-of', 'default=noprint_wrappers=1:nokey=1',
                str(rgb_video)
            ]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            rate_str = result.stdout.strip()
            if '/' in rate_str:
                num, den = map(float, rate_str.split('/'))
                if den > 0:
                    fps = num / den
            else:
                fps = float(rate_str)
            
            # Get duration
            cmd = [
                'ffprobe', '-v', 'error',
                '-show_entries', 'format=duration',
                '-of', 'default=noprint_wrappers=1:nokey=1',
                str(rgb_video)
            ]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            target_duration = float(result.stdout.strip())
            
            # Get frame count
            cmd = [
                'ffprobe', '-v', 'error',
                '-select_streams', 'v:0',
                '-count_frames',
                '-show_entries', 'stream=nb_frames',
                '-of', 'default=noprint_wrappers=1:nokey=1',
                str(rgb_video)
            ]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            target_frames = int(result.stdout.strip())
            
            print(f"Detected from {rgb_video.name}:")
            print(f"  FPS: {fps:.6f}")
            print(f"  Duration: {target_duration:.6f}s")
            print(f"  Frames: {target_frames}")
        except Exception as e:
            print(f"Warning: Could not detect properties from reference video: {e}")
            fps = 24.0 if fps is None else fps
            target_frames = None
            target_duration = None
    else:
        fps = 24.0 if fps is None else fps
    
    # Process depth npz
    processed_scene_stats = process_depth_npz(
        input_npz=input_npz,
        output_video=output_video,
        blur_sigma=args.blur_sigma,
        fps=fps,
        target_frames=target_frames,
        target_duration=target_duration,
        log_base=args.log_base,
        sharpen=args.sharpen,
        scene_timestamps=scene_timestamps,
    )
    
    # Update metadata with postprocessing info and scene stats
    update_metadata_with_postprocessing(
        metadata_file=metadata_file,
        blur_sigma=args.blur_sigma,
        log_base=args.log_base,
        sharpen=args.sharpen,
        processed_scene_stats=processed_scene_stats
    )
    
    # Create export.zip
    if args.export:
        create_export_zip(
            output_dir=input_folder,
            rgb_video=rgb_video,
            depth_video=output_video,
            metadata_file=metadata_file
        )


if __name__ == "__main__":
    main()

