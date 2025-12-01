#!/bin/bash
# Wrapper to run PAGE-4D evaluation on a directory of frames.
# Usage: ./run_page4d.sh <input_dir> [output_dir]

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <input_dir> [output_dir]" >&2
  exit 1
fi

INPUT_DIR="$1"
shift || true
if [ $# -gt 0 ]; then
  OUTPUT_DIR="$1"
  shift
else
  OUTPUT_DIR=""
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAGE4D_DIR="${SCRIPT_DIR}/Page4D/page-4d"
ENV_PREFIX="${SCRIPT_DIR}/vggt/.mamba-env"
PYTHON_SCRIPT="${PAGE4D_DIR}/run_page4d_dir.py"

if [ ! -d "$ENV_PREFIX" ]; then
  echo "Error: VGGT micromamba env not found at $ENV_PREFIX" >&2
  exit 1
fi
if [ ! -f "$PYTHON_SCRIPT" ]; then
  echo "Error: run_page4d_dir.py not found at $PYTHON_SCRIPT" >&2
  exit 1
fi

if [[ "$INPUT_DIR" != /* ]]; then
  INPUT_DIR="${SCRIPT_DIR}/${INPUT_DIR}"
fi
if [ -z "$OUTPUT_DIR" ]; then
  OUTPUT_DIR="${SCRIPT_DIR}/page4dpoutput"
fi
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="${SCRIPT_DIR}/${OUTPUT_DIR}"
fi

if [ ! -d "$INPUT_DIR" ]; then
  echo "Error: input directory not found: $INPUT_DIR" >&2
  exit 1
fi

# Activate VGGT env
eval "$(micromamba shell hook -s bash)"
micromamba activate "$ENV_PREFIX"

export PYTHONNOUSERSITE=1
export HF_HOME="${SCRIPT_DIR}/vggt/.hf-cache"
mkdir -p "$HF_HOME"

python "$PYTHON_SCRIPT" --input-dir "$INPUT_DIR" --output-dir "$OUTPUT_DIR"
