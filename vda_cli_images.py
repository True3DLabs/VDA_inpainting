#!/usr/bin/env python3
"""
VDA CLI (images directory) - Run Depth Anything on a directory of images

Arguments mirror VideoDepthAnything/vda_cli.py, except --input expects a directory of images.
Outputs per-image depth .npy and an optional colored visualization .png in the output directory.
"""

import argparse
import os
import sys
from pathlib import Path
import cv2
import numpy as np
import torch
from tqdm import tqdm
import shutil

# Resolve repository paths so we can import Depth Anything modules from VideoDepthAnything
REPO_ROOT = Path(__file__).resolve().parents[1]
# REPO_ROOT = Path("/home/al/vda_frankenstein")
VDA_ROOT = REPO_ROOT / "Video-Depth-Anything"
if str(VDA_ROOT) not in sys.path:
    sys.path.insert(0, str(VDA_ROOT))

# Depth Anything
from depth_anything.dpt import DepthAnything
from depth_anything.util.transform import Resize, NormalizeImage, PrepareForNet


def get_model(model_type: str = 'base', device: str = 'cuda'):
    """Load Depth Anything model (base or metric variants) similar to vda_cli.py."""
    if model_type == 'base':
        # DepthAnything internally calls torch.hub.load('torchhub/facebookresearch_dinov2_main', ... , source='local')
        # Ensure CWD is the repo root that contains the 'torchhub' directory so torch.hub can find it.
        _cwd = os.getcwd()
        os.chdir(str(VDA_ROOT))
        try:
            model = DepthAnything.from_pretrained('LiheYoung/depth_anything_vitl14', local_files_only=False).to(device).eval()
        finally:
            os.chdir(_cwd)
        checkpoint_path = str(VDA_ROOT / 'checkpoints/depth_anything_vitl14.pth')
        if os.path.exists(checkpoint_path):
            checkpoint = torch.load(checkpoint_path, map_location=device)
            if 'model' in checkpoint:
                checkpoint = checkpoint['model']
            model.load_state_dict(checkpoint)
            print(f"Loaded base model checkpoint: {checkpoint_path}")
        return model

    if model_type in ['indoor', 'outdoor']:
        sys.path.append(str(VDA_ROOT / 'metric_depth'))
        from zoedepth.models.builder import build_model
        from zoedepth.utils.config import get_config

        config = get_config("zoedepth", "eval")
        ckpt = (
            VDA_ROOT / 'checkpoints_metric_depth/depth_anything_metric_depth_indoor.pt'
            if model_type == 'indoor' else
            VDA_ROOT / 'checkpoints_metric_depth/depth_anything_metric_depth_outdoor.pt'
        )
        config.pretrained_resource = "local::" + str(ckpt)
        model = build_model(config).to(device).eval()
        print(f"Loaded {model_type} metric depth model: {ckpt}")
        return model

    raise ValueError(f"Unknown model type: {model_type}")


def infer_depth(image_bgr: np.ndarray, model, model_type: str, device: str) -> np.ndarray:
    """Infer depth for a single BGR image, returns float32 HxW array."""
    image_rgb = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
    h, w = image_bgr.shape[:2]

    if model_type == 'base':
        from torchvision.transforms import Compose
        transform = Compose([
            Resize(
                width=518,
                height=518,
                resize_target=False,
                keep_aspect_ratio=True,
                ensure_multiple_of=14,
                resize_method='lower_bound',
                image_interpolation_method=cv2.INTER_CUBIC,
            ),
            NormalizeImage(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
            PrepareForNet(),
        ])
        image_tensor = transform({'image': image_rgb / 255.0})['image']
        image_tensor = torch.from_numpy(image_tensor).unsqueeze(0).to(device)
        with torch.no_grad():
            depth = model(image_tensor)
        depth = torch.nn.functional.interpolate(
            depth.unsqueeze(1), size=(h, w), mode="bicubic", align_corners=False
        ).squeeze().cpu().numpy()
        return depth.astype(np.float32)

    # metric
    image_tensor = torch.from_numpy(image_rgb).permute(2, 0, 1).unsqueeze(0).float().to(device) / 255.0
    with torch.no_grad():
        out = model(image_tensor)
        # zoedepth returns dict
        depth = out['metric_depth'].squeeze().cpu().numpy()
    return depth.astype(np.float32)


def main():
    parser = argparse.ArgumentParser(description='Depth Anything on directory of images')
    parser.add_argument('--input', '-i', required=True, help='Input directory containing images')
    parser.add_argument('--model', '-m', choices=['base', 'indoor', 'outdoor'], default='base',
                        help='Model type: base (relative), indoor (metric), outdoor (metric)')
    parser.add_argument('--output', '-o', required=True, help='Output directory for results')
    parser.add_argument('--device', default='cuda', help='Device to use (cuda or cpu)')
    parser.add_argument('--visualize', action='store_true', help='Save colored visualization PNGs alongside .npy')
    args = parser.parse_args()

    input_dir = Path(args.input)
    if not input_dir.is_dir():
        print(f"Input is not a directory: {input_dir}")
        sys.exit(1)

    device = torch.device(args.device if torch.cuda.is_available() else 'cpu')
    if device.type == 'cpu' and args.device == 'cuda':
        print("CUDA not available, using CPU")

    print(f"Loading model: {args.model}")
    model = get_model(args.model, device)

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    # Clear output directory contents before writing
    for entry in output_dir.iterdir():
        try:
            if entry.is_dir() and not entry.is_symlink():
                shutil.rmtree(entry)
            else:
                entry.unlink(missing_ok=True)
        except FileNotFoundError:
            pass

    # Gather images
    exts = {'.jpg', '.jpeg', '.png', '.bmp'}
    image_paths = sorted([p for p in input_dir.iterdir() if p.suffix.lower() in exts])
    if not image_paths:
        print(f"No images found in: {input_dir}")
        sys.exit(1)

    print(f"Found {len(image_paths)} images in {input_dir}")

    depths = []
    for img_path in tqdm(image_paths, desc='Processing images'):
        img = cv2.imread(str(img_path))
        if img is None:
            print(f"Warning: failed to read {img_path}")
            continue
        depth = infer_depth(img, model, args.model, device)
        depths.append(depth.astype(np.float32))

    if not depths:
        print("No valid images processed; nothing to save.")
        sys.exit(1)

    # Stack into (N, H, W) and save single NPZ with key 'depth'
    import numpy as _np
    depth_stack = _np.stack(depths, axis=0)
    out_path = output_dir / 'depth.npz'
    _np.savez_compressed(out_path, depth=depth_stack)
    print(f"Saved depth stack with shape {depth_stack.shape} to: {out_path}")


if __name__ == '__main__':
    main()


