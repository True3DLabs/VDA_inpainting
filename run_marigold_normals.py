#!/usr/bin/env python3
"""
Script to generate normal maps using Marigold Normals Pipeline
"""
import sys
import os
import torch
from pathlib import Path

# Add VideoPainter diffusers to path
script_dir = Path(__file__).parent
diffusers_path = script_dir / "VideoPainter" / "diffusers" / "src"
sys.path.insert(0, str(diffusers_path))

try:
    import diffusers
    from diffusers.utils import load_image
except ImportError as e:
    print(f"Error importing diffusers: {e}", file=sys.stderr)
    print("Make sure you're in the correct environment and diffusers is installed.", file=sys.stderr)
    sys.exit(1)

def main():
    if len(sys.argv) < 2:
        print("Usage: python run_marigold_normals.py <input_image> [output_path]", file=sys.stderr)
        sys.exit(1)
    
    input_image_path = sys.argv[1]
    output_path = sys.argv[2] if len(sys.argv) > 2 else None
    
    if not os.path.exists(input_image_path):
        print(f"Error: Input image not found: {input_image_path}", file=sys.stderr)
        sys.exit(1)
    
    # Generate output path if not provided
    if output_path is None:
        input_path = Path(input_image_path)
        output_path = str(input_path.parent / f"{input_path.stem}_normals.png")
    
    print(f"Loading image: {input_image_path}")
    print(f"Output will be saved to: {output_path}")
    
    # Check for CUDA
    device = "cuda" if torch.cuda.is_available() else "cpu"
    dtype = torch.float16 if device == "cuda" else torch.float32
    print(f"Using device: {device}, dtype: {dtype}")
    
    try:
        print("Loading Marigold Normals Pipeline...")
        pipe = diffusers.MarigoldNormalsPipeline.from_pretrained(
            "prs-eth/marigold-normals-lcm-v0-1",
            variant="fp16" if device == "cuda" else None,
            torch_dtype=dtype
        ).to(device)
        
        print("Loading input image...")
        image = load_image(input_image_path)
        
        print("Generating normal map (this may take a while)...")
        normals = pipe(image)
        
        print("Visualizing normals...")
        vis = pipe.image_processor.visualize_normals(normals.prediction)
        
        print(f"Saving to {output_path}...")
        vis[0].save(output_path)
        
        print(f"Success! Normal map saved to: {output_path}")
        
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    main()

