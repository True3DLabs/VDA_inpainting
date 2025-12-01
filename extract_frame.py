from spatialstudio import splv
import os

video = splv.Decoder("processing/710.splv")
os.makedirs("processing/frames", exist_ok=True)

for frame in video:
    frame.save(f"processing/frames/frame_0.vv")
    break