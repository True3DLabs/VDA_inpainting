#!/bin/bash
# Create export.zip containing depth.mp4, rgb.mp4, and metadata.json
# Usage: ./export.sh <output_directory>
# Example: ./export.sh outputs/dev_cinema-1764008853

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <output_directory>" >&2
  echo "Example: $0 outputs/dev_cinema-1764008853" >&2
  exit 1
fi

OUTPUT_DIR="$1"

if [ ! -d "$OUTPUT_DIR" ]; then
  echo "Error: Directory not found: $OUTPUT_DIR" >&2
  exit 1
fi

# Convert to absolute path
if [[ "$OUTPUT_DIR" != /* ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  OUTPUT_DIR="${SCRIPT_DIR}/${OUTPUT_DIR}"
fi

FRAMES_DIR="${OUTPUT_DIR}/frames"
DEPTH_VIDEO="${OUTPUT_DIR}/depth.mp4"
RGB_VIDEO="${OUTPUT_DIR}/rgb.mp4"
METADATA_FILE="${OUTPUT_DIR}/metadata.json"
EXPORT_ZIP="${OUTPUT_DIR}/export.zip"

# Check required files/directories exist
if [ ! -f "$METADATA_FILE" ]; then
  echo "Error: Metadata file not found: $METADATA_FILE" >&2
  exit 1
fi

if [ ! -d "$FRAMES_DIR" ]; then
  echo "Error: Frames directory not found: $FRAMES_DIR" >&2
  exit 1
fi

if [ ! -f "$DEPTH_VIDEO" ]; then
  echo "Error: Depth video not found: $DEPTH_VIDEO" >&2
  exit 1
fi

# Extract fps from metadata.json (try 'fps' first, fallback to 'extraction_fps' for compatibility)
FPS=$(python3 -c "import json; data = json.load(open('$METADATA_FILE')); print(data.get('fps') or data.get('extraction_fps', 24))" 2>/dev/null || echo "24")

if [ -z "$FPS" ] || [ "$FPS" = "0" ]; then
  echo "Warning: Could not extract fps from metadata, using default 24" >&2
  FPS=24
fi

echo "Using fps: $FPS"

# Count frames
FRAME_COUNT=$(ls -1 "${FRAMES_DIR}"/frame_*.png 2>/dev/null | wc -l)
if [ "$FRAME_COUNT" -eq 0 ]; then
  echo "Error: No frames found in $FRAMES_DIR" >&2
  exit 1
fi

echo "Found $FRAME_COUNT frames"

# Create RGB video from frames
echo "Creating RGB video from frames..."
if ! ffmpeg -y -framerate "$FPS" -i "${FRAMES_DIR}/frame_%06d.png" \
  -c:v libx264 -pix_fmt yuv420p -crf 18 \
  "$RGB_VIDEO" >/dev/null 2>&1; then
  echo "Error: Failed to create RGB video" >&2
  exit 1
fi

echo "RGB video created: $RGB_VIDEO"

# Create export.zip using Python
echo "Creating export.zip..."
python3 <<EOF
import zipfile
import os

output_dir = "$OUTPUT_DIR"
export_zip = "$EXPORT_ZIP"
depth_video = "$DEPTH_VIDEO"
rgb_video = "$RGB_VIDEO"
metadata_file = "$METADATA_FILE"

with zipfile.ZipFile(export_zip, 'w', zipfile.ZIP_DEFLATED) as zipf:
    zipf.write(depth_video, os.path.basename(depth_video))
    zipf.write(rgb_video, os.path.basename(rgb_video))
    zipf.write(metadata_file, os.path.basename(metadata_file))

print(f"Export complete: {export_zip}")
print("Contents:")
with zipfile.ZipFile(export_zip, 'r') as zipf:
    for info in zipf.infolist():
        print(f"  {info.filename} ({info.file_size} bytes)")
EOF

