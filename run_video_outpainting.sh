#!/bin/bash
# Video Outpainting Script
# Usage: ./run_video_outpainting.sh <input_video>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_PREFIX="${SCRIPT_DIR}/FLUX-Fill/.mamba-env"
PYTHON_SCRIPT="${SCRIPT_DIR}/video_outpainting.py"
MAX_FPS=24
MAX_WIDTH=1280
MAX_HEIGHT=720

# Function to extract video frames and metadata
extract_video_frames() {
    local video_file="$1"
    local frames_dir="$2"
    local metadata_file="$3"
    
    # Check if ffmpeg and ffprobe are available
    if ! command -v ffprobe &> /dev/null; then
        echo "Error: ffprobe not found. Please install ffmpeg." >&2
        exit 1
    fi
    if ! command -v ffmpeg &> /dev/null; then
        echo "Error: ffmpeg not found. Please install ffmpeg." >&2
        exit 1
    fi
    
    # Get video metadata using ffprobe
    local original_fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$video_file" | awk -F'/' '{if ($2+0 == 0) print 0; else print ($1+0)/($2+0)}')
    # Calculate actual FPS used (min of original and MAX_FPS)
    local actual_fps=$(echo "$original_fps $MAX_FPS" | awk '{if ($1 < $2) print $1; else print $2}')
    local fps=$original_fps
    local duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local original_width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local original_height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local bitrate=$(ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local num_frames=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_frames -of default=noprint_wrappers=1:nokey=1 "$video_file" 2>/dev/null || echo "")
    
    # Calculate actual resolution used (scale down if exceeds max dimensions, maintaining aspect ratio)
    local actual_width=$original_width
    local actual_height=$original_height
    if [ "$original_width" -gt "$MAX_WIDTH" ] || [ "$original_height" -gt "$MAX_HEIGHT" ]; then
        # Calculate scale factor to fit within max dimensions using awk
        local scale=$(echo "$original_width $original_height $MAX_WIDTH $MAX_HEIGHT" | awk '{
            scale_w = $3 / $1
            scale_h = $4 / $2
            if (scale_w < scale_h) print scale_w
            else print scale_h
        }')
        actual_width=$(echo "$original_width $scale" | awk '{printf "%.0f", $1 * $2}')
        actual_height=$(echo "$original_height $scale" | awk '{printf "%.0f", $1 * $2}')
        # Ensure dimensions are even (required by some codecs)
        actual_width=$((actual_width - (actual_width % 2)))
        actual_height=$((actual_height - (actual_height % 2)))
    fi
    
    # Create frames directory
    mkdir -p "$frames_dir"
    
    # Extract frames using ffmpeg with MAX_FPS and resolution limits
    # Scale frames if they exceed max dimensions, maintaining aspect ratio
    local vf_filter="fps=fps=${MAX_FPS}"
    if [ "$actual_width" -ne "$original_width" ] || [ "$actual_height" -ne "$original_height" ]; then
        vf_filter="${vf_filter},scale=${actual_width}:${actual_height}"
    fi
    if ! ffmpeg -i "$video_file" -vf "$vf_filter" -y "${frames_dir}/frame_%06d.png" >/dev/null 2>&1; then
        echo "Error: Failed to extract frames from video" >&2
        exit 1
    fi
    
    # Count actual extracted frames
    local actual_frames=$(ls -1 "${frames_dir}"/frame_*.png 2>/dev/null | wc -l)
    
    # Create metadata JSON file (one line per dict item)
    {
        echo "{"
        echo "\"original_fps\": $fps,"
        echo "\"fps\": $actual_fps,"
        echo "\"duration\": $duration,"
        echo "\"width\": $original_width,"
        echo "\"height\": $original_height,"
        echo "\"extraction_width\": $actual_width,"
        echo "\"extraction_height\": $actual_height,"
        echo "\"codec\": \"$codec\","
        echo "\"bitrate\": $bitrate,"
        if [ -n "$num_frames" ]; then
            echo "\"num_frames\": $num_frames,"
        fi
        echo "\"extracted_frames\": $actual_frames,"
        echo "\"frames_dir\": \"$frames_dir\","
        echo "\"video_file\": \"$video_file\""
        echo "}"
    } > "$metadata_file"
    
    echo "$actual_frames"
}

if [ ! -d "$ENV_PREFIX" ]; then
  echo "Error: Flux Fill environment not found at $ENV_PREFIX" >&2
  exit 1
fi

if [ ! -f "$PYTHON_SCRIPT" ]; then
  echo "Error: Video outpainting script not found at $PYTHON_SCRIPT" >&2
  exit 1
fi

if [ $# -lt 1 ]; then
  cat >&2 <<USAGE
Usage: $0 <input_video>

Extracts frames from video, creates expanded initial frame with outpainting masks,
and fills only the first frame. All parameters are hardcoded (expansion percent,
max dimensions, prompt, etc).

Example:
  $0 input_video.mp4
USAGE
  exit 1
fi

INPUT_VIDEO="$1"

if [ ! -f "$INPUT_VIDEO" ]; then
  echo "Error: input video not found: $INPUT_VIDEO" >&2
  exit 1
fi

# Convert to absolute path
if [[ "$INPUT_VIDEO" != /* ]]; then
  INPUT_VIDEO="${SCRIPT_DIR}/${INPUT_VIDEO}"
fi

# Create root_dir per video: outputs/{input_filename}-{timestamp}/
INPUT_BASENAME=$(basename "$INPUT_VIDEO")
INPUT_NAME="${INPUT_BASENAME%.*}"
TIMESTAMP=$(date +%s)
ROOT_DIR="${SCRIPT_DIR}/outputs/${INPUT_NAME}-${TIMESTAMP}"
mkdir -p "$ROOT_DIR"

# Extract frames and create metadata
FRAMES_DIR="${ROOT_DIR}/frames"
METADATA_FILE="${ROOT_DIR}/${INPUT_NAME}_metadata.json"
LOG_FILE="${ROOT_DIR}/${INPUT_NAME}_log.txt"

echo "Extracting frames from video..." >&2
NUM_FRAMES=$(extract_video_frames "$INPUT_VIDEO" "$FRAMES_DIR" "$METADATA_FILE")
echo "Extracted $NUM_FRAMES frames to $FRAMES_DIR" >&2
echo "Metadata saved to $METADATA_FILE" >&2
echo "Log file will be saved to $LOG_FILE" >&2

# Activate micromamba env
eval "$(micromamba shell hook -s bash)"
micromamba activate "$ENV_PREFIX"

export PYTHONNOUSERSITE=1
export HF_HOME="${SCRIPT_DIR}/FLUX-Fill/.hf-cache"
export HUGGINGFACE_HUB_CACHE="$HF_HOME/hub"
export TRANSFORMERS_CACHE="$HF_HOME/transformers"
export DIFFUSERS_CACHE="$HF_HOME/diffusers"
mkdir -p "$HUGGINGFACE_HUB_CACHE" "$TRANSFORMERS_CACHE" "$DIFFUSERS_CACHE"

# Run Python script and log all output (stdout and stderr) to log file
# Use tee to also display output on console
echo "Starting video outpainting processing..." | tee -a "$LOG_FILE"
python "$PYTHON_SCRIPT" "$INPUT_VIDEO" "$ROOT_DIR" 2>&1 | tee -a "$LOG_FILE"
