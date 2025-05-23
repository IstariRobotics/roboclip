import argparse
import json
from pathlib import Path
import numpy as np

from replay_local_data import load_depth_frames, find_closest_pose

DATA_DIR = Path(__file__).resolve().parent / "../data"

def load_metadata(meta_path: Path):
    with open(meta_path, 'r') as f:
        meta = json.load(f)
    intr = {
        'fx': meta.get('fx'),
        'fy': meta.get('fy'),
        'cx': meta.get('cx'),
        'cy': meta.get('cy'),
        'width': meta.get('depthWidth'),
        'height': meta.get('depthHeight'),
    }
    return intr

def load_camera_poses(pose_path: Path):
    with open(pose_path, 'r') as f:
        poses = json.load(f)
    return poses

def depth_to_points(depth: np.ndarray, intr):
    h, w = depth.shape
    xs = np.arange(w, dtype=np.float32)
    ys = np.arange(h, dtype=np.float32)
    grid_x, grid_y = np.meshgrid(xs, ys)
    z = depth.astype(np.float32)
    x = (grid_x - intr['cx']) * z / intr['fx']
    y = (grid_y - intr['cy']) * z / intr['fy']
    return np.stack([x, y, z], axis=-1)

def transform_points(points: np.ndarray, pose: np.ndarray):
    h, w, _ = points.shape
    pts_h = np.concatenate([points.reshape(-1,3), np.ones((h*w,1), dtype=np.float32)], axis=1)
    world = (pose @ pts_h.T).T
    return world[:, :3].reshape(h, w, 3)

def project_points(points: np.ndarray, intr):
    X = points[...,0]
    Y = points[...,1]
    Z = points[...,2]
    u = intr['fx'] * X / Z + intr['cx']
    v = intr['fy'] * Y / Z + intr['cy']
    return np.stack([u, v], axis=-1)

def compute_flow(depth1, depth2, pose1, pose2, intr):
    h, w = depth1.shape
    pts1 = depth_to_points(depth1, intr)
    world = transform_points(pts1, pose1)
    cam2_inv = np.linalg.inv(pose2)
    pts2_cam = transform_points(world, cam2_inv)
    proj = project_points(pts2_cam, intr)
    xs = np.arange(w, dtype=np.float32)
    ys = np.arange(h, dtype=np.float32)
    grid_x, grid_y = np.meshgrid(xs, ys)
    flow = np.zeros((h, w, 2), dtype=np.float32)
    valid = (depth1 > 0) & (pts2_cam[...,2] > 0)
    flow[...,0] = proj[...,0] - grid_x
    flow[...,1] = proj[...,1] - grid_y
    flow[~valid] = np.nan
    return flow

def main():
    parser = argparse.ArgumentParser(description="Compute optical flow from depth frames and camera poses")
    parser.add_argument('--session_id', required=True, help='ID of the Scan-* session')
    args = parser.parse_args()

    session_dir = DATA_DIR / args.session_id
    meta_path = session_dir / 'meta.json'
    pose_path = session_dir / 'camera_poses.json'
    depth_dir = session_dir / 'depth'

    intr = load_metadata(meta_path)
    poses = load_camera_poses(pose_path)

    depth_frames, depth_times = load_depth_frames(depth_dir, {
        'depthWidth': intr['width'],
        'depthHeight': intr['height']
    })

    for i in range(len(depth_frames)-1):
        d1 = depth_frames[i]
        d2 = depth_frames[i+1]
        t1 = depth_times[i]
        t2 = depth_times[i+1]
        pose1 = np.array(find_closest_pose(t1, poses)['matrix'], dtype=np.float32)
        pose2 = np.array(find_closest_pose(t2, poses)['matrix'], dtype=np.float32)
        flow = compute_flow(d1, d2, pose1, pose2, intr)
        out_path = depth_dir / f"{t1:.6f}.flow.npy"
        np.save(out_path, flow)
        print(f"Saved {out_path}")

if __name__ == '__main__':
    main()
