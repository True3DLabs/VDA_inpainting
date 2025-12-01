#!/bin/bash
# Master script for video processing pipeline with scene-based processing
# Usage: ./main_v2.sh <input_video_or_folder> [--max-fps N] [--max-res N] [--max-len N] [--no-depth] [--no-export] [--da3-model-dir DIR] [--backend-url URL]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_FPS=24
MAX_RES=720
MAX_LEN=""
MAX_CLIP=20
NO_DEPTH=false
NO_EXPORT=false
DA3_MODEL_DIR="depth-anything/DA3NESTED-GIANT-LARGE"
BACKEND_URL="http://localhost:8008"
USE_BACKEND=false

# Parse arguments
INPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --max-fps)
      MAX_FPS="$2"; shift 2 ;;
    --max-res)
      MAX_RES="$2"; shift 2 ;;
    --max-len)
      MAX_LEN="$2"; shift 2 ;;
    --max-clip)
      MAX_CLIP="$2"; shift 2 ;;
    --no-depth)
      NO_DEPTH=true; shift ;;
    --no-export)
      NO_EXPORT=true; shift ;;
    --da3-model-dir)
      DA3_MODEL_DIR="$2"; shift 2 ;;
    --backend-url)
      BACKEND_URL="$2"; USE_BACKEND=true; shift 2 ;;
    --help|-h)
      cat >&2 <<USAGE
Usage: $0 <input_video_or_folder> [options]

Options:
  --max-fps N       Maximum FPS for processing (default: 24)
  --max-res N       Maximum resolution for larger side (default: 1280)
  --max-len N       Maximum length in seconds to clip video (default: no limit)
  --max-clip N      Maximum scene length in seconds for da3 processing (default: 30)
                    Scenes exceeding this will get flat depth (value 100)
  --no-depth        Skip depth estimation
  --no-export       Skip export.zip creation
  --da3-model-dir DIR  Path to DA3 model directory (default: depth-anything/DA3NESTED-GIANT-LARGE)
  --backend-url URL    DA3 backend URL (optional, enables backend mode if provided)
  --help            Show this help message

The script can be run on:
  - An input video file: Creates new output directory and processes
  - An existing output folder: Resumes processing, skipping existing files

Example:
  $0 input_video.mp4 --max-fps 30 --max-res 1920 --max-len 10 --da3-model-dir depth-anything/DA3NESTED-GIANT-LARGE
  $0 outputs/my_video-1234567890  # Resume processing
USAGE
      exit 0 ;;
    *)
      if [ -z "$INPUT" ]; then
        INPUT="$1"
      else
        echo "Unknown option: $1" >&2
        exit 1
      fi
      shift ;;
  esac
done

if [ -z "$INPUT" ]; then
  echo "Error: No input specified" >&2
  echo "Usage: $0 <input_video_or_folder> [options]" >&2
  exit 1
fi

# Convert to absolute path
if [[ "$INPUT" != /* ]]; then
  INPUT="${SCRIPT_DIR}/${INPUT}"
fi

# Determine if input is a video file or output folder
if [ -f "$INPUT" ]; then
  # Input is a video file - create new output directory
  INPUT_VIDEO="$INPUT"
  INPUT_BASENAME=$(basename "$INPUT_VIDEO")
  INPUT_NAME="${INPUT_BASENAME%.*}"
  TIMESTAMP=$(date +%s)
  ROOT_DIR="${SCRIPT_DIR}/outputs/${INPUT_NAME}-${TIMESTAMP}"
  mkdir -p "$ROOT_DIR"
  IS_NEW_RUN=true
elif [ -d "$INPUT" ]; then
  # Input is an output folder - resume processing
  ROOT_DIR="$INPUT"
  METADATA_FILE="${ROOT_DIR}/metadata.json"
  if [ ! -f "$METADATA_FILE" ]; then
    echo "Error: metadata.json not found in $ROOT_DIR. Is this a valid output directory?" >&2
    exit 1
  fi
  # Extract original video path from metadata
  INPUT_VIDEO=$(python3 -c "import json; data = json.load(open('$METADATA_FILE')); print(data.get('video_file', ''))" 2>/dev/null || echo "")
  if [ -z "$INPUT_VIDEO" ] || [ ! -f "$INPUT_VIDEO" ]; then
    echo "Error: Could not find original video file from metadata" >&2
    exit 1
  fi
  INPUT_NAME=$(basename "$ROOT_DIR" | sed 's/-[0-9]*$//')
  IS_NEW_RUN=false
  # Load existing config from metadata if available, otherwise use default
  if [ -z "$DA3_MODEL_DIR" ]; then
    DA3_MODEL_DIR=$(python3 -c "import json; data = json.load(open('$METADATA_FILE')); print(data.get('da3_model_dir', 'depth-anything/DA3NESTED-GIANT-LARGE'))" 2>/dev/null || echo "depth-anything/DA3NESTED-GIANT-LARGE")
  fi
  # Ensure we always have a default if somehow still empty
  if [ -z "$DA3_MODEL_DIR" ]; then
    DA3_MODEL_DIR="depth-anything/DA3NESTED-GIANT-LARGE"
  fi
else
  echo "Error: Input not found: $INPUT" >&2
  exit 1
fi

SCENES_DIR="${ROOT_DIR}/scenes"
METADATA_FILE="${ROOT_DIR}/metadata.json"
RGB_VIDEO="${ROOT_DIR}/rgb.mp4"
DEPTH_VIDEO="${ROOT_DIR}/depth.mp4"
LOG_FILE="${ROOT_DIR}/log.txt"
SCENE_SPLIT_SCRIPT="${SCRIPT_DIR}/scene_split.py"

# Function to extract video metadata
extract_video_metadata() {
    local video_file="$1"
    
    if ! command -v ffprobe &> /dev/null; then
        echo "Error: ffprobe not found. Please install ffmpeg." >&2
        exit 1
    fi
    
    # Get video metadata using ffprobe
    local original_fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$video_file" | awk -F'/' '{if ($2+0 == 0) print 0; else print ($1+0)/($2+0)}')
    local original_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local original_width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local original_height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local bitrate=$(ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local num_frames=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_frames -of default=noprint_wrappers=1:nokey=1 "$video_file" 2>/dev/null || echo "")
    
    # Calculate actual FPS used (min of original and MAX_FPS)
    local actual_fps=$(echo "$original_fps $MAX_FPS" | awk '{if ($1 < $2) print $1; else print $2}')
    
    # Calculate actual duration (min of original and MAX_LEN if specified)
    local duration=$original_duration
    if [ -n "$MAX_LEN" ]; then
        duration=$(echo "$original_duration $MAX_LEN" | awk '{if ($1 < $2) print $1; else print $2}')
    fi
    
    # Return values via global variables (bash limitation)
    METADATA_ORIGINAL_FPS=$original_fps
    METADATA_ACTUAL_FPS=$actual_fps
    METADATA_DURATION=$duration
    METADATA_ORIGINAL_DURATION=$original_duration
    METADATA_WIDTH=$original_width
    METADATA_HEIGHT=$original_height
    METADATA_CODEC=$codec
    METADATA_BITRATE=$bitrate
    METADATA_NUM_FRAMES=$num_frames
}

# Function to calculate depth dimensions based on MAX_RES
calculate_depth_dimensions() {
    local width=$1
    local height=$2
    local max_res=$3
    
    local max_hw=$(echo "$width $height" | awk '{if ($1 > $2) print $1; else print $2}')
    if [ "$max_hw" -le "$max_res" ]; then
        DEPTH_WIDTH=$width
        DEPTH_HEIGHT=$height
    else
        local scale=$(echo "$max_res $max_hw" | awk '{print $1 / $2}')
        DEPTH_WIDTH=$(echo "$width $scale" | awk '{printf "%.0f", $1 * $2}')
        DEPTH_HEIGHT=$(echo "$height $scale" | awk '{printf "%.0f", $1 * $2}')
        # Ensure dimensions are even (required by some codecs)
        DEPTH_WIDTH=$((DEPTH_WIDTH - (DEPTH_WIDTH % 2)))
        DEPTH_HEIGHT=$((DEPTH_HEIGHT - (DEPTH_HEIGHT % 2)))
    fi
}

# Function to verify video properties match
verify_videos_match() {
    local video1="$1"
    local video2="$2"
    
    local fps1=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$video1" | awk -F'/' '{if ($2+0 == 0) print 0; else print ($1+0)/($2+0)}')
    local fps2=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$video2" | awk -F'/' '{if ($2+0 == 0) print 0; else print ($1+0)/($2+0)}')
    
    local duration1=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video1")
    local duration2=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video2")
    
    local frames1=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_frames -of default=noprint_wrappers=1:nokey=1 "$video1" 2>/dev/null || echo "")
    local frames2=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_frames -of default=noprint_wrappers=1:nokey=1 "$video2" 2>/dev/null || echo "")
    
    local mismatch=false
    
    if [ -n "$frames1" ] && [ -n "$frames2" ] && [ "$frames1" != "$frames2" ]; then
        echo "⚠️  SEVERE WARNING: Frame count mismatch! RGB: $frames1, Depth: $frames2" | tee -a "$LOG_FILE"
        mismatch=true
    fi
    
    local fps_diff=$(echo "$fps1 $fps2" | awk '{diff = ($1 > $2) ? ($1 - $2) : ($2 - $1); print diff}')
    if [ "$(echo "$fps_diff > 0.01" | bc -l 2>/dev/null || echo "0")" = "1" ]; then
        echo "⚠️  SEVERE WARNING: FPS mismatch! RGB: $fps1, Depth: $fps2" | tee -a "$LOG_FILE"
        mismatch=true
    fi
    
    local dur_diff=$(echo "$duration1 $duration2" | awk '{diff = ($1 > $2) ? ($1 - $2) : ($2 - $1); print diff}')
    if [ "$(echo "$dur_diff > 0.1" | bc -l 2>/dev/null || echo "0")" = "1" ]; then
        echo "⚠️  SEVERE WARNING: Duration mismatch! RGB: ${duration1}s, Depth: ${duration2}s" | tee -a "$LOG_FILE"
        mismatch=true
    fi
    
    if [ "$mismatch" = true ]; then
        echo "❌ CRITICAL: RGB and depth videos do not match! This may cause synchronization issues." | tee -a "$LOG_FILE"
        return 1
    else
        echo "✅ RGB and depth videos match (FPS: $fps1, Duration: ${duration1}s, Frames: ${frames1:-N/A})" | tee -a "$LOG_FILE"
        return 0
    fi
}

# Function to extract depth min/max from da3 output
extract_depth_stats() {
    local scene_dir="$1"
    # da3 creates exports/mini_npz/results.npz
    local depth_npz="${scene_dir}/exports/mini_npz/results.npz"
    
    if [ ! -f "$depth_npz" ]; then
        echo "" >&2
        return
    fi
    
    python3 <<EOF 2>/dev/null
import numpy as np

try:
    data = np.load("$depth_npz")
    if 'depth' in data:
        depth = data['depth']
        # Filter out invalid depths
        valid_depths = depth[depth > 0]
        if len(valid_depths) > 0:
            min_depth = float(np.min(valid_depths))
            max_depth = float(np.max(valid_depths))
            print(f"{min_depth} {max_depth}")
        else:
            print("0.0 10.0")
    else:
        print("0.0 10.0")
except Exception as e:
    print("0.0 10.0")
EOF
}

# Initialize metadata.json early
if [ "$IS_NEW_RUN" = true ] || [ ! -f "$METADATA_FILE" ]; then
    python3 <<EOF
import json
from pathlib import Path

metadata_file = Path("$METADATA_FILE")
metadata = {
    "video_file": "$INPUT_VIDEO",
    "max_res": $MAX_RES,
    "max_fps": $MAX_FPS,
    "max_clip": $MAX_CLIP,
    "depth_scale": 1.0,
    "depth_shift": 0.0,
    "fov": 60,
    "max_depth": 10
}

max_len_str = "$MAX_LEN"
if max_len_str:
    metadata["max_len"] = float(max_len_str)

da3_model_dir_str = "$DA3_MODEL_DIR"
if da3_model_dir_str:
    metadata["da3_model_dir"] = da3_model_dir_str

with open(metadata_file, "w") as f:
    json.dump(metadata, f, indent=2)
EOF
fi

# Step 1: Split video into scenes
if [ "$IS_NEW_RUN" = true ] || [ ! -d "$SCENES_DIR" ] || [ -z "$(ls -A "$SCENES_DIR" 2>/dev/null)" ]; then
    echo "Splitting video into scenes..." | tee -a "$LOG_FILE"
    mkdir -p "$SCENES_DIR"
    
    if [ ! -f "$SCENE_SPLIT_SCRIPT" ]; then
        echo "Error: Scene splitting script not found: $SCENE_SPLIT_SCRIPT" >&2
        exit 1
    fi
    
    # Split video with MAX_LEN cropping if specified
    # Use temporary file for timestamps, then store in metadata.json
    TEMP_TIMESTAMPS="${ROOT_DIR}/.temp_scene_timestamps.json"
    SCENE_SPLIT_ARGS=("$INPUT_VIDEO" "-o" "$SCENES_DIR")
    if [ -n "$MAX_LEN" ]; then
        SCENE_SPLIT_ARGS+=("--max-len" "$MAX_LEN")
    fi
    SCENE_SPLIT_ARGS+=("--output-timestamps" "$TEMP_TIMESTAMPS")
    
    if ! micromamba run -n da3 python "$SCENE_SPLIT_SCRIPT" "${SCENE_SPLIT_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        echo "Error: Failed to split video into scenes" >&2
        exit 1
    fi
    
    if [ ! -f "$TEMP_TIMESTAMPS" ]; then
        echo "Error: Scene timestamps file not created" >&2
        exit 1
    fi
    
    # Store scene timestamps in metadata.json
    SCENE_TIMESTAMPS=$(cat "$TEMP_TIMESTAMPS")
    python3 <<EOF
import json
from pathlib import Path

metadata_file = Path("$METADATA_FILE")
metadata = {}
if metadata_file.exists():
    with open(metadata_file, 'r') as f:
        metadata = json.load(f)

scene_timestamps = json.loads('''$SCENE_TIMESTAMPS''')
metadata['scene_timestamps'] = scene_timestamps
metadata['scene_count'] = len(scene_timestamps)

with open(metadata_file, 'w') as f:
    json.dump(metadata, f, indent=2)
EOF
    rm "$TEMP_TIMESTAMPS"
    
    echo "Scenes split successfully" | tee -a "$LOG_FILE"
else
    echo "Scenes directory already exists, skipping scene splitting" | tee -a "$LOG_FILE"
fi

# Count scenes
SCENE_COUNT=$(ls -1 "${SCENES_DIR}"/scene_*.mp4 2>/dev/null | wc -l)
if [ "$SCENE_COUNT" -eq 0 ]; then
    echo "Error: No scene files found in $SCENES_DIR" >&2
    exit 1
fi

echo "Found $SCENE_COUNT scenes" | tee -a "$LOG_FILE"

# Step 2: Process RGB scenes (reencode with proper FPS)
if [ ! -f "$RGB_VIDEO" ]; then
    echo "Creating rgb.mp4 from scenes..." | tee -a "$LOG_FILE"
    
    extract_video_metadata "$INPUT_VIDEO"
    
    # Create concat file for ffmpeg
    CONCAT_FILE="${ROOT_DIR}/rgb_concat.txt"
    > "$CONCAT_FILE"
    for scene_file in "${SCENES_DIR}"/scene_*.mp4; do
        echo "file '$(basename "$scene_file")'" >> "$CONCAT_FILE"
    done
    
    # Reencode each scene to match target FPS, then concatenate
    TEMP_SCENES_DIR="${ROOT_DIR}/rgb_scenes_temp"
    mkdir -p "$TEMP_SCENES_DIR"
    
    for scene_file in "${SCENES_DIR}"/scene_*.mp4; do
        scene_name=$(basename "$scene_file")
        temp_scene="${TEMP_SCENES_DIR}/${scene_name}"
        ffmpeg -i "$scene_file" -vf "fps=fps=${METADATA_ACTUAL_FPS}" -c:v libx264 -pix_fmt yuv420p -crf 18 -y "$temp_scene" >/dev/null 2>&1
    done
    
    # Update concat file to point to temp scenes
    > "$CONCAT_FILE"
    for scene_file in "${TEMP_SCENES_DIR}"/scene_*.mp4; do
        echo "file '$(realpath "$scene_file")'" >> "$CONCAT_FILE"
    done
    
    # Concatenate all scenes
    ffmpeg -f concat -safe 0 -i "$CONCAT_FILE" -c:v libx264 -pix_fmt yuv420p -crf 18 -y "$RGB_VIDEO" >/dev/null 2>&1
    
    rm -rf "$TEMP_SCENES_DIR" "$CONCAT_FILE"
    
    echo "rgb.mp4 created: $RGB_VIDEO" | tee -a "$LOG_FILE"
else
    echo "rgb.mp4 already exists, skipping creation" | tee -a "$LOG_FILE"
fi

# Step 3: Process depth scenes with da3 (unless --no-depth)
if [ "$NO_DEPTH" = false ]; then
    # DA3_MODEL_DIR defaults to depth-anything/DA3NESTED-GIANT-LARGE
    if [ -z "$DA3_MODEL_DIR" ]; then
        DA3_MODEL_DIR="depth-anything/DA3NESTED-GIANT-LARGE"
    fi
    
    # Check backend if using backend mode
    if [ "$USE_BACKEND" = true ]; then
        echo "Checking DA3 backend at $BACKEND_URL..." | tee -a "$LOG_FILE"
        if ! curl -s "$BACKEND_URL/status" >/dev/null 2>&1; then
            echo "Warning: Backend not responding at $BACKEND_URL. Please start it manually:" | tee -a "$LOG_FILE"
            echo "  da3 backend --model-dir $DA3_MODEL_DIR --host 0.0.0.0 --port $(echo $BACKEND_URL | awk -F: '{print $NF}')" | tee -a "$LOG_FILE"
            echo "Continuing without backend..." | tee -a "$LOG_FILE"
            USE_BACKEND=false
        fi
    else
        echo "Using live inference (no backend)" | tee -a "$LOG_FILE"
    fi
    
    # Process each scene with da3
    SCENE_DEPTH_STATS=()
    SCENE_FLAT_DEPTH=()
    
    # Count total scenes for progress tracking
    SCENE_FILES=("${SCENES_DIR}"/scene_*.mp4)
    TOTAL_SCENES=${#SCENE_FILES[@]}
    CURRENT_SCENE=0
    
    echo "========================================" | tee -a "$LOG_FILE"
    echo "Starting depth processing for $TOTAL_SCENES scenes" | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
    
    for scene_file in "${SCENES_DIR}"/scene_*.mp4; do
        CURRENT_SCENE=$((CURRENT_SCENE + 1))
        scene_name=$(basename "$scene_file" .mp4)
        scene_num=$(echo "$scene_name" | sed 's/scene_0*//')
        scene_dir="${SCENES_DIR}/${scene_name}"
        scene_depth_video="${scene_dir}/depth.mp4"
        
        echo "" | tee -a "$LOG_FILE"
        echo "[$CURRENT_SCENE/$TOTAL_SCENES] Processing depth for $scene_name..." | tee -a "$LOG_FILE"
        
        if [ ! -f "$scene_depth_video" ]; then
            mkdir -p "$scene_dir"
            
            # Check scene duration
            scene_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$scene_file")
            scene_exceeds_max=$(echo "$scene_duration $MAX_CLIP" | awk '{if ($1 > $2) print 1; else print 0}')
            
            if [ "$scene_exceeds_max" = "1" ]; then
                echo "  ⚠️  Scene duration (${scene_duration}s) exceeds MAX_CLIP (${MAX_CLIP}s)" | tee -a "$LOG_FILE"
                echo "  → Creating flat depth video (value=100)..." | tee -a "$LOG_FILE"
                
                # Calculate FPS and dimensions for flat depth video
                scene_fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$scene_file" | awk -F'/' '{if ($2+0 == 0) print 0; else print ($1+0)/($2+0)}')
                actual_scene_fps=$(echo "$scene_fps $MAX_FPS" | awk '{if ($1 < $2) print $1; else print $2}')
                scene_width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$scene_file")
                scene_height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$scene_file")
                
                # Calculate number of frames needed
                num_frames=$(echo "$scene_duration $actual_scene_fps" | awk '{printf "%.0f", $1 * $2}')
                
                # Create flat depth video with value 100 everywhere
                echo "  → Generating flat depth video..." | tee -a "$LOG_FILE"
                python3 <<EOF
import numpy as np
import cv2
from pathlib import Path

scene_depth_video = "$scene_depth_video"
fps = $actual_scene_fps
width = $scene_width
height = $scene_height
num_frames = $num_frames

# Create flat depth frame with value 100 (grayscale)
flat_frame = np.full((height, width), 100, dtype=np.uint8)

# Create video writer
fourcc = cv2.VideoWriter_fourcc(*'mp4v')
out = cv2.VideoWriter(scene_depth_video, fourcc, fps, (width, height), False)

# Write frames
for _ in range(num_frames):
    out.write(flat_frame)

out.release()
print(f"    Created flat depth video: {scene_depth_video} ({num_frames} frames, value=100)")
EOF
                
                # Mark as flat depth
                SCENE_FLAT_DEPTH+=("$scene_num")
                # Set depth stats for flat depth (100 normalized, but we'll record as flat)
                SCENE_DEPTH_STATS+=("$scene_num:100.0 100.0")
                echo "  ✅ Completed flat depth for $scene_name" | tee -a "$LOG_FILE"
            else
                # Calculate FPS for this scene (min of scene FPS and MAX_FPS)
                scene_fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$scene_file" | awk -F'/' '{if ($2+0 == 0) print 0; else print ($1+0)/($2+0)}')
                actual_scene_fps=$(echo "$scene_fps $MAX_FPS" | awk '{if ($1 < $2) print $1; else print $2}')
                
                # Process with da3 - export both mini_npz (for stats) and depth_vis (for video)
                echo "  → Starting da3 depth estimation (live inference)..." | tee -a "$LOG_FILE"
                echo "    Input: $scene_file" | tee -a "$LOG_FILE"
                echo "    FPS: $actual_scene_fps, Resolution: ${MAX_RES}px (max)" | tee -a "$LOG_FILE"
                if [ "$USE_BACKEND" = true ]; then
                    echo "    Using backend: $BACKEND_URL" | tee -a "$LOG_FILE"
                else
                    echo "    Using live inference (direct model loading)" | tee -a "$LOG_FILE"
                fi
                
                DA3_ARGS=(
                    "video" "$scene_file"
                    "--model-dir" "$DA3_MODEL_DIR"
                    "--export-dir" "$scene_dir"
                    "--export-format" "mini_npz"
                    "--process-res" "$MAX_RES"
                    "--fps" "$actual_scene_fps"
                    "--auto-cleanup"
                )
                
                if [ "$USE_BACKEND" = true ]; then
                    DA3_ARGS+=("--use-backend" "--backend-url" "$BACKEND_URL")
                fi
                
                DA3_START_TIME=$(date +%s)
                
                # Capture da3 output to check for OOM errors
                DA3_OUTPUT=$(mktemp)
                DA3_EXIT_CODE=0
                micromamba run -n da3 da3 "${DA3_ARGS[@]}" 2>&1 | tee "$DA3_OUTPUT" | tee -a "$LOG_FILE" || DA3_EXIT_CODE=${PIPESTATUS[0]}
                
                # Check for OOM errors in output
                OOM_DETECTED=false
                if grep -qi "out of memory\|OOM\|CUDA out of memory\|RuntimeError.*memory" "$DA3_OUTPUT"; then
                    OOM_DETECTED=true
                fi
                
                rm "$DA3_OUTPUT"
                
                if [ "$DA3_EXIT_CODE" -ne 0 ] || [ "$OOM_DETECTED" = true ]; then
                    if [ "$OOM_DETECTED" = true ]; then
                        echo "  ⚠️  Out of Memory (OOM) detected during da3 processing" | tee -a "$LOG_FILE"
                        echo "  → Falling back to flat depth video (value=100)..." | tee -a "$LOG_FILE"
                    else
                        echo "  ⚠️  da3 processing failed (exit code: $DA3_EXIT_CODE)" | tee -a "$LOG_FILE"
                        echo "  → Falling back to flat depth video (value=100)..." | tee -a "$LOG_FILE"
                    fi
                    
                    # Create flat depth video as fallback
                    scene_fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$scene_file" | awk -F'/' '{if ($2+0 == 0) print 0; else print ($1+0)/($2+0)}')
                    actual_scene_fps=$(echo "$scene_fps $MAX_FPS" | awk '{if ($1 < $2) print $1; else print $2}')
                    scene_width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$scene_file")
                    scene_height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$scene_file")
                    num_frames=$(echo "$scene_duration $actual_scene_fps" | awk '{printf "%.0f", $1 * $2}')
                    
                    python3 <<EOF
import numpy as np
import cv2

scene_depth_video = "$scene_depth_video"
fps = $actual_scene_fps
width = $scene_width
height = $scene_height
num_frames = $num_frames

flat_frame = np.full((height, width), 100, dtype=np.uint8)
fourcc = cv2.VideoWriter_fourcc(*'mp4v')
out = cv2.VideoWriter(scene_depth_video, fourcc, fps, (width, height), False)

for _ in range(num_frames):
    out.write(flat_frame)

out.release()
print(f"    Created flat depth video: {scene_depth_video} ({num_frames} frames, value=100)")
EOF
                    
                    SCENE_FLAT_DEPTH+=("$scene_num")
                    SCENE_DEPTH_STATS+=("$scene_num:1.0 2.0")
                    echo "  ✅ Completed flat depth fallback for $scene_name" | tee -a "$LOG_FILE"
                else
                    DA3_END_TIME=$(date +%s)
                    DA3_DURATION=$((DA3_END_TIME - DA3_START_TIME))
                    echo "  ✅ da3 processing completed in ${DA3_DURATION}s" | tee -a "$LOG_FILE"
                    
                    # Create depth video from numpy files using scene metadata
                    echo "  → Creating depth video from numpy data..." | tee -a "$LOG_FILE"
                    
                    # Get scene duration and fps from the scene video file
                    scene_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$scene_file")
                    scene_width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$scene_file")
                    scene_height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$scene_file")
                    
                    python3 <<EOF
import numpy as np
import cv2
from pathlib import Path
import sys

scene_dir = Path("$scene_dir")
depth_npz = scene_dir / "exports" / "mini_npz" / "results.npz"
depth_video = "$scene_depth_video"
fps = $actual_scene_fps
target_duration = $scene_duration
target_width = $scene_width
target_height = $scene_height

if not depth_npz.exists():
    print(f"Error: npz file not found at {depth_npz}", file=sys.stderr)
    sys.exit(1)

data = np.load(depth_npz)
if 'depth' not in data:
    print("Error: No depth data in npz file", file=sys.stderr)
    sys.exit(1)

depth = data['depth']

# Normalize depth to 0-255
depth_min = np.min(depth[depth > 0]) if np.any(depth > 0) else 0
depth_max = np.max(depth)
if depth_max <= depth_min:
    depth_max = depth_min + 1
depth_normalized = ((depth - depth_min) / (depth_max - depth_min) * 255).astype(np.uint8)

# Handle different depth array shapes
final_frame_count = 0
if depth_normalized.ndim == 2:
    # Single frame - repeat to match duration
    height, width = depth_normalized.shape
    num_frames = int(np.ceil(target_duration * fps))
    final_frame_count = num_frames
    fourcc = cv2.VideoWriter_fourcc(*'mp4v')
    out = cv2.VideoWriter(depth_video, fourcc, fps, (width, height), False)
    for _ in range(num_frames):
        out.write(depth_normalized)
    out.release()
elif depth_normalized.ndim == 3:
    # Multiple frames - da3 outputs (frames, height, width) format
    # Check if shape is (height, width, frames) and transpose if needed
    # If the last dimension is the smallest and much smaller than others, it's likely frames
    if depth_normalized.shape[2] < depth_normalized.shape[0] and depth_normalized.shape[2] < depth_normalized.shape[1]:
        # Shape is likely (height, width, frames) - transpose to (frames, height, width)
        depth_normalized = np.transpose(depth_normalized, (2, 0, 1))
    # Otherwise, assume it's already (frames, height, width) format
    
    # Now depth_normalized should be (frames, height, width)
    num_frames_depth = depth_normalized.shape[0]
    height, width = depth_normalized.shape[1:3]
    
    # Calculate target number of frames based on duration and fps
    target_frames = int(np.ceil(target_duration * fps))
    
    # Verify aspect ratio matches (within tolerance)
    scene_aspect = target_width / target_height
    depth_aspect = width / height
    aspect_diff = abs(scene_aspect - depth_aspect)
    if aspect_diff > 0.01:
        print(f"Warning: Aspect ratio mismatch - Scene: {scene_aspect:.3f}, Depth: {depth_aspect:.3f}", file=sys.stderr)
    
    # Repeat or interpolate frames to match target duration
    if num_frames_depth < target_frames:
        # Repeat frames to match duration
        frame_indices = np.linspace(0, num_frames_depth - 1, target_frames).astype(int)
        depth_normalized = depth_normalized[frame_indices]
    elif num_frames_depth > target_frames:
        # Sample frames to match duration
        frame_indices = np.linspace(0, num_frames_depth - 1, target_frames).astype(int)
        depth_normalized = depth_normalized[frame_indices]
    
    # Use original depth resolution (no resizing, preserve aspect ratio)
    fourcc = cv2.VideoWriter_fourcc(*'mp4v')
    out = cv2.VideoWriter(depth_video, fourcc, fps, (width, height), False)
    final_frame_count = len(depth_normalized)
    for frame in depth_normalized:
        out.write(frame)
    out.release()
else:
    final_frame_count = int(np.ceil(target_duration * fps))

print(f"Created depth video: {depth_video}")
if 'width' in locals() and 'height' in locals():
    print(f"  Resolution: {width}x{height}")
print(f"  FPS: {fps}")
print(f"  Duration: {target_duration}s")
print(f"  Frames: {final_frame_count}")
EOF
                    
                    if [ ! -f "$scene_depth_video" ]; then
                        echo "  ❌ Error: Failed to create depth video for $scene_name, skipping..." | tee -a "$LOG_FILE"
                        continue
                    fi
                    echo "    ✅ Depth video created: $scene_depth_video" | tee -a "$LOG_FILE"
                    
                    # Extract depth stats
                    echo "  → Extracting depth statistics..." | tee -a "$LOG_FILE"
                    depth_stats=$(extract_depth_stats "$scene_dir")
                    if [ -n "$depth_stats" ]; then
                        SCENE_DEPTH_STATS+=("$scene_num:$depth_stats")
                        echo "    Depth range: $depth_stats" | tee -a "$LOG_FILE"
                    fi
                    echo "  ✅ Completed processing $scene_name" | tee -a "$LOG_FILE"
                fi
            fi
        else
            echo "  ⏭️  Depth video already exists for $scene_name, skipping da3 processing..." | tee -a "$LOG_FILE"
            # Try to extract existing stats
            depth_stats=$(extract_depth_stats "$scene_dir")
            if [ -n "$depth_stats" ]; then
                SCENE_DEPTH_STATS+=("$scene_num:$depth_stats")
                echo "    Depth range: $depth_stats" | tee -a "$LOG_FILE"
            fi
        fi
    done
    
    echo "" | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
    echo "✅ All depth processing completed ($TOTAL_SCENES scenes)" | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    
    # Verify all depth videos exist before stitching
    echo "Verifying all depth videos are ready..." | tee -a "$LOG_FILE"
    MISSING_DEPTH_VIDEOS=()
    for scene_file in "${SCENES_DIR}"/scene_*.mp4; do
        scene_name=$(basename "$scene_file" .mp4)
        scene_depth_video="${SCENES_DIR}/${scene_name}/depth.mp4"
        if [ ! -f "$scene_depth_video" ]; then
            MISSING_DEPTH_VIDEOS+=("$scene_name")
        fi
    done
    
    if [ ${#MISSING_DEPTH_VIDEOS[@]} -gt 0 ]; then
        echo "❌ Error: Missing depth videos for scenes: ${MISSING_DEPTH_VIDEOS[*]}" | tee -a "$LOG_FILE"
        exit 1
    fi
    
    echo "✅ All $TOTAL_SCENES depth videos verified" | tee -a "$LOG_FILE"
    
    # Stitch depth scenes together
    if [ ! -f "$DEPTH_VIDEO" ]; then
        echo "" | tee -a "$LOG_FILE"
        echo "========================================" | tee -a "$LOG_FILE"
        echo "Stitching depth scenes into final video..." | tee -a "$LOG_FILE"
        echo "========================================" | tee -a "$LOG_FILE"
        
        CONCAT_FILE="${ROOT_DIR}/depth_concat.txt"
        > "$CONCAT_FILE"
        SCENES_TO_STITCH=0
        for scene_file in "${SCENES_DIR}"/scene_*.mp4; do
            scene_name=$(basename "$scene_file" .mp4)
            scene_depth_video="${SCENES_DIR}/${scene_name}/depth.mp4"
            if [ -f "$scene_depth_video" ]; then
                echo "file '$(realpath "$scene_depth_video")'" >> "$CONCAT_FILE"
                SCENES_TO_STITCH=$((SCENES_TO_STITCH + 1))
            fi
        done
        
        if [ -s "$CONCAT_FILE" ]; then
            echo "Concatenating $SCENES_TO_STITCH depth scenes..." | tee -a "$LOG_FILE"
            STITCH_START_TIME=$(date +%s)
            ffmpeg -f concat -safe 0 -i "$CONCAT_FILE" -c:v libx264 -pix_fmt yuv420p -crf 18 -y "$DEPTH_VIDEO" >/dev/null 2>&1
            STITCH_END_TIME=$(date +%s)
            STITCH_DURATION=$((STITCH_END_TIME - STITCH_START_TIME))
            rm "$CONCAT_FILE"
            echo "✅ depth.mp4 created in ${STITCH_DURATION}s: $DEPTH_VIDEO" | tee -a "$LOG_FILE"
        else
            echo "Error: No depth scenes to concatenate" >&2
            exit 1
        fi
    else
        echo "depth.mp4 already exists, skipping creation" | tee -a "$LOG_FILE"
    fi
    
    # Verify RGB and depth match
    if [ -f "$RGB_VIDEO" ] && [ -f "$DEPTH_VIDEO" ]; then
        verify_videos_match "$RGB_VIDEO" "$DEPTH_VIDEO"
    fi
else
    echo "Skipping depth estimation (--no-depth specified)" | tee -a "$LOG_FILE"
fi

# Step 4: Create/update metadata.json
echo "Updating metadata.json..." | tee -a "$LOG_FILE"
extract_video_metadata "$RGB_VIDEO"

# Load existing metadata or create new
python3 <<EOF
import json
from pathlib import Path

metadata_file = Path("$METADATA_FILE")
metadata = {}
if metadata_file.exists():
    with open(metadata_file, 'r') as f:
        metadata = json.load(f)

# Get scene timestamps from metadata
scene_timestamps = metadata.get('scene_timestamps', [])

# Build scene metadata with depth stats
scene_depth_stats = []
for stat in '''${SCENE_DEPTH_STATS[@]}'''.split():
    if ':' in stat:
        parts = stat.split(':', 1)
        if len(parts) == 2:
            scene_num, depths = parts
            depth_parts = depths.split()
            if len(depth_parts) == 2:
                min_depth, max_depth = depth_parts
                scene_depth_stats.append({
                    "scene_number": int(scene_num),
                    "min_depth": float(min_depth),
                    "max_depth": float(max_depth)
                })

flat_depth_scenes = []
for flat_scene in '''${SCENE_FLAT_DEPTH[@]}'''.split():
    if flat_scene:
        flat_depth_scenes.append(int(flat_scene))

scenes = []
for i, timestamp in enumerate(scene_timestamps):
    scene_info = {"start_time": timestamp}
    # Find matching depth stats
    for stat in scene_depth_stats:
        if stat["scene_number"] == i + 1:
            scene_info["min_depth"] = stat["min_depth"]
            scene_info["max_depth"] = stat["max_depth"]
            break
    # Mark if flat depth
    if (i + 1) in flat_depth_scenes:
        scene_info["flat_depth"] = True
    scenes.append(scene_info)

metadata['scenes'] = scenes

# Write updated metadata back
with open(metadata_file, 'w') as f:
    json.dump(metadata, f, indent=2)
EOF

calculate_depth_dimensions "$METADATA_WIDTH" "$METADATA_HEIGHT" "$MAX_RES"

# Create/update metadata JSON with all information
python3 <<EOF | tee -a "$LOG_FILE"
import json
from pathlib import Path

metadata_file = Path("$METADATA_FILE")

# Load existing metadata (may have scene_timestamps and scenes already)
metadata = {}
if metadata_file.exists():
    with open(metadata_file, 'r') as f:
        metadata = json.load(f)

# Update with video metadata (scenes already updated in previous step)
metadata.update({
    "original_fps": $METADATA_ORIGINAL_FPS,
    "fps": $METADATA_ACTUAL_FPS,
    "duration": $METADATA_DURATION,
    "width": $METADATA_WIDTH,
    "height": $METADATA_HEIGHT,
    "depth_width": $DEPTH_WIDTH,
    "depth_height": $DEPTH_HEIGHT,
    "codec": "$METADATA_CODEC",
    "bitrate": $METADATA_BITRATE,
    "num_frames": ${METADATA_NUM_FRAMES:-None},
    "video_file": "$INPUT_VIDEO",
    "fov": 60,
    "max_depth": 10,
    "depth_scale": 1.0,
    "depth_shift": 0.0,
    "scene_count": $SCENE_COUNT,
    "max_res": $MAX_RES,
    "max_fps": $MAX_FPS,
    "max_clip": $MAX_CLIP
})

# Ensure scenes are preserved (already updated in previous step)
if 'scenes' not in metadata:
    metadata['scenes'] = []

max_len_str = "$MAX_LEN"
if max_len_str:
    metadata["max_len"] = float(max_len_str)

da3_model_dir_str = "$DA3_MODEL_DIR"
if da3_model_dir_str:
    metadata["da3_model_dir"] = da3_model_dir_str

with open(metadata_file, "w") as f:
    json.dump(metadata, f, indent=2)

print(f"Metadata saved to $METADATA_FILE")
EOF

# Step 5: Export (create export.zip unless --no-export)
if [ "$NO_EXPORT" = false ]; then
    EXPORT_ZIP="${ROOT_DIR}/export.zip"
    
    if [ ! -f "$EXPORT_ZIP" ]; then
        echo "Creating export.zip..." | tee -a "$LOG_FILE"
        
        # Check required files exist
        if [ ! -f "$METADATA_FILE" ]; then
            echo "Error: Metadata file not found: $METADATA_FILE" >&2
            exit 1
        fi
        
        if [ ! -f "$RGB_VIDEO" ]; then
            echo "Error: RGB video not found: $RGB_VIDEO" >&2
            exit 1
        fi
        
        if [ "$NO_DEPTH" = false ] && [ ! -f "$DEPTH_VIDEO" ]; then
            echo "Error: Depth video not found: $DEPTH_VIDEO" >&2
            exit 1
        fi
        
        # Create export.zip using Python
        python3 <<EOF | tee -a "$LOG_FILE"
import zipfile
import os

output_dir = "$ROOT_DIR"
export_zip = "$EXPORT_ZIP"
depth_video = "$DEPTH_VIDEO"
rgb_video = "$RGB_VIDEO"
metadata_file = "$METADATA_FILE"

with zipfile.ZipFile(export_zip, 'w', zipfile.ZIP_DEFLATED) as zipf:
    zipf.write(rgb_video, os.path.basename(rgb_video))
    zipf.write(metadata_file, os.path.basename(metadata_file))
    if os.path.exists(depth_video):
        zipf.write(depth_video, os.path.basename(depth_video))

print(f"Export complete: {export_zip}")
print("Contents:")
with zipfile.ZipFile(export_zip, 'r') as zipf:
    for info in zipf.infolist():
        print(f"  {info.filename} ({info.file_size} bytes)")
EOF
        
        echo "Export complete: $EXPORT_ZIP" | tee -a "$LOG_FILE"
    else
        echo "export.zip already exists, skipping export" | tee -a "$LOG_FILE"
    fi
else
    echo "Skipping export (--no-export specified)" | tee -a "$LOG_FILE"
fi

echo "Processing complete! Output directory: $ROOT_DIR" | tee -a "$LOG_FILE"
