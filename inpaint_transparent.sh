#!/bin/bash
# SDXL Inpainting CLI wrapper script
# Usage: ./inpaint_transparent.sh <input_image> [output_image] [options...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDXL_ENV="${SCRIPT_DIR}/SDXL-Inpaint/.mamba-env"
PYTHON_SCRIPT="${SCRIPT_DIR}/SDXL-Inpaint/inpaint_transparent.py"

if [ ! -d "$SDXL_ENV" ]; then
    echo "Error: SDXL environment not found at $SDXL_ENV" >&2
    exit 1
fi

if [ $# -lt 1 ]; then
    echo "Usage: $0 <input_image> [output_image] [--prompt PROMPT] [--steps N] [--guidance G] [--seed N] [--alpha_threshold T] [--dilate D] [--feather F] [--save_mask]" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 processing/frames/frame_0.png" >&2
    echo "  $0 input.png output.png --prompt 'fill missing regions realistically, seamless continuation' --steps 30" >&2
    echo "  $0 input.png --alpha_threshold 200 --save_mask" >&2
    exit 1
fi

INPUT_IMAGE="$1"
shift

if [ ! -f "$INPUT_IMAGE" ]; then
    echo "Error: Input image not found: $INPUT_IMAGE" >&2
    exit 1
fi

# Initialize micromamba and activate environment
eval "$(micromamba shell hook -s bash)"
micromamba activate "$SDXL_ENV"

# Set isolated Hugging Face cache
export PYTHONNOUSERSITE=1
export HF_HOME="${SCRIPT_DIR}/SDXL-Inpaint/.hf-cache"
export HUGGINGFACE_HUB_CACHE="$HF_HOME/hub"
export TRANSFORMERS_CACHE="$HF_HOME/transformers"
export DIFFUSERS_CACHE="$HF_HOME/diffusers"

# Run the Python script with all remaining arguments
# python "$PYTHON_SCRIPT" --input "$INPUT_IMAGE" "$@"
python ~/VDA_inpainting/SDXL-Inpaint/inpaint_transparent.py --input "$INPUT_IMAGE" --steps 30 --guidance 3.5 --seed 10 --dilate 1 --feather 2 --prompt "fill all missing and black regions realistically, seamless continuation. Leave the original scene as it is. Fill the entire image."

