import argparse
import json
import os
import shutil
from pathlib import Path
import cv2
import numpy as np


def export_to_arflow(session_dir: Path, out_dir: Path) -> None:
    """Export a roboclip session to an ARFlow style directory."""
    if not session_dir.exists():
        raise FileNotFoundError(f"Session directory {session_dir} does not exist")

    out_dir.mkdir(parents=True, exist_ok=True)
    rgb_dir = out_dir / "frames"
    depth_dir = out_dir / "depth"
    pose_dir = out_dir / "camera_poses"
    imu_dir = out_dir / "imu"

    for d in [rgb_dir, depth_dir, pose_dir, imu_dir]:
        d.mkdir(parents=True, exist_ok=True)

    # --- Export RGB frames ---
    video_path = session_dir / "video.mov"
    if video_path.exists():
        cap = cv2.VideoCapture(str(video_path))
        idx = 0
        while cap.isOpened():
            ret, frame = cap.read()
            if not ret:
                break
            frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            out_path = rgb_dir / f"{idx:06d}.png"
            cv2.imwrite(str(out_path), frame_rgb)
            idx += 1
        cap.release()

    # --- Export depth frames ---
    depth_src = session_dir / "depth"
    if depth_src.is_dir():
        for idx, f in enumerate(sorted(depth_src.glob("*.d32"))):
            arr = np.fromfile(f, dtype=np.float32)
            out_path = depth_dir / f"{idx:06d}.npy"
            np.save(out_path, arr)

    # --- Export camera poses ---
    poses_path = session_dir / "camera_poses.json"
    if poses_path.exists():
        with open(poses_path, "r") as f:
            poses = json.load(f)
        for idx, pose in enumerate(poses):
            matrix = np.array(pose.get("matrix", []), dtype=np.float32)
            out_path = pose_dir / f"{idx:06d}.txt"
            np.savetxt(out_path, matrix)

    # --- Export IMU ---
    imu_src = session_dir / "imu.bin"
    if imu_src.exists():
        shutil.copy2(imu_src, imu_dir / "imu.csv")

    # --- Export intrinsics ---
    meta_path = session_dir / "meta.json"
    if meta_path.exists():
        with open(meta_path, "r") as f:
            meta = json.load(f)
        fx = meta.get("fx")
        fy = meta.get("fy")
        cx = meta.get("cx")
        cy = meta.get("cy")
        if fx and fy and cx and cy:
            with open(out_dir / "intrinsics.txt", "w") as f_intr:
                f_intr.write(f"{fx} {fy} {cx} {cy}\n")
        shutil.copy2(meta_path, out_dir / "meta.json")


def main() -> None:
    parser = argparse.ArgumentParser(description="Export a Scan-* session to ARFlow format")
    parser.add_argument("session_dir", type=Path, help="Path to Scan-YYYYMMDD-hhmm directory")
    parser.add_argument("out_dir", type=Path, help="Output directory for ARFlow formatted data")
    args = parser.parse_args()
    export_to_arflow(args.session_dir, args.out_dir)


if __name__ == "__main__":
    main()
