#!/bin/bash
# Run Video-Depth-Anything relative depth on a video file or directory of frames.
# Usage: ./run_vda.sh <input_video_or_dir> [output_video] [options]
# Options:
#   --encoder {vits,vitb,vitl}    (default: vitl)
#   --input-size N                (default: 518)
#   --max-res N                   (default: 1280)
#   --fp32                        (use float32 inference)
#   --help                        (show usage)

set -euo pipefail

usage() {
  cat >&2 <<USAGE
Usage: $0 <input_video_or_dir> [output_video] [options]
Options:
  --encoder {vits,vitb,vitl}    Choose model size (default vitl)
  --input-size N                Input resolution for inference (default 518)
  --max-res N                   Max resolution (max of width/height) for processing and output (default 1280)
  --fp32                        Use float32 inference (default bfloat16/float16)
  --help                        Show this help message

Output:
  Creates a grayscale depth video scaled so max(width, height) <= max_res (maintains aspect ratio).
  For 16:9 videos with max_res=1280, output will be 1280x720.
  FPS is detected from metadata.json, video metadata, or defaults to 24.
USAGE
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

INPUT="$1"
shift
OUTPUT=""
if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
  OUTPUT="$1"
  shift
fi

ENCODER="vitl"
INPUT_SIZE=518
MAX_RES=1280
FP32=false

while [ $# -gt 0 ]; do
  case "$1" in
    --encoder)
      ENCODER="$2"; shift 2 ;;
    --input-size)
      INPUT_SIZE="$2"; shift 2 ;;
    --max-res)
      MAX_RES="$2"; shift 2 ;;
    --fp32)
      FP32=true; shift ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_PREFIX="${SCRIPT_DIR}/Video-Depth-Anything/.mamba-env"
PYTHON_SCRIPT="${SCRIPT_DIR}/Video-Depth-Anything/run_vda_relative.py"

if [ ! -d "$ENV_PREFIX" ]; then
  echo "Error: environment not found at $ENV_PREFIX" >&2
  exit 1
fi
if [ ! -f "$PYTHON_SCRIPT" ]; then
  echo "Error: run_vda_relative.py not found at $PYTHON_SCRIPT" >&2
  exit 1
fi

if [[ "$INPUT" != /* ]]; then
  INPUT="${SCRIPT_DIR}/${INPUT}"
fi

if [ -z "$OUTPUT" ]; then
  if [ -f "$INPUT" ]; then
    base_name="$(basename "$INPUT" | sed 's/\.[^.]*$//')"
  else
    base_name="$(basename "$INPUT")"
  fi
  OUTPUT="${SCRIPT_DIR}/processing/vda/${base_name}_depth.mp4"
fi
if [[ "$OUTPUT" != /* ]]; then
  OUTPUT="${SCRIPT_DIR}/${OUTPUT}"
fi

if [ ! -e "$INPUT" ]; then
  echo "Error: input not found: $INPUT" >&2
  exit 1
fi

# Activate environment
eval "$(micromamba shell hook -s bash)"
micromamba activate "$ENV_PREFIX"

export PYTHONNOUSERSITE=1
export HF_HOME="${SCRIPT_DIR}/Video-Depth-Anything/.hf-cache"
export TORCH_HOME="${SCRIPT_DIR}/Video-Depth-Anything/.torch-cache"
mkdir -p "$HF_HOME" "$TORCH_HOME"

CMD=(python "$PYTHON_SCRIPT" \
  --input "$INPUT" \
  --output "$OUTPUT" \
  --encoder "$ENCODER" \
  --input_size "$INPUT_SIZE" \
  --max_res "$MAX_RES")

if [ "$FP32" = true ]; then
  CMD+=(--fp32)
fi

"${CMD[@]}"

