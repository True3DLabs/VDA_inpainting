import json
from spatialstudio import splv
import numpy as np
import cv2

def make_bounds_cubic(world_min, world_max):
    world_min = np.array(world_min, dtype=float)
    world_max = np.array(world_max, dtype=float)

    # Compute the current extents
    size = world_max - world_min
    max_extent = np.max(size)

    # Compute padding for each axis to make them all equal to max_extent
    pad = (max_extent - size) / 2.0

    # Expand bounds symmetrically
    new_min = world_min - pad
    new_max = world_max + pad

    return tuple(new_min), tuple(new_max)

# Read depth from a npy file
depth = np.load("processing/vda_metric_outputs/depth_npy/snow_fountain_frame_1.npy")

max_depth = 50.0
depth[depth > max_depth] = max_depth

# Read extrinsics and intrinsics from a json file
# extrinsics = json.load(open("processing/frames/frame_0_extrinsics_intrinsics.json"))["extrinsics"]
# intrinsics = json.load(open("processing/frames/frame_0_extrinsics_intrinsics.json"))["intrinsics"]

extrinsics = np.array([
    [1, 0, 0, 0],
    [0, 1, 0, 0],
    [0, 0, 1, 0]
])
intrinsics = np.load("processing/inputs/intrinsics.npy")
fx, fy, cx, cy = intrinsics[0, 0:4]
width, height = depth.shape[1], depth.shape[0]
intrinsics = np.array([
    [fx * width, 0,  cx * width],
    [0,  fy * height, cy * height],
    [0,  0,  1]
])


# Read image from a png file
image = cv2.imread("processing/inputs/snow_fountain_frame_1.png")

print(image.shape)

w, h, d = 760, 760, 760

minPos = (0, 0, 0)
maxPos = (1, 1, 1)

breakpoint()

new_frame, minPos, maxPos = splv.Frame.from_rgbd(image, depth, intrinsics, extrinsics, minPos, maxPos, w, h, d)

minPos, maxPos = make_bounds_cubic(minPos, maxPos)

new_frame, _, _ = splv.Frame.from_rgbd(image, depth, intrinsics, extrinsics, minPos, maxPos, w, h, d)

new_frame.save("processing/frames/snow_fountain_frame_0_projected.vv")


# Debug: cycle through the original frame, new frame, and the combined frame

encoder = splv.Encoder(
    width=w, height=h, depth=d, 
    framerate=1,
    outputPath="processing/frames/snow_fountain_frame_0.splv"
)

encoder.encode(new_frame)
encoder.finish()

# Try rendering the frame
breakpoint()
render, output_depth = splv.Frame.render(new_frame, image.shape[1], image.shape[0], intrinsics, extrinsics)
cv2.imwrite("processing/frames/snow_fountain_frame_0_rendered.png", render)

print("Output depth range:", output_depth.min(), output_depth.mean(), output_depth.max())
print("Original depth range:", depth.min(), depth.mean(), depth.max())