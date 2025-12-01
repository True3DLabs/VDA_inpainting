# VDA Inpainting Pipeline

Video processing pipeline for depth estimation and inpainting.

## Repository Structure

This repository contains the main pipeline scripts (`.py` and `.sh` files) in the root directory. The following nested directories contain external repositories/dependencies:

### Nested Repositories (not tracked in this git repo)

- **Video-Depth-Anything/**: Video depth estimation using Depth Anything
- **6dv-frontend/**: Frontend application (Next.js)
- **Depth-Anything-3/**: DA3 depth estimation models
- **VideoPainter/**: Video inpainting models
- **Marigold-DC/**: Marigold depth completion
- **FLUX-Fill/**: FLUX image inpainting
- **SDXL-Inpaint/**: SDXL-based inpainting
- **Page4D/**: 4D point cloud processing
- **sam3/**: SAM3 segmentation
- **vggt/**: VGGT models
- **RGBD/**: RGBD utilities

These nested repositories should be managed separately or added as git submodules if needed.

## Main Scripts

- `main.sh`: Main video processing pipeline with scene detection and VDA depth estimation
- `main_v2.sh`: Alternative pipeline with DA3 depth estimation
- `scene_split.py`: Scene detection using PySceneDetect
- `video_outpainting.py`: Video outpainting utilities
- Other utility scripts for various processing tasks

## Usage

See individual script files for usage instructions.

