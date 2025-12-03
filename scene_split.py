#!/usr/bin/env python3
"""
Scene splitting script using PySceneDetect.
Splits an input MP4 video into multiple scene files.
"""

import argparse
import json
import sys
from pathlib import Path

from scenedetect import detect, ContentDetector, split_video_ffmpeg
from scenedetect.video_splitter import VideoMetadata, SceneMetadata


def scene_filename_formatter(video=None, scene=None, video_metadata=None, scene_metadata=None) -> str:
    """Custom formatter to create zero-padded scene filenames like scene_001.mp4
    
    Accepts keyword arguments: video (VideoMetadata) and scene (SceneMetadata)
    """
    scene_meta = scene or scene_metadata
    if scene_meta is None:
        raise ValueError("scene or scene_metadata must be provided")
    scene_number = scene_meta.index + 1
    return f'scene_{scene_number:03d}.mp4'


def split_video_into_scenes(input_video, output_folder, threshold=27.0, max_len=None, return_timestamps=False):
    """
    Split a video into scenes and save them as numbered MP4 files.
    
    Args:
        input_video: Path to input MP4 video file
        output_folder: Path to output folder for scene files
        threshold: Detection threshold for ContentDetector (default: 27.0)
        max_len: Maximum length in seconds to crop video before detection (default: None)
        return_timestamps: If True, return list of scene start timestamps (default: False)
    
    Returns:
        List of scene start timestamps in seconds if return_timestamps=True, else None
    """
    input_path = Path(input_video)
    output_path = Path(output_folder)
    
    if not input_path.exists():
        raise FileNotFoundError(f"Input video not found: {input_video}")
    
    if not input_path.suffix.lower() == '.mp4':
        print(f"Warning: Input file is not .mp4: {input_path.suffix}")
    
    output_path.mkdir(parents=True, exist_ok=True)
    
    # If max_len is specified, create a temporary cropped video for detection
    temp_video = None
    video_to_detect = input_video
    if max_len is not None:
        import tempfile
        import subprocess
        temp_video = tempfile.NamedTemporaryFile(suffix='.mp4', delete=False)
        temp_video.close()
        print(f"Cropping video to {max_len} seconds for scene detection...")
        subprocess.run([
            'ffmpeg', '-i', str(input_path), '-t', str(max_len),
            '-c:v', 'libx264', '-c:a', 'copy', '-y', temp_video.name
        ], check=True, capture_output=True)
        video_to_detect = temp_video.name
    
    print(f"Detecting scenes in: {video_to_detect}")
    print(f"Output folder: {output_folder}")
    print(f"Threshold: {threshold}")
    
    scene_list = detect(video_to_detect, ContentDetector(threshold=threshold))
    
    # Clean up temp video if created
    if temp_video is not None:
        Path(temp_video.name).unlink()
    
    if not scene_list:
        print("No scenes detected in the video.")
        print("Creating single scene file with entire video as scene_001.mp4...")
        
        # Get video duration to determine if we need to crop
        import subprocess
        duration_cmd = [
            'ffprobe', '-v', 'error', '-show_entries', 'format=duration',
            '-of', 'default=noprint_wrappers=1:nokey=1', str(input_path)
        ]
        duration = float(subprocess.run(duration_cmd, capture_output=True, text=True, check=True).stdout.strip())
        
        # Determine actual duration (considering max_len)
        actual_duration = duration
        if max_len is not None:
            actual_duration = min(duration, max_len)
        
        # Create scene_001.mp4 with entire video (or cropped if max_len specified)
        scene_output = output_path / 'scene_001.mp4'
        if max_len is not None:
            subprocess.run([
                'ffmpeg', '-i', str(input_path), '-t', str(max_len),
                '-c:v', 'libx264', '-c:a', 'copy', '-y', str(scene_output)
            ], check=True, capture_output=True)
        else:
            subprocess.run([
                'ffmpeg', '-i', str(input_path),
                '-c:v', 'libx264', '-c:a', 'copy', '-y', str(scene_output)
            ], check=True, capture_output=True)
        
        print(f"Created scene_001.mp4 with entire video (duration: {actual_duration:.2f}s)")
        print(f"Output file saved to: {scene_output}")
        
        if return_timestamps:
            return [0.0]
        return None
    
    print(f"\nDetected {len(scene_list)} scenes")
    
    scene_timestamps = []
    for i, scene in enumerate(scene_list):
        start_time = scene[0].get_seconds()
        end_time = scene[1].get_seconds()
        print(f"  Scene {i+1}: {scene[0].get_timecode()} - {scene[1].get_timecode()}")
        scene_timestamps.append(start_time)
    
    print(f"\nSplitting video into scenes...")
    
    # Split the original (uncropped) video, but scenes will be limited by max_len if specified
    split_video_ffmpeg(
        input_video_path=str(input_path),
        scene_list=scene_list,
        output_dir=output_path,
        formatter=scene_filename_formatter,
        show_progress=True
    )
    
    print(f"\nSuccessfully split video into {len(scene_list)} scenes")
    print(f"Output files saved to: {output_folder}")
    
    if return_timestamps:
        return scene_timestamps
    return None


def main():
    parser = argparse.ArgumentParser(
        description='Split an MP4 video into scenes using PySceneDetect'
    )
    parser.add_argument(
        'input_video',
        type=str,
        help='Path to input MP4 video file'
    )
    parser.add_argument(
        '-o', '--output',
        type=str,
        default=None,
        help='Output folder for scene files (default: <input_video>_scenes)'
    )
    parser.add_argument(
        '-t', '--threshold',
        type=float,
        default=27.0,
        help='Detection threshold for ContentDetector (default: 27.0)'
    )
    parser.add_argument(
        '--max-len',
        type=float,
        default=None,
        help='Maximum length in seconds to crop video before detection (default: no limit)'
    )
    parser.add_argument(
        '--output-timestamps',
        type=str,
        default=None,
        help='Output file path to save scene timestamps as JSON array (default: not saved)'
    )
    
    args = parser.parse_args()
    
    if args.output is None:
        input_path = Path(args.input_video)
        args.output = str(input_path.parent / f"{input_path.stem}_scenes")
    
    try:
        timestamps = split_video_into_scenes(
            args.input_video, 
            args.output, 
            args.threshold,
            max_len=args.max_len,
            return_timestamps=args.output_timestamps is not None
        )
        
        if args.output_timestamps and timestamps is not None:
            with open(args.output_timestamps, 'w') as f:
                json.dump(timestamps, f, indent=2)
            print(f"\nScene timestamps saved to: {args.output_timestamps}")
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()

