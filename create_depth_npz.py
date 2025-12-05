#!/usr/bin/env python3
"""
Create top-level depth.npz by concatenating all scene depth npz files.

Concatenates:
- depth: (total_frames, height, width) - metric depth values
- conf: (total_frames, height, width) - confidence values (if available)

Usage:
    python create_depth_npz.py <output_dir>
    
Example:
    python create_depth_npz.py outputs/yesterday_clip-1764868582
"""

import json
import numpy as np
from pathlib import Path
import sys


def create_depth_npz(output_dir: Path):
    """Create top-level depth.npz from scene npz files."""
    metadata_file = output_dir / "metadata.json"
    scenes_dir = output_dir / "scenes"
    output_npz = output_dir / "depth.npz"
    
    if not metadata_file.exists():
        print(f"Error: metadata.json not found in {output_dir}")
        return False
    
    if not scenes_dir.exists():
        print(f"Error: scenes directory not found in {output_dir}")
        return False
    
    # Load metadata to get scene count
    with open(metadata_file, 'r') as f:
        metadata = json.load(f)
    
    scene_count = metadata.get('scene_count', 0)
    if scene_count == 0:
        scene_timestamps = metadata.get('scene_timestamps', [])
        scene_count = len(scene_timestamps) if scene_timestamps else 0
    
    print(f"Concatenating depth from {scene_count} scenes...")
    
    all_depths = []
    all_confs = []
    total_frames = 0
    
    for i in range(1, scene_count + 1):
        scene_name = f"scene_{i:03d}"
        scene_dir = scenes_dir / scene_name
        
        # Check possible npz locations
        npz_paths = [
            scene_dir / "exports" / "mini_npz" / "results.npz",
            scene_dir / "depth_results.npz",
        ]
        
        npz_path = None
        for p in npz_paths:
            if p.exists():
                npz_path = p
                break
        
        if npz_path is None:
            # Flat depth scene - check for depth.mp4 to get frame count
            depth_video = scene_dir / "depth.mp4"
            if depth_video.exists():
                import subprocess
                result = subprocess.run(
                    ['ffprobe', '-v', 'error', '-select_streams', 'v:0',
                     '-count_frames', '-show_entries', 'stream=nb_read_frames',
                     '-of', 'default=noprint_wrappers=1:nokey=1', str(depth_video)],
                    capture_output=True, text=True
                )
                try:
                    num_frames = int(result.stdout.strip())
                    # Get dimensions from first valid scene
                    if all_depths and len(all_depths) > 0:
                        h, w = all_depths[0].shape[1], all_depths[0].shape[2]
                    else:
                        # Default dimensions - will be overwritten if we find a valid scene later
                        h, w = 308, 728
                    
                    # Create flat depth array with value 100 (normalized)
                    flat_depth = np.full((num_frames, h, w), 100.0, dtype=np.float32)
                    flat_conf = np.ones((num_frames, h, w), dtype=np.float32)
                    all_depths.append(flat_depth)
                    all_confs.append(flat_conf)
                    total_frames += num_frames
                    print(f"  Scene {i}: {num_frames} frames (flat depth)")
                    continue
                except:
                    pass
            print(f"  Scene {i}: skipped (no depth data)")
            continue
        
        try:
            data = np.load(npz_path)
            depth = data['depth']  # (frames, height, width)
            
            all_depths.append(depth)
            total_frames += depth.shape[0]
            
            if 'conf' in data:
                all_confs.append(data['conf'])
            
            print(f"  Scene {i}: {depth.shape[0]} frames, range=[{depth.min():.2f}, {depth.max():.2f}]m")
            
        except Exception as e:
            print(f"  Scene {i}: error reading npz: {e}")
            continue
    
    if not all_depths:
        print("Error: No depth data found in any scene")
        return False
    
    # Concatenate all arrays
    print(f"\nConcatenating {len(all_depths)} scene arrays...")
    combined_depth = np.concatenate(all_depths, axis=0)
    
    save_dict = {'depth': combined_depth}
    
    if all_confs and len(all_confs) == len(all_depths):
        combined_conf = np.concatenate(all_confs, axis=0)
        save_dict['conf'] = combined_conf
    
    print(f"Combined depth shape: {combined_depth.shape}")
    print(f"Total frames: {total_frames}")
    print(f"Depth range: [{combined_depth.min():.2f}, {combined_depth.max():.2f}]m")
    
    # Save
    print(f"\nSaving to {output_npz}...")
    np.savez_compressed(output_npz, **save_dict)
    
    # Report file size
    size_mb = output_npz.stat().st_size / (1024 * 1024)
    print(f"✅ Created {output_npz} ({size_mb:.1f} MB)")
    
    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    
    output_dir = Path(sys.argv[1])
    if not output_dir.exists():
        print(f"Error: Directory not found: {output_dir}")
        sys.exit(1)
    
    success = create_depth_npz(output_dir)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
