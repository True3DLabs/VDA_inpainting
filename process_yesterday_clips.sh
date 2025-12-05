#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_VIDEO="$SCRIPT_DIR/videos/yesterday_full.mp4"
CLIPS_DIR="$SCRIPT_DIR/videos/yesterday_clips"
CLIP_DURATION=300  # 5 minutes in seconds

# Check if source video exists
if [ ! -f "$SOURCE_VIDEO" ]; then
    echo "Error: Source video not found: $SOURCE_VIDEO" >&2
    exit 1
fi

mkdir -p "$CLIPS_DIR"

# Get video duration
TOTAL_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$SOURCE_VIDEO")
TOTAL_DURATION=${TOTAL_DURATION%.*}  # Round down to integer

echo "Total video duration: ${TOTAL_DURATION}s"
echo "Clip duration: ${CLIP_DURATION}s"

# Calculate number of clips
NUM_CLIPS=$(( (TOTAL_DURATION + CLIP_DURATION - 1) / CLIP_DURATION ))
echo "Will create $NUM_CLIPS clips"

# Create clips and process them
for ((i=0; i<NUM_CLIPS; i++)); do
    START_TIME=$((i * CLIP_DURATION))
    CLIP_NAME="yesterday_full_clip_$(printf "%02d" $i)"
    CLIP_PATH="$CLIPS_DIR/${CLIP_NAME}.mp4"
    
    # Skip first two clips (already processed)
    if [ $i -eq 0 ] || [ $i -eq 1 ]; then
        echo ""
        echo "=== Skipping clip $i (already processed) ==="
        continue
    fi
    
    echo ""
    echo "=== Processing clip $i: $CLIP_NAME ==="
    echo "Start time: ${START_TIME}s"
    
    # Create clip if it doesn't exist
    if [ ! -f "$CLIP_PATH" ]; then
        echo "Creating clip: $CLIP_PATH"
        ffmpeg -ss "$START_TIME" -i "$SOURCE_VIDEO" -t "$CLIP_DURATION" \
            -c copy -avoid_negative_ts make_zero \
            "$CLIP_PATH" -y
        echo "Clip created: $CLIP_PATH"
    else
        echo "Clip already exists: $CLIP_PATH"
    fi
    
    # Run main.sh on the clip
    echo "Running: ./main.sh $CLIP_PATH --npz"
    "$SCRIPT_DIR/main.sh" "$CLIP_PATH" --npz
    
    echo "Clip $i processing complete!"
done

echo ""
echo "=== All clips processed! ==="
