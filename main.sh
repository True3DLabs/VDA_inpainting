#!/bin/bash
# Master script for video processing pipeline
# Usage: ./main.sh <input_video_or_folder> [--max-fps N] [--max-res N] [--max-len N] [--no-depth] [--no-export]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_FPS=24
MAX_RES=1280
MAX_LEN=""
NO_DEPTH=false
NO_EXPORT=false
SAVE_NPZ=false

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
    --no-depth)
      NO_DEPTH=true; shift ;;
    --no-export)
      NO_EXPORT=true; shift ;;
    --npz)
      SAVE_NPZ=true; shift ;;
    --help|-h)
      cat >&2 <<USAGE
Usage: $0 <input_video_or_folder> [options]

Options:
  --max-fps N       Maximum FPS for processing (default: 24)
  --max-res N       Maximum resolution for larger side (default: 1280)
  --max-len N       Maximum length in seconds to clip video (default: no limit)
  --no-depth        Skip depth estimation (VDA)
  --no-export       Skip export.zip creation
  --npz             Save raw metric depth values to depth.npz (unquantized)
  --help            Show this help message

The script can be run on:
  - An input video file: Creates new output directory and processes
  - An existing output folder: Resumes processing, skipping existing files

Example:
  $0 input_video.mp4 --max-fps 30 --max-res 1920 --max-len 10
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
else
  echo "Error: Input not found: $INPUT" >&2
  exit 1
fi

FRAMES_DIR="${ROOT_DIR}/frames"
METADATA_FILE="${ROOT_DIR}/metadata.json"
REFERENCE_VIDEO="${ROOT_DIR}/rgb.mp4"
DEPTH_VIDEO="${ROOT_DIR}/depth.mp4"
DEPTH_NPZ="${ROOT_DIR}/depth.npz"
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

# Function to update metadata with scene information
update_metadata_with_scenes() {
    local metadata_file="$1"
    local video_file="$2"
    local frames_dir="$3"
    local scene_depth_stats_file="$4"
    
    extract_video_metadata "$video_file"
    calculate_depth_dimensions "$METADATA_WIDTH" "$METADATA_HEIGHT" "$MAX_RES"
    
    local extracted_frames=0
    if [ -d "$frames_dir" ]; then
        extracted_frames=$(ls -1 "${frames_dir}"/frame_*.png 2>/dev/null | wc -l)
    fi
    
    python3 <<EOF
import json
from pathlib import Path

metadata_file = Path("$metadata_file")
scene_depth_stats_file_str = "$scene_depth_stats_file"
scene_depth_stats_file = Path(scene_depth_stats_file_str) if scene_depth_stats_file_str and scene_depth_stats_file_str.strip() else None

# Load existing metadata (should already have scene_timestamps)
metadata = {}
if metadata_file.exists():
    with open(metadata_file, 'r') as f:
        metadata = json.load(f)

# Get scene timestamps from metadata (already there from scene detection)
scene_timestamps = metadata.get('scene_timestamps', [])

# Load scene depth stats if available
scene_min_depths = []
scene_max_depths = []
if scene_depth_stats_file and scene_depth_stats_file.exists():
    with open(scene_depth_stats_file, 'r') as f:
        depth_stats = json.load(f)
        scene_min_depths = depth_stats.get('scene_min_depths', [])
        scene_max_depths = depth_stats.get('scene_max_depths', [])

# Ensure arrays match scene count
# Default to 1 scene starting at 0.0 if no scenes detected
if not scene_timestamps or len(scene_timestamps) == 0:
    scene_timestamps = [0.0]

scene_count = len(scene_timestamps) if scene_timestamps else 1

# Use real depth stats from VDA - don't pad with defaults
# If depth stats don't match scene count, that's okay - they'll be updated after VDA runs
# The depth stats will have real metric depth values, not placeholder defaults

# Create scene_fovs array (default 60)
scene_fovs = [60.0] * scene_count

# Update metadata
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
    "extracted_frames": $extracted_frames,
    "frames_dir": "$frames_dir",
    "video_file": "$video_file",
    "global_depth_scale": 1.0,
    "global_depth_shift": 0.0,
    "fov": 60,
    "max_depth": 10,
    "scene_timestamps": scene_timestamps,
    "scene_min_depths": scene_min_depths,
    "scene_max_depths": scene_max_depths,
    "scene_fovs": scene_fovs,
    "scene_count": scene_count
})

max_len_str = "$MAX_LEN"
if max_len_str and "$METADATA_ORIGINAL_DURATION" != "$METADATA_DURATION":
    metadata["original_duration"] = $METADATA_ORIGINAL_DURATION
    metadata["max_len"] = float(max_len_str)

with open(metadata_file, 'w') as f:
    json.dump(metadata, f, indent=2)
EOF
}

# Function to create or update metadata.json
create_metadata() {
    local metadata_file="$1"
    local video_file="$2"
    local frames_dir="$3"
    local include_depth_dims=${4:-false}
    
    extract_video_metadata "$video_file"
    
    # Count extracted frames if frames directory exists
    local extracted_frames=0
    if [ -d "$frames_dir" ]; then
        extracted_frames=$(ls -1 "${frames_dir}"/frame_*.png 2>/dev/null | wc -l)
    fi
    
    # Calculate depth dimensions if needed
    if [ "$include_depth_dims" = true ]; then
        calculate_depth_dimensions "$METADATA_WIDTH" "$METADATA_HEIGHT" "$MAX_RES"
    fi
    
    # Create metadata JSON file
    {
        echo "{"
        echo "\"original_fps\": $METADATA_ORIGINAL_FPS,"
        echo "\"fps\": $METADATA_ACTUAL_FPS,"
        echo "\"duration\": $METADATA_DURATION,"
        if [ -n "$MAX_LEN" ] && [ "$METADATA_ORIGINAL_DURATION" != "$METADATA_DURATION" ]; then
            echo "\"original_duration\": $METADATA_ORIGINAL_DURATION,"
            echo "\"max_len\": $MAX_LEN,"
        fi
        echo "\"width\": $METADATA_WIDTH,"
        echo "\"height\": $METADATA_HEIGHT,"
        if [ "$include_depth_dims" = true ]; then
            echo "\"depth_width\": $DEPTH_WIDTH,"
            echo "\"depth_height\": $DEPTH_HEIGHT,"
        fi
        echo "\"codec\": \"$METADATA_CODEC\","
        echo "\"bitrate\": $METADATA_BITRATE,"
        if [ -n "$METADATA_NUM_FRAMES" ]; then
            echo "\"num_frames\": $METADATA_NUM_FRAMES,"
        fi
        echo "\"extracted_frames\": $extracted_frames,"
        echo "\"frames_dir\": \"$frames_dir\","
        echo "\"video_file\": \"$video_file\","
        echo "\"fov\": 60,"
        echo "\"max_depth\": 10"
        echo "}"
    } > "$metadata_file"
}

# Step 1: Create reference video FIRST (needed for frame extraction timing)
# This is done early so frame extraction can use it
if [ ! -f "$REFERENCE_VIDEO" ]; then
    echo "Creating rgb.mp4 (re-encoded to match MAX_FPS if needed)..." | tee -a "$LOG_FILE"
    
    extract_video_metadata "$INPUT_VIDEO"
    
    # Re-encode input video to actual_fps (min of original and MAX_FPS) if needed
    # This ensures consistent timing for all downstream processing
    # Keep original resolution, use h264, and apply MAX_LEN if specified
    # Downmix audio to 2 channels (stereo)
    FFMPEG_CMD=(ffmpeg -i "$INPUT_VIDEO" -vf "fps=fps=${METADATA_ACTUAL_FPS}" -c:v libx264 -pix_fmt yuv420p -crf 18 -ac 2 -c:a aac)
    if [ -n "$MAX_LEN" ]; then
        FFMPEG_CMD+=(-t "$MAX_LEN")
    fi
    FFMPEG_CMD+=(-y "$REFERENCE_VIDEO")
    if ! "${FFMPEG_CMD[@]}" >/dev/null 2>&1; then
        echo "Error: Failed to create rgb.mp4" >&2
        exit 1
    fi
    
    echo "rgb.mp4 created: $REFERENCE_VIDEO" | tee -a "$LOG_FILE"
    
    # Extract exact properties from rgb.mp4 for downstream use
    extract_video_metadata "$REFERENCE_VIDEO"
    REFERENCE_FPS=$METADATA_ACTUAL_FPS
    REFERENCE_DURATION=$METADATA_DURATION
    REFERENCE_FRAMES=$METADATA_NUM_FRAMES
    
    echo "rgb.mp4 properties:" | tee -a "$LOG_FILE"
    echo "  FPS: $REFERENCE_FPS" | tee -a "$LOG_FILE"
    echo "  Duration: ${REFERENCE_DURATION}s" | tee -a "$LOG_FILE"
    echo "  Frames: ${REFERENCE_FRAMES:-N/A}" | tee -a "$LOG_FILE"
else
    echo "rgb.mp4 already exists, extracting properties..." | tee -a "$LOG_FILE"
    extract_video_metadata "$REFERENCE_VIDEO"
    REFERENCE_FPS=$METADATA_ACTUAL_FPS
    REFERENCE_DURATION=$METADATA_DURATION
    REFERENCE_FRAMES=$METADATA_NUM_FRAMES
fi

# Step 2: Extract frames and create metadata (if new run or frames don't exist)
# Use rgb.mp4 to ensure frames match timing exactly
if [ "$IS_NEW_RUN" = true ] || [ ! -d "$FRAMES_DIR" ] || [ -z "$(ls -A "$FRAMES_DIR" 2>/dev/null)" ]; then
    echo "Extracting frames from rgb.mp4..." | tee -a "$LOG_FILE"
    mkdir -p "$FRAMES_DIR"
    
    if ! command -v ffmpeg &> /dev/null; then
        echo "Error: ffmpeg not found. Please install ffmpeg." >&2
        exit 1
    fi
    
    # Extract frames from rgb.mp4 using reference FPS
    FFMPEG_CMD=(ffmpeg -i "$REFERENCE_VIDEO" -vf "fps=fps=${REFERENCE_FPS}")
    FFMPEG_CMD+=(-y "${FRAMES_DIR}/frame_%06d.png")
    if ! "${FFMPEG_CMD[@]}" >/dev/null 2>&1; then
        echo "Error: Failed to extract frames from rgb.mp4" >&2
        exit 1
    fi
    
    echo "Frames extracted to $FRAMES_DIR" | tee -a "$LOG_FILE"
else
    echo "Frames directory already exists, skipping extraction" | tee -a "$LOG_FILE"
fi

# Create or update metadata.json (without depth dimensions for now)
create_metadata "$METADATA_FILE" "$REFERENCE_VIDEO" "$FRAMES_DIR" false
echo "Metadata saved to $METADATA_FILE" | tee -a "$LOG_FILE"

# Step 3: Scene detection (if scene_timestamps not in metadata.json or empty)
if ! python3 -c "import json; data = json.load(open('$METADATA_FILE')); timestamps = data.get('scene_timestamps', []); exit(0 if timestamps and len(timestamps) > 0 else 1)" 2>/dev/null; then
    echo "Detecting scenes..." | tee -a "$LOG_FILE"
    
    if [ ! -f "$SCENE_SPLIT_SCRIPT" ]; then
        echo "Error: Scene splitting script not found: $SCENE_SPLIT_SCRIPT" >&2
        exit 1
    fi
    
    TEMP_TIMESTAMPS="${ROOT_DIR}/.temp_scene_timestamps.json"
    # Use rgb.mp4 for scene detection to ensure timestamps match
    # rgb.mp4 already has MAX_LEN applied, so don't pass it again
    SCENE_SPLIT_ARGS=("$REFERENCE_VIDEO" "-o" "${ROOT_DIR}/scenes_temp" "--output-timestamps" "$TEMP_TIMESTAMPS")
    
    if ! micromamba run -n da3 python "$SCENE_SPLIT_SCRIPT" "${SCENE_SPLIT_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        echo "Error: Failed to detect scenes" >&2
        exit 1
    fi
    
    if [ -f "$TEMP_TIMESTAMPS" ]; then
        # Update metadata.json with scene timestamps
        python3 <<EOF
import json
from pathlib import Path

metadata_file = Path("$METADATA_FILE")
temp_timestamps_file = Path("$TEMP_TIMESTAMPS")

# Load existing metadata
metadata = {}
if metadata_file.exists():
    with open(metadata_file, 'r') as f:
        metadata = json.load(f)

# Load scene timestamps
scene_timestamps = []
if temp_timestamps_file.exists():
    with open(temp_timestamps_file, 'r') as f:
        scene_timestamps = json.load(f)

# Default to 1 scene starting at 0.0 if no scenes detected
if not scene_timestamps or len(scene_timestamps) == 0:
    scene_timestamps = [0.0]

# Update metadata with scene timestamps
metadata['scene_timestamps'] = scene_timestamps
metadata['scene_count'] = len(scene_timestamps)

# Write back to metadata.json
with open(metadata_file, 'w') as f:
    json.dump(metadata, f, indent=2)

print(f"Scene timestamps ({len(scene_timestamps)} scenes) saved to metadata.json")
EOF
        rm -f "$TEMP_TIMESTAMPS"
        rm -rf "${ROOT_DIR}/scenes_temp"
        echo "Scene detection complete" | tee -a "$LOG_FILE"
    else
        echo "Warning: Scene timestamps file not created, defaulting to 1 scene starting at 0.0" | tee -a "$LOG_FILE"
        python3 <<EOF
import json
from pathlib import Path

metadata_file = Path("$METADATA_FILE")
metadata = {}
if metadata_file.exists():
    with open(metadata_file, 'r') as f:
        metadata = json.load(f)

# Default to 1 scene starting at 0.0
metadata['scene_timestamps'] = [0.0]
metadata['scene_count'] = 1

with open(metadata_file, 'w') as f:
    json.dump(metadata, f, indent=2)
EOF
    fi
else
    echo "Scene timestamps already in metadata.json, skipping scene detection" | tee -a "$LOG_FILE"
fi

# Step 5: Outpainting (placeholder for now)
echo "Outpainting step (placeholder - not implemented yet)" | tee -a "$LOG_FILE"

# Step 6: Run VDA depth estimation (unless --no-depth)
if [ "$NO_DEPTH" = false ]; then
    if [ ! -f "$DEPTH_VIDEO" ]; then
        echo "Running VDA depth estimation..." | tee -a "$LOG_FILE"
        
        VDA_ENV_PREFIX="${SCRIPT_DIR}/Video-Depth-Anything/.mamba-env"
        VDA_PYTHON_SCRIPT="${SCRIPT_DIR}/Video-Depth-Anything/run_vda_relative.py"
        
        if [ ! -d "$VDA_ENV_PREFIX" ]; then
            echo "Error: VDA environment not found at $VDA_ENV_PREFIX" >&2
            exit 1
        fi
        if [ ! -f "$VDA_PYTHON_SCRIPT" ]; then
            echo "Error: run_vda_relative.py not found at $VDA_PYTHON_SCRIPT" >&2
            exit 1
        fi
        
        # Activate VDA environment
        eval "$(micromamba shell hook -s bash)"
        micromamba activate "$VDA_ENV_PREFIX"
        
        export PYTHONNOUSERSITE=1
        export HF_HOME="${SCRIPT_DIR}/Video-Depth-Anything/.hf-cache"
        export TORCH_HOME="${SCRIPT_DIR}/Video-Depth-Anything/.torch-cache"
        mkdir -p "$HF_HOME" "$TORCH_HOME"
        
        # Run VDA - it will use metadata.json to get fps and scene_timestamps for scene-aware normalization
        # Pass reference FPS to ensure exact timing match
        VDA_ARGS=(
            --input "$REFERENCE_VIDEO"
            --output "$DEPTH_VIDEO"
            --encoder vitl
            --input_size 518
            --max_res "$MAX_RES"
            --metadata-json "$METADATA_FILE"
            --target-fps "$REFERENCE_FPS"
        )
        if [ "$SAVE_NPZ" = true ]; then
            VDA_ARGS+=(--save-npz)
        fi
        python "$VDA_PYTHON_SCRIPT" "${VDA_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"
        
        # Re-encode depth video to match rgb.mp4 exactly (same fps, duration, frame count)
        echo "Re-encoding depth video to match rgb.mp4 timing exactly..." | tee -a "$LOG_FILE"
        TEMP_DEPTH="${DEPTH_VIDEO}.tmp"
        mv "$DEPTH_VIDEO" "$TEMP_DEPTH"
        
        # Re-encode with exact rgb.mp4 FPS and ensure frame count matches
        FFMPEG_CMD=(ffmpeg -i "$TEMP_DEPTH" -vf "fps=fps=${REFERENCE_FPS}" -c:v libx264 -pix_fmt yuv420p -crf 18)
        if [ -n "$REFERENCE_DURATION" ]; then
            FFMPEG_CMD+=(-t "$REFERENCE_DURATION")
        fi
        FFMPEG_CMD+=(-y "$DEPTH_VIDEO")
        if ! "${FFMPEG_CMD[@]}" >/dev/null 2>&1; then
            echo "Error: Failed to re-encode depth video" >&2
            mv "$TEMP_DEPTH" "$DEPTH_VIDEO"
            exit 1
        fi
        rm -f "$TEMP_DEPTH"
        echo "Depth video re-encoded to match rgb.mp4 timing" | tee -a "$LOG_FILE"
        
        echo "Depth video created: $DEPTH_VIDEO" | tee -a "$LOG_FILE"
        
        # Extract scene depth stats from VDA output if available
        SCENE_DEPTH_STATS_FILE="${ROOT_DIR}/.scene_depth_stats.json"
        if [ -f "$SCENE_DEPTH_STATS_FILE" ]; then
            echo "Found scene depth statistics: $SCENE_DEPTH_STATS_FILE" | tee -a "$LOG_FILE"
        else
            SCENE_DEPTH_STATS_FILE=""
        fi
        
        # Update metadata with depth dimensions and scene information
        update_metadata_with_scenes "$METADATA_FILE" "$INPUT_VIDEO" "$FRAMES_DIR" "$SCENE_DEPTH_STATS_FILE"
        echo "Metadata updated with depth dimensions and scene information" | tee -a "$LOG_FILE"
        
        # Clean up temporary scene depth stats file
        if [ -f "$SCENE_DEPTH_STATS_FILE" ]; then
            rm -f "$SCENE_DEPTH_STATS_FILE"
            echo "Cleaned up temporary scene depth stats file" | tee -a "$LOG_FILE"
        fi
    else
        echo "depth.mp4 already exists, skipping VDA" | tee -a "$LOG_FILE"
        # Update metadata with depth dimensions and scene information if not already present
        SCENE_DEPTH_STATS_FILE="${ROOT_DIR}/.scene_depth_stats.json"
        if ! python3 -c "import json; data = json.load(open('$METADATA_FILE')); exit(0 if 'depth_width' in data and 'scene_timestamps' in data else 1)" 2>/dev/null; then
            update_metadata_with_scenes "$METADATA_FILE" "$REFERENCE_VIDEO" "$FRAMES_DIR" "$SCENE_DEPTH_STATS_FILE"
            echo "Metadata updated with depth dimensions and scene information" | tee -a "$LOG_FILE"
            
            # Clean up temporary scene depth stats file
            if [ -f "$SCENE_DEPTH_STATS_FILE" ]; then
                rm -f "$SCENE_DEPTH_STATS_FILE"
                echo "Cleaned up temporary scene depth stats file" | tee -a "$LOG_FILE"
            fi
        fi
    fi
else
    echo "Skipping depth estimation (--no-depth specified)" | tee -a "$LOG_FILE"
fi

# Step 6: Export (create export.zip unless --no-export)
if [ "$NO_EXPORT" = false ]; then
    EXPORT_ZIP="${ROOT_DIR}/export.zip"
    
    if [ ! -f "$EXPORT_ZIP" ]; then
        echo "Creating export.zip..." | tee -a "$LOG_FILE"
        
        # Check required files exist
        if [ ! -f "$METADATA_FILE" ]; then
            echo "Error: Metadata file not found: $METADATA_FILE" >&2
            exit 1
        fi
        
        if [ ! -f "$REFERENCE_VIDEO" ]; then
            echo "Error: rgb.mp4 not found: $REFERENCE_VIDEO" >&2
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
rgb_video = "$REFERENCE_VIDEO"
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

