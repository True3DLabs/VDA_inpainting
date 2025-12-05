#!/usr/bin/env python3
"""
Update metadata.json with per-scene depth statistics from npz files.

Extracts:
- scene_min_depths: minimum depth value per scene
- scene_max_depths: maximum depth value per scene  
- scene_screen_dists: 35th percentile depth from middle frame of each scene

Usage:
    python update_scene_depth_metadata.py <output_dir>
    
Example:
    python update_scene_depth_metadata.py outputs/yesterday_clip-1764868582
"""

import json
import numpy as np
from pathlib import Path
import sys


def get_scene_depth_stats(scene_dir: Path) -> dict:
    """Extract depth stats from a scene's npz file."""
    # Check both possible npz locations
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
        return None
    
    try:
        data = np.load(npz_path)
        if 'depth' not in data:
            return None
        
        depth = data['depth']  # Shape: (frames, height, width)
        
        # Min and max across entire scene
        min_depth = float(np.min(depth))
        max_depth = float(np.max(depth))
        
        # 35th percentile from middle frame
        num_frames = depth.shape[0]
        middle_frame_idx = num_frames // 2
        middle_frame = depth[middle_frame_idx]
        screen_dist = float(np.percentile(middle_frame, 35))
        
        return {
            "min_depth": min_depth,
            "max_depth": max_depth,
            "screen_dist": screen_dist
        }
    except Exception as e:
        print(f"  Warning: Error reading {npz_path}: {e}")
        return None


def update_metadata_with_depth_stats(output_dir: Path):
    """Update metadata.json with scene depth statistics."""
    metadata_file = output_dir / "metadata.json"
    scenes_dir = output_dir / "scenes"
    
    if not metadata_file.exists():
        print(f"Error: metadata.json not found in {output_dir}")
        return False
    
    if not scenes_dir.exists():
        print(f"Error: scenes directory not found in {output_dir}")
        return False
    
    # Load existing metadata
    with open(metadata_file, 'r') as f:
        metadata = json.load(f)
    
    scene_count = metadata.get('scene_count', 0)
    if scene_count == 0:
        scene_timestamps = metadata.get('scene_timestamps', [])
        scene_count = len(scene_timestamps) if scene_timestamps else 0
    
    print(f"Processing {scene_count} scenes...")
    
    scene_min_depths = []
    scene_max_depths = []
    scene_screen_dists = []
    
    for i in range(1, scene_count + 1):
        scene_name = f"scene_{i:03d}"
        scene_dir = scenes_dir / scene_name
        
        if not scene_dir.exists():
            print(f"  Scene {i}: directory not found, using defaults")
            scene_min_depths.append(1.0)
            scene_max_depths.append(10.0)
            scene_screen_dists.append(3.0)
            continue
        
        stats = get_scene_depth_stats(scene_dir)
        
        if stats is None:
            print(f"  Scene {i}: no depth data found, using defaults")
            scene_min_depths.append(1.0)
            scene_max_depths.append(10.0)
            scene_screen_dists.append(3.0)
        else:
            scene_min_depths.append(stats["min_depth"])
            scene_max_depths.append(stats["max_depth"])
            scene_screen_dists.append(stats["screen_dist"])
            print(f"  Scene {i}: min={stats['min_depth']:.2f}m, max={stats['max_depth']:.2f}m, screen={stats['screen_dist']:.2f}m")
    
    # Update metadata
    metadata['scene_min_depths'] = scene_min_depths
    metadata['scene_max_depths'] = scene_max_depths
    metadata['scene_screen_dists'] = scene_screen_dists
    
    # Write back
    with open(metadata_file, 'w') as f:
        json.dump(metadata, f, indent=2)
    
    print(f"\nUpdated {metadata_file} with depth stats for {scene_count} scenes")
    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    
    output_dir = Path(sys.argv[1])
    if not output_dir.exists():
        print(f"Error: Directory not found: {output_dir}")
        sys.exit(1)
    
    success = update_metadata_with_depth_stats(output_dir)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
