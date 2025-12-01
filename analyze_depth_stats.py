import cv2
import numpy as np
import matplotlib.pyplot as plt
import sys
import os
import json

def analyze_depth_video(video_path, transition_skip_frames=5):
    cap = cv2.VideoCapture(video_path)
    
    if not cap.isOpened():
        print(f"Error: Could not open video file {video_path}")
        return
    
    fps = cap.get(cv2.CAP_PROP_FPS)
    if fps == 0:
        fps = 23.976
    
    frame_numbers = []
    max_depths = []
    min_depths = []
    
    frame_idx = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        
        if len(frame.shape) == 3:
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        else:
            gray = frame
        
        max_depth = np.max(gray)
        min_depth = np.min(gray)
        
        frame_numbers.append(frame_idx)
        max_depths.append(max_depth)
        min_depths.append(min_depth)
        
        frame_idx += 1
        
        if frame_idx % 100 == 0:
            print(f"Processed {frame_idx} frames...")
    
    cap.release()
    
    print(f"Total frames processed: {len(frame_numbers)}")
    
    plt.figure(figsize=(12, 6))
    plt.plot(frame_numbers, max_depths, 'b-', linewidth=1.5, label='Max Depth', alpha=0.7)
    plt.plot(frame_numbers, min_depths, 'r-', linewidth=1.5, label='Min Depth', alpha=0.7)
    plt.xlabel('Frame Number')
    plt.ylabel('Depth Value (0-255)')
    plt.title('Min and Max Depth Values Per Frame')
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.ylim(0, 255)
    
    output_path = os.path.join(os.path.dirname(video_path), 'depth_stats.png')
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    print(f"Graph saved to: {output_path}")
    
    plt.close()
    
    metadata_path = os.path.join(os.path.dirname(video_path), 'metadata.json')
    if os.path.exists(metadata_path):
        print(f"Found metadata.json, analyzing per-scene depth...")
        analyze_per_scene_depth(video_path, metadata_path, max_depths, min_depths, fps, transition_skip_frames)

def analyze_per_scene_depth(video_path, metadata_path, max_depths, min_depths, fps, transition_skip_frames=5):
    with open(metadata_path, 'r') as f:
        metadata = json.load(f)
    
    if 'scene_timestamps' not in metadata:
        print("No scene_timestamps found in metadata.json")
        return
    
    scene_timestamps = metadata['scene_timestamps']
    video_fps = metadata.get('fps', fps)
    
    scene_numbers = []
    scene_max_depths = []
    scene_min_depths = []
    
    total_frames = len(max_depths)
    
    for scene_idx in range(len(scene_timestamps) - 1):
        start_time = scene_timestamps[scene_idx]
        end_time = scene_timestamps[scene_idx + 1]
        
        start_frame = int(start_time * video_fps)
        end_frame = int(end_time * video_fps)
        
        start_frame = max(0, min(start_frame, total_frames - 1))
        end_frame = max(0, min(end_frame, total_frames - 1))
        
        if start_frame >= end_frame:
            continue
        
        scene_start = start_frame + transition_skip_frames
        scene_end = end_frame - transition_skip_frames
        
        if scene_start >= scene_end:
            scene_start = start_frame
            scene_end = end_frame
        
        scene_max_values = max_depths[scene_start:scene_end]
        scene_min_values = min_depths[scene_start:scene_end]
        
        if len(scene_max_values) > 0:
            scene_max_depth = np.max(scene_max_values)
            scene_min_depth = np.min(scene_min_values)
            
            scene_numbers.append(scene_idx)
            scene_max_depths.append(scene_max_depth)
            scene_min_depths.append(scene_min_depth)
    
    if len(scene_numbers) == 0:
        print("No valid scenes found for analysis")
        return
    
    plt.figure(figsize=(12, 6))
    plt.plot(scene_numbers, scene_max_depths, 'b-', linewidth=1.5, marker='o', markersize=4, label='Max Depth', alpha=0.7)
    plt.plot(scene_numbers, scene_min_depths, 'r-', linewidth=1.5, marker='o', markersize=4, label='Min Depth', alpha=0.7)
    plt.xlabel('Scene Number')
    plt.ylabel('Depth Value (0-255)')
    plt.title(f'Min and Max Depth Values Per Scene (skipping {transition_skip_frames} frames at transitions)')
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.ylim(0, 255)
    
    output_path = os.path.join(os.path.dirname(video_path), 'depth_stats_per_scene.png')
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    print(f"Per-scene graph saved to: {output_path}")
    
    plt.close()

if __name__ == "__main__":
    video_path = sys.argv[1] if len(sys.argv) > 1 else "/home/al/VDA_inpainting/outputs/yesterday_clip-1764103445/depth.mp4"
    analyze_depth_video(video_path)

