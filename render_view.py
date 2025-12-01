from spatialstudio import splv
from PIL import Image
import numpy as np
import json

def find_extrinsics(camPos, camTarget):
    """
    Compute camera extrinsics matrix from camera position and target.
    
    Args:
        camPos: tuple or array of (x, y, z) camera position
        camTarget: tuple or array of (x, y, z) camera target point
    
    Returns:
        extrinsics: 3x4 numpy array representing the extrinsics matrix
    """
    camPos = np.array(camPos, dtype=np.float32)
    camTarget = np.array(camTarget, dtype=np.float32)
    
    # Compute forward vector (normalized direction from camPos to camTarget)
    forward = camTarget - camPos
    forward = forward / np.linalg.norm(forward)
    
    # World up vector
    up = np.array([0.0, 1.0, 0.0], dtype=np.float32)
    
    # Compute right vector (normalized cross product of up and forward)
    right = np.cross(up, forward)
    right = right / np.linalg.norm(right)
    
    # Recompute up vector (normalized cross product of forward and right)
    up = np.cross(forward, right)
    up = up / np.linalg.norm(up)
    
    # Build extrinsics matrix (3x4)
    # Translation component is negative dot product of each axis with camPos
    extrinsics = np.array([
        [right[0], right[1], right[2], -np.dot(right, camPos)],
        [up[0], up[1], up[2], -np.dot(up, camPos)],
        [forward[0], forward[1], forward[2], -np.dot(forward, camPos)]
    ], dtype=np.float32)
    
    return extrinsics


def find_intrinsics(imageWidth, imageHeight, camFov):
    """
    Compute camera intrinsics matrix from image dimensions and field of view.
    
    Args:
        imageWidth: width of the image in pixels
        imageHeight: height of the image in pixels
        camFov: field of view in degrees
    
    Returns:
        intrinsics: 3x3 numpy array representing the intrinsics matrix
    """
    # Convert FOV from degrees to radians
    fovY = np.deg2rad(camFov)
    
    # Compute focal length
    fy = 0.5 * imageHeight / np.tan(0.5 * fovY)
    fx = fy  # TODO: why does it get stretched with non-square focal lengths?
    
    # Principal point (image center)
    cx = imageWidth * 0.5
    cy = imageHeight * 0.5
    
    # Build intrinsics matrix (3x3)
    intrinsics = np.array([
        [fx, 0.0, cx],
        [0.0, fy, cy],
        [0.0, 0.0, 1.0]
    ], dtype=np.float32)
    
    return intrinsics


# 

frame = splv.Frame.load("processing/frames/frame_0.vv")




# render the view
img, depth = frame.render(width=1024, height=1024, fov=80, camPos=(1, 0.1, -1), camTarget=(0, 0, 0))
# breakpoint()
# turn the image from numpy array to PIL image
img = Image.fromarray(img)
np.save("processing/frames/frame_0_depth.npy", depth)
img.save("processing/frames/frame_0.png")
depth_img = Image.fromarray((depth * 255 / depth.max()).astype(np.uint8))
depth_img.save("processing/frames/frame_0_depth.png")

# output the extrinsics and intrinsics to a json file
extrinsics = find_extrinsics((1, 0.1, -1), (0, 0, 0))
intrinsics = find_intrinsics(1024, 1024, 80)
json.dump({"extrinsics": extrinsics.tolist(), "intrinsics": intrinsics.tolist()}, open("processing/frames/frame_0_extrinsics_intrinsics.json", "w"))