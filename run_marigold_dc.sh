#!/bin/bash
# Marigold-DC CLI wrapper script
# Usage: ./run_marigold_dc.sh <input_image> [output_depth] [options...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARIGOLD_ENV="${SCRIPT_DIR}/Marigold-DC/.mamba-env"
PYTHON_SCRIPT="${SCRIPT_DIR}/Marigold-DC/marigold_dc.py"

if [ ! -d "$MARIGOLD_ENV" ]; then
    echo "Error: Marigold-DC environment not found at $MARIGOLD_ENV" >&2
    exit 1
fi

if [ $# -lt 1 ]; then
    echo "Usage: $0 <input_image> [output_depth] [--in-depth SPARSE_DEPTH] [--num_inference_steps N] [--ensemble_size N] [--processing_resolution N]" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 processing/frames/frame_0.png" >&2
    echo "  $0 input.png processing/depth/output.npy" >&2
    echo "  $0 input.png --num_inference_steps 30 --processing_resolution 768" >&2
    echo "  $0 input.png --in-depth custom_sparse.npy" >&2
    exit 1
fi

INPUT_IMAGE="$1"
shift

if [ ! -f "$INPUT_IMAGE" ]; then
    echo "Error: Input image not found: $INPUT_IMAGE" >&2
    exit 1
fi

# Determine output path
OUTPUT_DEPTH=""
REMAINING_ARGS=()

# Parse arguments to find output path and other options
while [ $# -gt 0 ]; do
    case "$1" in
        --in-depth|--num_inference_steps|--ensemble_size|--processing_resolution|--checkpoint)
            REMAINING_ARGS+=("$1" "$2")
            shift 2
            ;;
        --use_full_precision|--use_tiny_vae)
            REMAINING_ARGS+=("$1")
            shift
            ;;
        --*)
            REMAINING_ARGS+=("$1")
            shift
            ;;
        *)
            # First non-flag argument after input is likely the output path
            if [ -z "$OUTPUT_DEPTH" ]; then
                OUTPUT_DEPTH="$1"
            else
                REMAINING_ARGS+=("$1")
            fi
            shift
            ;;
    esac
done

# Generate output path if not provided
if [ -z "$OUTPUT_DEPTH" ]; then
    BASE_NAME=$(basename "$INPUT_IMAGE" | sed 's/\.[^.]*$//')
    OUTPUT_DIR="${SCRIPT_DIR}/processing/depth"
    mkdir -p "$OUTPUT_DIR"
    OUTPUT_DEPTH="${OUTPUT_DIR}/${BASE_NAME}_depth.npy"
fi

# Create output directory if needed
OUTPUT_DIR=$(dirname "$OUTPUT_DEPTH")
if [ "$OUTPUT_DIR" != "." ] && [ "$OUTPUT_DIR" != "" ]; then
    mkdir -p "$OUTPUT_DIR"
fi

# Check if sparse depth is provided, if not create minimal one
HAS_SPARSE_DEPTH=false
for i in "${!REMAINING_ARGS[@]}"; do
    if [ "${REMAINING_ARGS[$i]}" == "--in-depth" ]; then
        HAS_SPARSE_DEPTH=true
        break
    fi
done

if [ "$HAS_SPARSE_DEPTH" = false ]; then
    # Create minimal sparse depth matching image dimensions
    TEMP_SPARSE="/tmp/marigold_sparse_$$.npy"
    python3 - << PY
from PIL import Image
import numpy as np
import sys
try:
    img = Image.open("$INPUT_IMAGE")
    h, w = img.size[1], img.size[0]
    sparse_depth = np.zeros((h, w), dtype=np.float32)
    # Add minimal guidance points (corners and center)
    sparse_depth[0, 0] = 1.0
    sparse_depth[0, w-1] = 1.0
    sparse_depth[h-1, 0] = 1.0
    sparse_depth[h-1, w-1] = 1.0
    sparse_depth[h//2, w//2] = 1.0
    np.save("$TEMP_SPARSE", sparse_depth)
    print("Created minimal sparse depth", file=sys.stderr)
except Exception as e:
    print(f"Error creating sparse depth: {e}", file=sys.stderr)
    sys.exit(1)
PY
    REMAINING_ARGS+=("--in-depth" "$TEMP_SPARSE")
fi

# Initialize micromamba and activate environment
eval "$(micromamba shell hook -s bash)"
micromamba activate "$MARIGOLD_ENV"

# Set isolated Hugging Face cache
export PYTHONNOUSERSITE=1
export HF_HOME="${SCRIPT_DIR}/Marigold-DC/.hf-cache"
export HUGGINGFACE_HUB_CACHE="$HF_HOME/hub"
export TRANSFORMERS_CACHE="$HF_HOME/transformers"
export DIFFUSERS_CACHE="$HF_HOME/diffusers"

# Run Marigold-DC (change to Marigold-DC directory to run as module)
# Convert paths to absolute if relative
if [[ "$INPUT_IMAGE" != /* ]]; then
    INPUT_IMAGE="${SCRIPT_DIR}/${INPUT_IMAGE}"
fi
if [[ "$OUTPUT_DEPTH" != /* ]]; then
    OUTPUT_DEPTH="${SCRIPT_DIR}/${OUTPUT_DEPTH}"
fi

cd "${SCRIPT_DIR}/Marigold-DC"
python -m marigold_dc \
    --in-image "$INPUT_IMAGE" \
    --out-depth "$OUTPUT_DEPTH" \
    "${REMAINING_ARGS[@]}" || EXIT_CODE=$?
cd - > /dev/null

# Clean up temporary sparse depth if created
if [ "$HAS_SPARSE_DEPTH" = false ] && [ -f "$TEMP_SPARSE" ]; then
    rm -f "$TEMP_SPARSE"
fi

# Exit with the same code as the Python script
exit ${EXIT_CODE:-0}

