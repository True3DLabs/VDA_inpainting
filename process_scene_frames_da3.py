#!/usr/bin/env python3
"""
Process scene frames with da3 frame-by-frame to ensure exact frame count matching.
Uses da3 Python API directly - NO video encoding.
"""

import argparse
import cv2
import numpy as np
import subprocess
import sys
from pathlib import Path
import tempfile
import shutil

def extract_frames_from_video(video_path: Path, output_dir: Path) -> list[Path]:
    """Extract all frames from video to output directory, returns list of frame paths in order."""
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Use ffmpeg to extract frames
    # ffmpeg's %06d pattern starts from 1, so frame_000001.png is the first frame
    frame_pattern = output_dir / "frame_%06d.png"
    cmd = [
        'ffmpeg', '-i', str(video_path),
        '-vsync', '0',  # Don't duplicate/drop frames
        '-start_number', '1',  # Start numbering from 1
        '-y',
        str(frame_pattern)
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error extracting frames: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    
    # Get all extracted frames in order
    frame_files = sorted(output_dir.glob("frame_*.png"), key=lambda p: int(p.stem.split('_')[1]))
    if len(frame_files) == 0:
        print(f"Warning: No frames extracted. Checked pattern: {output_dir / 'frame_*.png'}", file=sys.stderr)
        # List what files actually exist
        existing_files = list(output_dir.glob("*"))
        if existing_files:
            print(f"Found files in directory: {[f.name for f in existing_files[:10]]}", file=sys.stderr)
    return frame_files

def get_video_pts_timestamps(video_path: Path) -> tuple[list[int], str]:
    """Extract integer PTS timestamps and timebase from video.
    Returns (pts_values, timebase_string) where pts_values are integers with no precision loss."""
    # Extract integer PTS values
    pts_cmd = [
        'ffprobe', '-v', 'error',
        '-select_streams', 'v:0',
        '-show_entries', 'frame=pkt_pts',
        '-of', 'csv=p=0',
        str(video_path)
    ]
    
    pts_result = subprocess.run(pts_cmd, capture_output=True, text=True, check=True)
    pts_values = [int(x.strip()) for x in pts_result.stdout.strip().split('\n') if x.strip()]
    
    # Extract timebase
    tb_cmd = [
        'ffprobe', '-v', 'error',
        '-select_streams', 'v:0',
        '-show_entries', 'stream=time_base',
        '-of', 'csv=p=0',
        str(video_path)
    ]
    
    tb_result = subprocess.run(tb_cmd, capture_output=True, text=True, check=True)
    timebase = tb_result.stdout.strip()
    
    return pts_values, timebase

def process_frames_with_da3_direct(frame_files: list[Path], model_dir: str, 
                                   process_res: int, output_npz: Path) -> None:
    """Process frames using da3 images command directly."""
    print("Processing frames with da3 images command...")
    print(f"  Model dir: {model_dir}")
    print(f"  Process res: {process_res}")
    print(f"  Frames: {len(frame_files)}")
    
    if len(frame_files) == 0:
        print("Error: No frame files to process", file=sys.stderr)
        sys.exit(1)
    
    # Get the frames directory
    frames_dir = frame_files[0].parent
    
    # Use da3 images command which processes a directory of images
    # and outputs to an export directory
    export_dir = output_npz.parent / "da3_export"
    
    da3_cmd = [
        'da3', 'images', str(frames_dir),
        '--model-dir', model_dir,
        '--export-dir', str(export_dir),
        '--export-format', 'mini_npz',
        '--process-res', str(process_res),
        '--auto-cleanup'
    ]
    
    print(f"  Running: {' '.join(da3_cmd)}")
    result = subprocess.run(da3_cmd, capture_output=True, text=True)
    
    if result.returncode != 0:
        print(f"Error running da3 images command", file=sys.stderr)
        print(f"da3 stderr: {result.stderr}", file=sys.stderr)
        print(f"da3 stdout: {result.stdout}", file=sys.stderr)
        sys.exit(1)
    
    print(result.stdout)
    
    # da3 images creates exports/mini_npz/results.npz
    da3_npz = export_dir / "exports" / "mini_npz" / "results.npz"
    if not da3_npz.exists():
        # Try alternate locations
        alt_locations = [
            export_dir / "mini_npz" / "results.npz",
            export_dir / "results.npz",
        ]
        for alt in alt_locations:
            if alt.exists():
                da3_npz = alt
                break
        else:
            print(f"Error: da3 output not found at {da3_npz} or alternate locations", file=sys.stderr)
            print(f"Export dir contents:", file=sys.stderr)
            if export_dir.exists():
                for item in export_dir.rglob("*"):
                    if item.is_file():
                        print(f"  {item.relative_to(export_dir)}", file=sys.stderr)
            sys.exit(1)
    
    # Move to expected location
    shutil.move(str(da3_npz), str(output_npz))
    
    # Clean up export directory
    if export_dir.exists():
        shutil.rmtree(export_dir)
    
    print(f"  Saved depth results to: {output_npz}")

def main():
    parser = argparse.ArgumentParser(description='Process scene frames with da3 frame-by-frame')
    parser.add_argument('--scene-video', required=True, help='Input scene video file')
    parser.add_argument('--model-dir', required=True, help='DA3 model directory')
    parser.add_argument('--process-res', type=int, default=728, help='Processing resolution')
    parser.add_argument('--use-backend', action='store_true', help='Use backend service (not used in images mode)')
    parser.add_argument('--backend-url', default='http://localhost:8008', help='Backend URL (not used)')
    parser.add_argument('--output-npz', required=True, help='Output npz file path')
    parser.add_argument('--frames-dir', help='Temporary directory for frames (auto-created if not provided)')
    
    args = parser.parse_args()
    
    scene_video = Path(args.scene_video)
    output_npz = Path(args.output_npz)
    output_npz.parent.mkdir(parents=True, exist_ok=True)
    
    # Get integer PTS timestamps and timebase from RGB scene video
    print("Extracting PTS timestamps from RGB scene video...")
    rgb_pts, rgb_timebase = get_video_pts_timestamps(scene_video)
    print(f"  Found {len(rgb_pts)} frames with integer PTS timestamps (timebase: {rgb_timebase})")
    
    # Extract frames from scene video
    if args.frames_dir:
        frames_dir = Path(args.frames_dir)
    else:
        frames_dir = output_npz.parent / "temp_frames"
    
    print(f"Extracting frames from {scene_video}...")
    frame_files = extract_frames_from_video(scene_video, frames_dir)
    print(f"  Extracted {len(frame_files)} frames")
    
    # CRITICAL: Frame count must match exactly
    if len(frame_files) != len(rgb_pts):
        print(f"❌ CRITICAL ERROR: Frame extraction mismatch!", file=sys.stderr)
        print(f"  Extracted frames: {len(frame_files)}", file=sys.stderr)
        print(f"  PTS timestamps: {len(rgb_pts)}", file=sys.stderr)
        sys.exit(1)
    
    # Process frames with da3
    print("Processing frames with da3...")
    process_frames_with_da3_direct(frame_files, args.model_dir, args.process_res, output_npz)
    
    # Verify output frame count
    data = np.load(output_npz)
    if 'depth' not in data:
        print(f"Error: No depth data in output npz", file=sys.stderr)
        sys.exit(1)
    
    depth_frames = data['depth']
    if depth_frames.ndim == 2:
        # Single frame
        num_depth_frames = 1
    elif depth_frames.ndim == 3:
        # Check if shape is (frames, height, width) or (height, width, frames)
        if depth_frames.shape[2] < depth_frames.shape[0] and depth_frames.shape[2] < depth_frames.shape[1]:
            # Likely (height, width, frames)
            num_depth_frames = depth_frames.shape[2]
        else:
            # Likely (frames, height, width)
            num_depth_frames = depth_frames.shape[0]
    else:
        print(f"Error: Unexpected depth shape: {depth_frames.shape}", file=sys.stderr)
        sys.exit(1)
    
    # CRITICAL: Verify frame count matches
    if num_depth_frames != len(rgb_pts):
        print(f"❌ CRITICAL ERROR: da3 produced wrong number of frames!", file=sys.stderr)
        print(f"  Expected: {len(rgb_pts)}", file=sys.stderr)
        print(f"  Got: {num_depth_frames}", file=sys.stderr)
        print(f"  Depth shape: {depth_frames.shape}", file=sys.stderr)
        sys.exit(1)
    
    # Clean up frames directory if we created it
    if not args.frames_dir and frames_dir.exists():
        shutil.rmtree(frames_dir)
    
    # Save integer PTS timestamps for later use in video encoding
    pts_file = output_npz.parent / "rgb_pts.npy"
    np.save(str(pts_file), np.array(rgb_pts, dtype=np.int64))
    
    # Save timebase
    timebase_file = output_npz.parent / "rgb_timebase.txt"
    with open(timebase_file, 'w') as f:
        f.write(rgb_timebase)
    
    print(f"Saved integer PTS timestamps to {pts_file}")
    print(f"Saved timebase ({rgb_timebase}) to {timebase_file}")
    
    print(f"✅ Processing complete. Output: {output_npz}")
    print(f"   Frames: {num_depth_frames}")
    print(f"   Shape: {depth_frames.shape}")

if __name__ == '__main__':
    main()
