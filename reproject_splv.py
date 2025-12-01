import json
from spatialstudio import splv
import numpy as np
import cv2



# Read extrinsics and intrinsics from a json file
extrinsics = json.load(open("processing/frames/frame_0_extrinsics_intrinsics.json"))["extrinsics"]
intrinsics = json.load(open("processing/frames/frame_0_extrinsics_intrinsics.json"))["intrinsics"]

# Read depth from a npy file
depth = np.load("processing/frames/frame_0_depth.npy")

# Read image from a png file
image = cv2.imread("processing/frames/frame_0.png")

original_frame = splv.Frame.load("processing/frames/frame_0.vv")
# Get size of the original frame
w, h, d = original_frame.get_dims()

minPos = (0, 0, 0)
maxPos = (w, h, d)
# project image + depth into 3d voxels

_, minPos, maxPos = splv.Frame.from_rgbd(image, depth, intrinsics, extrinsics, minPos, maxPos, w, h, d)

new_frame, _, _ = splv.Frame.from_rgbd(image, depth, intrinsics, extrinsics, minPos, maxPos, w, h, d)

new_frame.save("processing/frames/frame_0_reprojected.vv")

# load the original frame
original_frame = splv.Frame.load("processing/frames/frame_0.vv")

combined_frame = original_frame.clone()
combined_frame.add(new_frame)
combined_frame.save("processing/frames/frame_0_combined.vv")

# Debug: cycle through the original frame, new frame, and the combined frame

encoder = splv.Encoder(
    width=w, height=h, depth=d, 
    framerate=1,
    outputPath="processing/frames/frame_0_cycle.splv"
)

encoder.encode(original_frame)
encoder.encode(new_frame)
encoder.encode(combined_frame)
encoder.finish()