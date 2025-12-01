#!/usr/bin/env python3
"""
Script to blend two images with specified weights
"""
import sys
from PIL import Image
import numpy as np
from pathlib import Path

def blend_images(img1_path, img2_path, output_path, weight1=0.5, weight2=0.5):
    """
    Blend two images with specified weights.
    
    Args:
        img1_path: Path to first image
        img2_path: Path to second image
        output_path: Path to save blended image
        weight1: Weight for first image (default 0.5)
        weight2: Weight for second image (default 0.5)
    """
    # Load images
    img1 = Image.open(img1_path).convert('RGB')
    img2 = Image.open(img2_path).convert('RGB')
    
    # Ensure same size
    if img1.size != img2.size:
        print(f"Warning: Images have different sizes. Resizing {img2_path} to match {img1_path}")
        img2 = img2.resize(img1.size, Image.Resampling.LANCZOS)
    
    # Convert to numpy arrays
    arr1 = np.array(img1, dtype=np.float32)
    arr2 = np.array(img2, dtype=np.float32)
    
    # Blend
    blended = weight1 * arr1 + weight2 * arr2
    
    # Clip to valid range and convert back to uint8
    blended = np.clip(blended, 0, 255).astype(np.uint8)
    
    # Create PIL Image and save
    result = Image.fromarray(blended)
    result.save(output_path)
    
    print(f"Blended image saved to: {output_path}")
    print(f"  Weight 1 ({img1_path}): {weight1}")
    print(f"  Weight 2 ({img2_path}): {weight2}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python blend_images.py <image1> <image2> [output_path] [weight1] [weight2]", file=sys.stderr)
        sys.exit(1)
    
    img1_path = sys.argv[1]
    img2_path = sys.argv[2]
    
    if len(sys.argv) > 3:
        output_path = sys.argv[3]
    else:
        # Generate output path from first image
        img1 = Path(img1_path)
        output_path = str(img1.parent / f"{img1.stem}_blended.png")
    
    weight1 = float(sys.argv[4]) if len(sys.argv) > 4 else 0.5
    weight2 = float(sys.argv[5]) if len(sys.argv) > 5 else 0.5
    
    blend_images(img1_path, img2_path, output_path, weight1, weight2)

