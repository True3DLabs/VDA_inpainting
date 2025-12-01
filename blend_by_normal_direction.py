#!/usr/bin/env python3
"""
Script to blend images based on normal map direction:
- Use original image RGB where normals face camera (high Z)
- Use normal map RGB where normals are perpendicular to camera (low Z)
"""
import sys
from PIL import Image
import numpy as np
from pathlib import Path

def blend_by_normal_direction(original_path, normal_path, output_path, strength=1.0):
    """
    Blend images based on normal map Z component (blue channel).
    
    Args:
        original_path: Path to original image
        normal_path: Path to normal map image
        output_path: Path to save blended image
        strength: Strength factor (default 1.0). 
                 > 1.0: More areas use normal map (stronger effect)
                 < 1.0: Fewer areas use normal map (weaker effect)
    """
    # Load images
    original = Image.open(original_path).convert('RGB')
    normal_map = Image.open(normal_path).convert('RGB')
    
    # Ensure same size
    if original.size != normal_map.size:
        print(f"Warning: Images have different sizes. Resizing normal map to match original")
        normal_map = normal_map.resize(original.size, Image.Resampling.LANCZOS)
    
    # Convert to numpy arrays
    orig_arr = np.array(original, dtype=np.float32)
    normal_arr = np.array(normal_map, dtype=np.float32)
    
    # Extract Z component from normal map (blue channel)
    # Normal maps typically encode normals where:
    # - R = X component (mapped from -1 to 1, stored as 0-255)
    # - G = Y component (mapped from -1 to 1, stored as 0-255)
    # - B = Z component (mapped from -1 to 1, stored as 0-255)
    z_component = normal_arr[:, :, 2]  # Blue channel
    
    # Normalize Z component from [0, 255] to [0, 1]
    # High Z (close to 255) = facing camera
    # Low Z (close to 0) = perpendicular/away from camera
    z_normalized = z_component / 255.0
    
    # Create blend factor:
    # - High Z (facing camera) → blend_factor → 1.0 → use original image
    # - Low Z (perpendicular) → blend_factor → 0.0 → use normal map
    blend_factor = z_normalized
    
    # Apply strength factor to control effect intensity
    # Using power function: strength > 1 makes more areas use normal map
    # strength < 1 makes fewer areas use normal map
    if strength != 1.0:
        # Invert and apply power: blend_factor^(1/strength)
        # When strength > 1, this reduces blend_factor values, making more normal map visible
        # When strength < 1, this increases blend_factor values, making more original visible
        blend_factor = np.power(blend_factor, 1.0 / strength)
    
    # Expand blend_factor to 3 channels for broadcasting
    blend_factor_3d = np.stack([blend_factor, blend_factor, blend_factor], axis=2)
    
    # Blend: original * blend_factor + normal_map * (1 - blend_factor)
    blended = orig_arr * blend_factor_3d + normal_arr * (1.0 - blend_factor_3d)
    
    # Clip to valid range and convert back to uint8
    blended = np.clip(blended, 0, 255).astype(np.uint8)
    
    # Create PIL Image and save
    result = Image.fromarray(blended)
    result.save(output_path)
    
    print(f"Blended image saved to: {output_path}")
    print(f"  Original image: {original_path}")
    print(f"  Normal map: {normal_path}")
    print(f"  Strength factor: {strength}")
    print(f"  Blend logic: Original RGB where normals face camera, Normal RGB where perpendicular")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python blend_by_normal_direction.py <original_image> <normal_map> [output_path] [strength]", file=sys.stderr)
        print("  strength: Strength factor (default 1.0). > 1.0 = more normal map visible, < 1.0 = less normal map visible", file=sys.stderr)
        sys.exit(1)
    
    original_path = sys.argv[1]
    normal_path = sys.argv[2]
    
    if len(sys.argv) > 3:
        output_path = sys.argv[3]
    else:
        # Generate output path from original image
        orig = Path(original_path)
        output_path = str(orig.parent / f"{orig.stem}_normal_blended.png")
    
    strength = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
    
    blend_by_normal_direction(original_path, normal_path, output_path, strength)

