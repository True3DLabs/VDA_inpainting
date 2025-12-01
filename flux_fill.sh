#!/bin/bash
# Flux Fill CLI wrapper script
# Usage: ./flux_fill.sh <input_image> [output_image] [--prompt ...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_PREFIX="${SCRIPT_DIR}/FLUX-Fill/.mamba-env"
PYTHON_SCRIPT="${SCRIPT_DIR}/FLUX-Fill/flux_fill_transparent.py"

# Function to check if file is a video
is_video_file() {
    local file="$1"
    local ext="${file##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
        mp4|avi|mov|mkv|webm|flv|wmv|m4v|mpg|mpeg|3gp|ogv|ts|mts)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

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
    local fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$video_file" | awk -F'/' '{if ($2+0 == 0) print 0; else print ($1+0)/($2+0)}')
    local duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local bitrate=$(ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$video_file")
    local num_frames=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_frames -of default=noprint_wrappers=1:nokey=1 "$video_file" 2>/dev/null || echo "")
    
    # Create frames directory
    mkdir -p "$frames_dir"
    
    # Extract frames using ffmpeg
    if ! ffmpeg -i "$video_file" -y "${frames_dir}/frame_%06d.png" >/dev/null 2>&1; then
        echo "Error: Failed to extract frames from video" >&2
        exit 1
    fi
    
    # Count actual extracted frames
    local actual_frames=$(ls -1 "${frames_dir}"/frame_*.png 2>/dev/null | wc -l)
    
    # Create metadata JSON file (one line per dict item)
    {
        echo "{"
        echo "\"fps\": $fps,"
        echo "\"duration\": $duration,"
        echo "\"width\": $width,"
        echo "\"height\": $height,"
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
  echo "Error: Flux Fill script not found at $PYTHON_SCRIPT" >&2
  exit 1
fi

if [ $# -lt 1 ]; then
  cat >&2 <<USAGE
Usage: $0 <input_image_or_video> [output_image] [options]
Options mirror flux_fill_transparent.py:
  --prompt TEXT                 Positive prompt
  --steps N                     Number of inference steps
  --guidance FLOAT              Guidance scale
  --seed N                      Random seed
  --alpha-threshold N           Alpha threshold for mask generation
  --dilate N                    Mask dilation radius
  --feather N                   Mask feather radius
  --max-seq-length N            Flux max sequence length
  --height/--width N            Override resolution (optional)
Note: Masks are saved to masks/ directory by default
      Video files will have frames extracted to frames/ directory
Examples:
  $0 transparent.png
  $0 transparent.png outputs/filled.png --prompt "restore missing details"
  $0 transparent.png --alpha-threshold 200
  $0 video.mp4
USAGE
  exit 1
fi

INPUT_FILE="$1"
shift

if [ ! -f "$INPUT_FILE" ]; then
  echo "Error: input file not found: $INPUT_FILE" >&2
  exit 1
fi

# Convert to absolute path
if [[ "$INPUT_FILE" != /* ]]; then
  INPUT_FILE="${SCRIPT_DIR}/${INPUT_FILE}"
fi

# Create root_dir per input file: outputs/{input_filename}-{timestamp}/
INPUT_BASENAME=$(basename "$INPUT_FILE")
INPUT_NAME="${INPUT_BASENAME%.*}"
TIMESTAMP=$(date +%s)
ROOT_DIR="${SCRIPT_DIR}/outputs/${INPUT_NAME}-${TIMESTAMP}"
mkdir -p "$ROOT_DIR"

# Check if input is a video file
if is_video_file "$INPUT_FILE"; then
  FRAMES_DIR="${ROOT_DIR}/frames"
  METADATA_FILE="${ROOT_DIR}/${INPUT_NAME}_metadata.json"
  
  echo "Detected video file. Extracting frames..." >&2
  NUM_FRAMES=$(extract_video_frames "$INPUT_FILE" "$FRAMES_DIR" "$METADATA_FILE")
  echo "Extracted $NUM_FRAMES frames to $FRAMES_DIR" >&2
  echo "Metadata saved to $METADATA_FILE" >&2
  
  # Exit after extracting frames - video processing complete
  exit 0
fi

# If not a video, treat as image
INPUT_IMAGE="$INPUT_FILE"

OUTPUT_IMAGE=""
POSITIONAL_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --prompt|--max-seq-length|--steps|--guidance|--seed|--alpha-threshold|--dilate|--feather|--height|--width)
      if [ $# -lt 2 ]; then
        echo "Missing value for $1" >&2
        exit 1
      fi
      POSITIONAL_ARGS+=("$1" "$2")
      shift 2
      ;;
    --save-mask)
      # Allow --save-mask to be passed through (though it's now default)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
    --*)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
    *)
      if [ -z "$OUTPUT_IMAGE" ]; then
        OUTPUT_IMAGE="$1"
      else
        POSITIONAL_ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

# INPUT_IMAGE is already absolute at this point
# ROOT_DIR is already set above

# Set up output directories within root_dir
INFILLED_DIR="${ROOT_DIR}/infilled"
MASKS_DIR="${ROOT_DIR}/masks"
mkdir -p "$INFILLED_DIR" "$MASKS_DIR"

# Generate output image path in infilled/ directory
if [ -z "$OUTPUT_IMAGE" ]; then
  INPUT_BASENAME=$(basename "$INPUT_IMAGE")
  INPUT_NAME="${INPUT_BASENAME%.*}"
  INPUT_EXT="${INPUT_BASENAME##*.}"
  OUTPUT_IMAGE="${INFILLED_DIR}/${INPUT_NAME}_filled.${INPUT_EXT}"
else
  # Extract just the filename and place in infilled/ directory
  OUTPUT_BASENAME=$(basename "$OUTPUT_IMAGE")
  OUTPUT_IMAGE="${INFILLED_DIR}/${OUTPUT_BASENAME}"
fi

# Always save mask to masks/ directory
INPUT_BASENAME=$(basename "$INPUT_IMAGE")
INPUT_NAME="${INPUT_BASENAME%.*}"
MASK_OUTPUT="${MASKS_DIR}/${INPUT_NAME}_flux_mask.png"
POSITIONAL_ARGS+=("--save-mask" "--mask-output" "$MASK_OUTPUT")

# Activate micromamba env
eval "$(micromamba shell hook -s bash)"
micromamba activate "$ENV_PREFIX"

export PYTHONNOUSERSITE=1
export HF_HOME="${SCRIPT_DIR}/FLUX-Fill/.hf-cache"
export HUGGINGFACE_HUB_CACHE="$HF_HOME/hub"
export TRANSFORMERS_CACHE="$HF_HOME/transformers"
export DIFFUSERS_CACHE="$HF_HOME/diffusers"
mkdir -p "$HUGGINGFACE_HUB_CACHE" "$TRANSFORMERS_CACHE" "$DIFFUSERS_CACHE"

CMD=(python "$PYTHON_SCRIPT" --input "$INPUT_IMAGE")
if [ -n "$OUTPUT_IMAGE" ]; then
  CMD+=(--output "$OUTPUT_IMAGE")
fi
CMD+=("${POSITIONAL_ARGS[@]}")

"${CMD[@]}"
