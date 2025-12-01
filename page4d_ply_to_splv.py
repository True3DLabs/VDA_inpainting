import glob
import os
from spatialstudio import splv
import plyfile
import numpy as np

input_path = "/home/al/VDA_inpainting/page4dpoutput/riverside/fig1_update_vggt"
output_path = "/home/al/VDA_inpainting/page4doutput/riverside/splv/page4d_output.splv"

os.makedirs(os.path.dirname(output_path), exist_ok=True)


def get_world_bounds(ply_file_list):
    all_vertices = []
    for ply_file in ply_file_list:
        ply = plyfile.PlyData.read(ply_file)
        vertex_data = ply.elements[0].data
        vertices = np.column_stack([vertex_data['x'], vertex_data['y'], vertex_data['z']])
        all_vertices.append(vertices)
    
    all_vertices = np.vstack(all_vertices)
    min_bounds = np.min(all_vertices, axis=0)
    max_bounds = np.max(all_vertices, axis=0)
    return min_bounds, max_bounds


ply_files = glob.glob(os.path.join(input_path, "*.ply"))
breakpoint()
min_bounds, max_bounds = get_world_bounds(ply_files)
print(min_bounds, max_bounds)

splv_width = 400
splv_height = 400
splv_depth = 400
splv_framerate = 2

x_range = max_bounds[0] - min_bounds[0]
y_range = max_bounds[1] - min_bounds[1]
z_range = max_bounds[2] - min_bounds[2]

x_scale = x_range / (splv_width - 1)
y_scale = y_range / (splv_height - 1)
z_scale = z_range / (splv_depth - 1)

x_offset = min_bounds[0]
y_offset = min_bounds[1]
z_offset = min_bounds[2]
encoder = splv.Encoder(width=splv_width, height=splv_height, depth=splv_depth, framerate=splv_framerate, outputPath=output_path)


for ply_file in ply_files:
    frame = splv.Frame(splv_width, splv_height, splv_depth)
    ply = plyfile.PlyData.read(ply_file)
    vertex_data = ply.elements[0].data
    for i in range(len(vertex_data)):
        r, g, b = vertex_data['red'][i], vertex_data['green'][i], vertex_data['blue'][i]
        x, y, z = vertex_data['x'][i], vertex_data['y'][i], vertex_data['z'][i]
        x = int((x - x_offset) / x_scale)
        y = int((y - y_offset) / y_scale)
        z = int((z - z_offset) / z_scale)
        frame[x, splv_height - 1 - y, z] = (r, g, b)
    encoder.encode(frame)

encoder.finish()
print("Done: %s" % output_path)