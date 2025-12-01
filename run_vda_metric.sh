#!/bin/bash
# Run Video-Depth-Anything metric depth on a directory of frames.
# Usage: ./run_vda_metric.sh <input_dir> [output_dir] [options]
# Options:
#   --encoder {vits,vitb,vitl}    (default: vitl)
#   --input-size N                (default: 518)
#   --max-res N                   (default: 1280)
#   --target-fps FPS              (default: 24)
#   --fp32                        (use float32 inference)
#   --grayscale                   (grayscale depth visualization)
#   --save-npz                    (save stacked depth npz)
#   --save-exr                    (save per-frame EXR)
#   --help                        (show usage)

set -euo pipefail

usage() {
  cat >&2 <<USAGE
Usage: $0 <input_dir> [output_dir] [options]
Options:
  --encoder {vits,vitb,vitl}    Choose model size (default vitl)
  --input-size N                Input resolution for inference (default 518)
  --max-res N                   Max resize of input frames (default 1280)
  --target-fps FPS              FPS for visualization outputs (default 24)
  --fp32                        Use float32 inference (default bfloat16/float16)
  --grayscale                   Save grayscale depth visualization PNG/video
  --save-npz                    Save stacked depth NPZ file
  --save-exr                    Save EXR depth maps per frame
  --help                        Show this help message
USAGE
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

INPUT_DIR="$1"
shift
OUTPUT_DIR=""
if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
  OUTPUT_DIR="$1"
  shift
fi

ENCODER="vitl"
INPUT_SIZE=518
MAX_RES=1280
TARGET_FPS=24
FP32=false
GRAYSCALE=false
SAVE_NPZ=false
SAVE_EXR=false

while [ $# -gt 0 ]; do
  case "$1" in
    --encoder)
      ENCODER="$2"; shift 2 ;;
    --input-size)
      INPUT_SIZE="$2"; shift 2 ;;
    --max-res)
      MAX_RES="$2"; shift 2 ;;
    --target-fps)
      TARGET_FPS="$2"; shift 2 ;;
    --fp32)
      FP32=true; shift ;;
    --grayscale)
      GRAYSCALE=true; shift ;;
    --save-npz)
      SAVE_NPZ=true; shift ;;
    --save-exr)
      SAVE_EXR=true; shift ;;
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
PYTHON_SCRIPT="${SCRIPT_DIR}/Video-Depth-Anything/run_frames.py"

if [ ! -d "$ENV_PREFIX" ]; then
  echo "Error: environment not found at $ENV_PREFIX" >&2
  exit 1
fi
if [ ! -f "$PYTHON_SCRIPT" ]; then
  echo "Error: run_frames.py not found at $PYTHON_SCRIPT" >&2
  exit 1
fi

if [[ "$INPUT_DIR" != /* ]]; then
  INPUT_DIR="${SCRIPT_DIR}/${INPUT_DIR}"
fi
if [ -z "$OUTPUT_DIR" ]; then
  base_name="$(basename "$INPUT_DIR")"
  OUTPUT_DIR="${SCRIPT_DIR}/processing/vda_metric/${base_name}"
fi
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="${SCRIPT_DIR}/${OUTPUT_DIR}"
fi

if [ ! -d "$INPUT_DIR" ]; then
  echo "Error: input directory not found: $INPUT_DIR" >&2
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
  --input_dir "$INPUT_DIR" \
  --output_dir "$OUTPUT_DIR" \
  --encoder "$ENCODER" \
  --metric \
  --input_size "$INPUT_SIZE" \
  --max_res "$MAX_RES" \
  --target_fps "$TARGET_FPS")

if [ "$FP32" = true ]; then
  CMD+=(--fp32)
fi
if [ "$GRAYSCALE" = true ]; then
  CMD+=(--grayscale)
fi
if [ "$SAVE_NPZ" = true ]; then
  CMD+=(--save_npz)
fi
if [ "$SAVE_EXR" = true ]; then
  CMD+=(--save_exr)
fi

"${CMD[@]}"
