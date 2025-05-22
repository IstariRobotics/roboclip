import os
import json
import struct
from pathlib import Path
import rerun as rr
import glob
import numpy as np
import cv2
import argparse  # Added for command-line arguments

# Path to downloaded data
DATA_DIR = Path(os.path.dirname(os.path.abspath(__file__))) / "../data"

def find_scan_folders():
    """Find all Scan-* folders in the local data directory"""
    if not DATA_DIR.exists():
        print(f"Data directory {DATA_DIR} doesn't exist.")
        print("Please run mirror_bucket.py first to download data.")
        return []
        
    # Look for Scan-* folders
    scan_folders = []
    for item in DATA_DIR.glob("Scan-*"):
        if item.is_dir():
            scan_folders.append(item)
            
    return scan_folders

def load_video_timestamps_json(json_path):
    """Load video frame wall-clock timestamps from video_timestamps.json as a list of floats."""
    with open(json_path, 'r') as f:
        data = json.load(f)
    # Extract wall_clock for each frame
    return [entry['wall_clock'] for entry in data]

def parse_imu_bin(file_path):
    """Parse an IMU CSV file into a list of events with wall-clock timestamps."""
    events = []
    try:
        with open(file_path, "r") as f:
            header = f.readline()  # skip header if present
            for line_idx, line in enumerate(f):
                line = line.strip()
                if not line:
                    continue
                parts = line.split(',')
                if len(parts) == 13:
                    try:
                        t_raw, roll, pitch, yaw, rx, ry, rz, ax, ay, az, gx, gy, gz = map(float, parts)
                        events.append({
                            "timestamp": t_raw,
                            "attitude": {"roll": roll, "pitch": pitch, "yaw": yaw},
                            "rotationRate": {"x": rx, "y": ry, "z": rz},
                            "userAcceleration": {"x": ax, "y": ay, "z": az},
                            "gravity": {"x": gx, "y": gy, "z": gz}
                        })
                    except ValueError as ve:
                        print(f"Error converting line to floats: {line} - {ve}")
                elif len(parts) == 10:
                    try:
                        t_raw, roll, pitch, yaw, rx, ry, rz, ax, ay, az = map(float, parts)
                        events.append({
                            "timestamp": t_raw,
                            "attitude": {"roll": roll, "pitch": pitch, "yaw": yaw},
                            "rotationRate": {"x": rx, "y": ry, "z": rz},
                            "userAcceleration": {"x": ax, "y": ay, "z": az}
                        })
                    except ValueError as ve:
                        print(f"Error converting line to floats: {line} - {ve}")
                else:
                    print(f"Skipping malformed line (expected 13 parts, got {len(parts)}): {line}")
    except Exception as e:
        print(f"Error parsing IMU data from {file_path}: {e}")
    return events

def locate_imu_file(folder_path):
    """Find the IMU file in the given folder"""
    imu_path = folder_path / "imu.bin"
    if imu_path.exists():
        return imu_path
    
    # Try finding any file named imu.bin
    imu_files = list(folder_path.glob("**/imu.bin"))
    if imu_files:
        return imu_files[0]
        
    return None

def euler_to_quaternion(roll, pitch, yaw):
    """Convert Euler angles (roll, pitch, yaw) to quaternion (x, y, z, w) for rerun Transform3D"""
    cy = np.cos(yaw * 0.5)
    sy = np.sin(yaw * 0.5)
    cp = np.cos(pitch * 0.5)
    sp = np.sin(pitch * 0.5)
    cr = np.cos(roll * 0.5)
    sr = np.sin(roll * 0.5)

    w = cr * cp * cy + sr * sp * sy
    x = sr * cp * cy - cr * sp * sy
    y = cr * sp * cy + sr * cp * sy
    z = cr * cp * sy - sr * sp * cy
    return [x, y, z, w]

def quaternion_multiply(q1, q2):
    # Multiplies two quaternions (x, y, z, w)
    x1, y1, z1, w1 = q1
    x2, y2, z2, w2 = q2
    w = w1*w2 - x1*x2 - y1*y2 - z1*z2
    x = w1*x2 + x1*w2 + y1*z2 - z1*y2
    y = w1*y2 - x1*z2 + y1*w2 + z1*x2
    z = w1*z2 + x1*y2 - y1*x2 + z1*w2
    return [x, y, z, w]

def arkit_imu_to_rerun_camera_quaternion(roll, pitch, yaw, extrinsic_rotation="xy180"):
    """
    Map ARKit/CoreMotion IMU orientation (roll, pitch, yaw) to rerun camera pose quaternion.
    extrinsic_rotation options:
      - "none": no extra rotation
      - "y180": 180 deg about Y (flip Z)
      - "x180": 180 deg about X (flip Y,Z)
      - "z180": 180 deg about Z (flip X,Y)
      - "y90": +90 deg about Y
      - "x90": +90 deg about X
      - "z90": +90 deg about Z
      - "y45": +45 deg about Y
      - "xy180": 180 deg about X then Y (flip both)
    """
    quat = euler_to_quaternion(roll, pitch, yaw)
    import math
    if extrinsic_rotation == "y180":
        angle = math.pi
        q_fix = [0, math.sin(angle/2), 0, math.cos(angle/2)]
        quat = quaternion_multiply(q_fix, quat)
    elif extrinsic_rotation == "x180":
        angle = math.pi
        q_fix = [math.sin(angle/2), 0, 0, math.cos(angle/2)]
        quat = quaternion_multiply(q_fix, quat)
    elif extrinsic_rotation == "z180":
        angle = math.pi
        q_fix = [0, 0, math.sin(angle/2), math.cos(angle/2)]
        quat = quaternion_multiply(q_fix, quat)
    elif extrinsic_rotation == "y90":
        angle = math.pi/2
        q_fix = [0, math.sin(angle/2), 0, math.cos(angle/2)]
        quat = quaternion_multiply(q_fix, quat)
    elif extrinsic_rotation == "x90":
        angle = math.pi/2
        q_fix = [math.sin(angle/2), 0, 0, math.cos(angle/2)]
        quat = quaternion_multiply(q_fix, quat)
    elif extrinsic_rotation == "z90":
        angle = math.pi/2
        q_fix = [0, 0, math.sin(angle/2), math.cos(angle/2)]
        quat = quaternion_multiply(q_fix, quat)
    elif extrinsic_rotation == "y45":
        angle = math.pi/4
        q_fix = [0, math.sin(angle/2), 0, math.cos(angle/2)]
        quat = quaternion_multiply(q_fix, quat)
    elif extrinsic_rotation == "xy180":
        # 180 deg about X then Y
        angle = math.pi
        q_x = [math.sin(angle/2), 0, 0, math.cos(angle/2)]
        q_y = [0, math.sin(angle/2), 0, math.cos(angle/2)]
        q_fix = quaternion_multiply(q_y, q_x)  # Note: order matters (Y * X)
        quat = quaternion_multiply(q_fix, quat)
    # else: no extra rotation
    quat = np.asarray(quat, dtype=np.float32)
    if np.isfinite(quat).all():
        norm = np.linalg.norm(quat)
        if norm > 1e-6:
            quat /= norm
    return quat

def rotate_vector_by_quaternion(v, q):
    """Rotate vector v (3,) by quaternion q (x, y, z, w)."""
    # Quaternion multiplication: v' = q * v * q_conj
    # Represent v as quaternion with w=0
    x, y, z = v
    qx, qy, qz, qw = q
    # Quaternion for vector
    vq = np.array([x, y, z, 0.0], dtype=np.float32)
    # Conjugate of q
    q_conj = np.array([-qx, -qy, -qz, qw], dtype=np.float32)
    # q * v
    def quat_mult(a, b):
        ax, ay, az, aw = a
        bx, by, bz, bw = b
        return np.array([
            aw*bx + ax*bw + ay*bz - az*by,
            aw*by - ax*bz + ay*bw + az*bx,
            aw*bz + ax*by - ay*bx + az*bw,
            aw*bw - ax*bx - ay*by - az*bz
        ], dtype=np.float32)
    tmp = quat_mult(q, vq)
    rotated = quat_mult(tmp, q_conj)
    return rotated[:3]

def load_video_frames(video_path):
    """Extract frames from video.mov using OpenCV"""
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        print(f"Error: Could not open video file {video_path}")
        return [], []
    frames = []
    timestamps = []
    fps = cap.get(cv2.CAP_PROP_FPS)
    frame_idx = 0
    while cap.isOpened():
        ret, frame = cap.read()
        if not ret:
            break
        # Convert BGR to RGB
        frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        frames.append(frame_rgb)
        timestamps.append(frame_idx / fps)
        frame_idx += 1
    cap.release()
    return frames, timestamps

def load_depth_frames(depth_dir, session_metadata): # Added session_metadata
    """Load all .d32 depth frames as numpy arrays, sorted by filename, and return (frames, timestamps)"""
    import re
    depth_files = sorted(glob.glob(str(depth_dir / '*.d32')))
    depth_frames = []
    depth_timestamps = []

    depth_width = session_metadata.get('depthWidth')
    depth_height = session_metadata.get('depthHeight')

    if not depth_width or not depth_height:
        print(f"Error: 'depthWidth' ({depth_width}) or 'depthHeight' ({depth_height}) not found or invalid in session_metadata for {depth_dir.parent.name}. Cannot process depth frames.")
        return [], []

    expected_elements = depth_height * depth_width
    print(f"DIAG_DEPTH_LOAD: Expecting depth frames with {expected_elements} elements ({depth_height}x{depth_width}).")

    for idx, f in enumerate(depth_files):
        arr = np.fromfile(f, dtype=np.float32)
        # Extract timestamp from filename (e.g., 58545.905945.d32)
        match = re.search(r'([0-9]+\.[0-9]+)\.d32$', f)
        if match:
            ts = float(match.group(1))
            depth_timestamps.append(ts)
        else:
            depth_timestamps.append(idx)  # fallback: index as timestamp
        if arr.size == expected_elements:
            arr = arr.reshape((depth_height, depth_width))
            depth_frames.append(arr)
            if idx < 2:
                print(f"DIAG_DEPTH_LOAD: Loaded depth frame from {f}, shape: {arr.shape}, dtype: {arr.dtype}")
                print(f"  Stats: min={np.min(arr):.3f}, max={np.max(arr):.3f}, mean={np.mean(arr):.3f}, non-zero values: {np.count_nonzero(arr)}/{arr.size}")
                sample_values = arr[arr.shape[0]//2, arr.shape[1]//2 - 2 : arr.shape[1]//2 + 2]
                print(f"  Sample values (center row, middle 4 pixels): {sample_values}")
        else:
            print(f"Warning: Depth file {f} has unexpected element count {arr.size}. Expected {expected_elements} ({depth_height}x{depth_width}). Skipping.")
    return depth_frames, depth_timestamps

def find_closest_imu_event(target_timestamp, imu_events):
    """Find the IMU event closest to the target_timestamp."""
    if not imu_events:
        return None
    
    imu_timestamps = np.array([e["timestamp"] for e in imu_events])
    # Find the index of the IMU event with the closest timestamp
    idx = np.searchsorted(imu_timestamps, target_timestamp, side="left")
    
    if idx == 0:
        return imu_events[0]
    if idx == len(imu_timestamps):
        return imu_events[-1]
    
    ts_before = imu_timestamps[idx-1]
    ts_after = imu_timestamps[idx]
    
    if (target_timestamp - ts_before) < (ts_after - target_timestamp):
        return imu_events[idx-1]
    else:
        return imu_events[idx]

def parse_camera_poses(session_folder):
    """Parse camera poses (4x4 matrices) from meta.json or a dedicated file if available."""
    poses = None
    poses_path = session_folder / "camera_poses.json"
    if poses_path.exists():
        with open(poses_path, "r") as f:
            poses = json.load(f)
        # Expecting a list of dicts: {"timestamp": float, "matrix": [[...], ...]}
        return poses
    # Optionally, try to load from meta.json if present
    meta_path = session_folder / "meta.json"
    if meta_path.exists():
        with open(meta_path, "r") as f:
            meta = json.load(f)
        if "camera_poses" in meta:
            return meta["camera_poses"]
    return None

def extract_translation_from_matrix(matrix):
    """Extract translation (x, y, z) from a 4x4 transform matrix."""
    return [matrix[0][3], matrix[1][3], matrix[2][3]]

def find_closest_pose(timestamp, poses):
    """Find the camera pose closest to the given timestamp."""
    if not poses:
        return None
    times = [p["timestamp"] for p in poses]
    idx = np.searchsorted(times, timestamp, side="left")
    if idx == 0:
        return poses[0]
    if idx == len(times):
        return poses[-1]
    before = times[idx-1]
    after = times[idx]
    if (timestamp - before) < (after - timestamp):
        return poses[idx-1]
    else:
        return poses[idx]

def save_camera_poses_from_imu(session_folder, session_imu_events):
    """Save a camera_poses.json file with identity rotation and zero translation for each IMU event (placeholder)."""
    poses = []
    for event in session_imu_events:
        # Identity 4x4 matrix (no translation, no rotation)
        matrix = [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 1],
        ]
        poses.append({
            "timestamp": event["timestamp"],
            "matrix": matrix
        })
    out_path = session_folder / "camera_poses.json"
    with open(out_path, "w") as f:
        json.dump(poses, f, indent=2)
    print(f"Wrote placeholder camera_poses.json with {len(poses)} poses to {out_path}")

def visualize_single_session_in_rerun(session_id, session_imu_events, session_metadata, video_frames, video_timestamps, depth_frames, depth_timestamps):
    """Visualize IMU, video, and depth data for a single session in rerun.io"""
    print(f"\n--- Visualizing session: {session_id} ---")
    
    # --- Diagnostic: Set extrinsic rotation for IMU-to-camera mapping ---
    imu_to_camera_extrinsic = "y90"  # +45 deg about Y axis (move frame 'right' in 3D space)
    print(f"[IMU2CAM] Using extrinsic rotation: {imu_to_camera_extrinsic}")
    
    app_name = f"roboclip-replay-{session_id}"
    rr.init(app_name)
    rr.spawn() # Spawns the Rerun viewer application

    if session_imu_events:
        session_imu_events.sort(key=lambda e: e["timestamp"]) # Ensure IMU events are sorted
        print(f"Found {len(session_imu_events)} IMU events for session {session_id}")
        # ---- START DIAGNOSTIC PRINTS ----
        imu_timestamps_for_diag = [e["timestamp"] for e in session_imu_events]
        if imu_timestamps_for_diag:
            print(f"DIAG: IMU timestamps range: min={min(imu_timestamps_for_diag):.3f}s, max={max(imu_timestamps_for_diag):.3f}s")
        # ---- END DIAGNOSTIC PRINTS ----

    if not video_frames and not depth_frames and not session_imu_events:
        print(f"No data (video, depth, or IMU) to visualize for session {session_id}. Skipping.")
        return # Changed from continue to return

    # --- Log Pinhole Camera Model once per session ---
    # This is logged to the camera's entity path and will apply to images logged there.
    base_camera_path = f"{session_id}/device/camera"
    
    # Attempt to get resolution from video if available, otherwise use default or depth
    width, height = 640, 480 # Default resolution
    if video_frames:
        width = video_frames[0].shape[1]
        height = video_frames[0].shape[0]
    elif depth_frames: # If no video, try to get resolution from depth (assuming depth is (H, W))
        height, width = depth_frames[0].shape # Depth shape is (H, W)
    
    f_len_x = session_metadata.get('intrinsics', {}).get('fx', (width + height) / 4.0)
    f_len_y = session_metadata.get('intrinsics', {}).get('fy', (width + height) / 4.0)
    principal_x = session_metadata.get('intrinsics', {}).get('cx', width / 2.0)
    principal_y = session_metadata.get('intrinsics', {}).get('cy', height / 2.0)

    image_from_camera_matrix = np.array([
        [f_len_x, 0, principal_x],
        [0, f_len_y, principal_y],
        [0, 0, 1.0]
    ], dtype=np.float32)

    rr.log(
        base_camera_path,
        rr.Pinhole(
            image_from_camera=image_from_camera_matrix,
            resolution=[float(width), float(height)]
        ),
        static=True # Log as static data as it doesn't change over time for the session
    )
    print(f"Logged Pinhole camera model for {session_id} to {base_camera_path}")

    # --- Determine the primary timeline and number of frames to log ---
    # Use video timestamps if available, otherwise try to use depth or IMU timestamps
    # This part needs careful handling if data sources have different lengths or start times.

    num_frames_to_log = 0
    primary_timestamps = []

    if video_frames:
        num_frames_to_log = len(video_frames)
        primary_timestamps = video_timestamps
        print(f"Using video stream as primary sync source for {session_id} ({num_frames_to_log} frames).")
        # ---- START DIAGNOSTIC PRINTS ----
        if primary_timestamps:
            print(f"DIAG: Video timestamps range: min={min(primary_timestamps):.3f}s, max={max(primary_timestamps):.3f}s")
        # ---- END DIAGNOSTIC PRINTS ----
    elif depth_frames: # If no video, use depth as primary
        # Create synthetic timestamps for depth if real ones aren't available
        # Assuming depth frames are sequential and roughly 30 FPS if no other info
        # This is a placeholder; actual depth timestamps would be better.
        depth_fps = session_metadata.get('depth_fps', 30) # Check metadata or assume 30
        primary_timestamps = [idx / depth_fps for idx in range(len(depth_frames))]
        num_frames_to_log = len(depth_frames)
        print(f"Using depth stream as primary sync source for {session_id} ({num_frames_to_log} frames at ~{depth_fps} FPS).")
    elif session_imu_events:
        # If only IMU, log IMU events directly against their own timestamps
        print(f"Only IMU data found for {session_id}. Logging IMU events directly.")
        for imu_idx, event in enumerate(session_imu_events):
            rr.set_time(timeline="timestamp", timestamp=event["timestamp"]) # Corrected API
            rr.set_time(timeline=f"{session_id}_imu_event_idx", sequence=imu_idx) # Corrected API
            
            attitude = event["attitude"]
            rotation = event["rotationRate"]
            accel = event["userAcceleration"]

            # Log Camera Pose (Transform3D) from IMU
            # Note: This assumes the IMU's coordinate system is aligned with the camera's desired pose.
            # If there's an extrinsic calibration (IMU to Camera), it should be applied here.
            quat = arkit_imu_to_rerun_camera_quaternion(attitude["roll"], attitude["pitch"], attitude["yaw"], extrinsic_rotation=imu_to_camera_extrinsic)
            if np.isfinite(quat).all():
                norm = np.linalg.norm(quat)
                if norm > 1e-6:
                    quat /= norm
                    if 0.99 < np.linalg.norm(quat) < 1.01:
                        # Log to the base_camera_path so it orients the camera space
                        rr.log(base_camera_path, rr.Transform3D(rotation=rr.datatypes.Quaternion(xyzw=quat)))

            # Log IMU scalar data
            imu_data_path = f"{session_id}/device/imu"
            # Log multiple scalars at once using rr.Scalars (fixed: use dict)
            rr.log(imu_data_path,
                   rr.Scalars({
                       "angular_velocity_x": float(rotation["x"]),
                       "angular_velocity_y": float(rotation["y"]),
                       "angular_velocity_z": float(rotation["z"]),
                       "acceleration_x": float(accel["x"]),
                       "acceleration_y": float(accel["y"]),
                       "acceleration_z": float(accel["z"]),
                       "attitude_roll": float(attitude["roll"]),
                       "attitude_pitch": float(attitude["pitch"]),
                       "attitude_yaw": float(attitude["yaw"])
                   })
            )
        print(f"Logged {len(session_imu_events)} IMU events for {session_id}.")
        return # Changed from continue to return
    else:
        print(f"No primary data source (video, depth, or IMU) for {session_id}. Skipping.")
        return # Changed from continue to return

    # Load camera poses if available
    session_folder = DATA_DIR / session_id
    camera_poses = parse_camera_poses(session_folder)

    # --- Synchronize and Log Camera Stream (IMU, Video, Depth) based on primary_timestamps ---
    print(f"Starting synchronized logging for {session_id} with {num_frames_to_log} frames...")

    # --- Depth/Video orientation diagnostic and fix ---
    # ARKit convention: depth and RGB are aligned, but pixel buffers may be transposed or flipped in file output.
    # We'll check the shape of the first video and depth frame and rotate depth if needed.
    depth_orientation_checked = False
    depth_needs_rot90 = False
    depth_needs_flipud = False
    depth_needs_fliplr = False

    for i in range(num_frames_to_log):
        current_time_sec = primary_timestamps[i]
        rr.set_time(timeline="timestamp", timestamp=current_time_sec) # Corrected API
        rr.set_time(timeline=f"{session_id}_frame_idx", sequence=i) # Corrected API
        
        closest_imu_event = find_closest_imu_event(current_time_sec, session_imu_events)

        # Camera translation from pose if available
        translation = None
        if camera_poses:
            pose = find_closest_pose(current_time_sec, camera_poses)
            if pose and "matrix" in pose:
                translation = extract_translation_from_matrix(pose["matrix"])

        # ---- START DIAGNOSTIC PRINTS ----
        if i < 5 or (num_frames_to_log // 2 - 2 <= i < num_frames_to_log // 2 + 1) or i >= num_frames_to_log - 5:
            if closest_imu_event:
                print(f"DIAG: Frame {i:03d}: Video time={current_time_sec:.3f}s -> IMU time={closest_imu_event['timestamp']:.3f}s, " +
                      f"Attitude (R/P/Y): {closest_imu_event['attitude']['roll']:.2f}, {closest_imu_event['attitude']['pitch']:.2f}, {closest_imu_event['attitude']['yaw']:.2f}")
            else:
                print(f"DIAG: Frame {i:03d}: Video time={current_time_sec:.3f}s -> No closest IMU event found.")
        # ---- END DIAGNOSTIC PRINTS ----

        if closest_imu_event:
            attitude = closest_imu_event["attitude"]
            rotation = closest_imu_event["rotationRate"]
            accel = closest_imu_event["userAcceleration"]

            # Log Camera Pose (Transform3D) from IMU
            quat = arkit_imu_to_rerun_camera_quaternion(attitude["roll"], attitude["pitch"], attitude["yaw"], extrinsic_rotation=imu_to_camera_extrinsic)
            if np.isfinite(quat).all():
                norm = np.linalg.norm(quat)
                if norm > 1e-6:
                    quat /= norm
                    if 0.99 < np.linalg.norm(quat) < 1.01:
                        if translation is not None:
                            rr.log(base_camera_path, rr.Transform3D(
                                translation=translation,
                                rotation=rr.datatypes.Quaternion(xyzw=quat)
                            ))
                        else:
                            rr.log(base_camera_path, rr.Transform3D(rotation=rr.datatypes.Quaternion(xyzw=quat)))

            # Transform IMU vectors to camera frame
            accel_vec = np.array([accel["x"], accel["y"], accel["z"]], dtype=np.float32)
            rot_vec = np.array([rotation["x"], rotation["y"], rotation["z"]], dtype=np.float32)
            accel_cam = rotate_vector_by_quaternion(accel_vec, quat)
            rot_cam = rotate_vector_by_quaternion(rot_vec, quat)

            # Log IMU scalar data, associated with the current frame
            imu_data_path = f"{session_id}/device/imu"
            rr.log(imu_data_path,
                   rr.Scalars({
                       "angular_velocity_x": float(rot_cam[0]),
                       "angular_velocity_y": float(rot_cam[1]),
                       "angular_velocity_z": float(rot_cam[2]),
                       "acceleration_x": float(accel_cam[0]),
                       "acceleration_y": float(accel_cam[1]),
                       "acceleration_z": float(accel_cam[2]),
                       "attitude_roll": float(attitude["roll"]),
                       "attitude_pitch": float(attitude["pitch"]),
                       "attitude_yaw": float(attitude["yaw"])
                   })
            )
            # Optionally, log as 3D arrows for diagnostics
            if i % 30 == 0:
                rr.log(f"{base_camera_path}/imu_accel_arrow", rr.Arrows3D(
                    origins=[[0.0, 0.0, 0.0]],
                    vectors=[accel_cam.tolist()],
                    colors=[[255, 128, 0]],
                    labels=["accel"]
                ))
                rr.log(f"{base_camera_path}/imu_rot_arrow", rr.Arrows3D(
                    origins=[[0.0, 0.0, 0.0]],
                    vectors=[rot_cam.tolist()],
                    colors=[[0, 128, 255]],
                    labels=["gyro"]
                ))

        # Log Video Frame if available and current index is valid
        if video_frames and i < len(video_frames):
            # Log the video frame in its original orientation (no vertical flip)
            video_frame = video_frames[i]
            rr.log(f"{base_camera_path}/rgb", rr.Image(video_frame))

        # Log Depth Frame if available and current index is valid
        # Find closest depth frame by timestamp
        if depth_frames and depth_timestamps:
            # For each video frame timestamp, find closest depth frame
            video_time = current_time_sec
            # Find index of closest depth timestamp
            closest_depth_idx = min(range(len(depth_timestamps)), key=lambda j: abs(depth_timestamps[j] - video_time))
            current_depth_frame = depth_frames[closest_depth_idx]
            # --- Orientation check and fix ---
            if not depth_orientation_checked and video_frames:
                rgb_shape = video_frames[0].shape[:2]
                depth_shape = current_depth_frame.shape
                print(f"DIAG_ORIENT: RGB shape={rgb_shape}, Depth shape={depth_shape}")
                if rgb_shape == depth_shape[::-1]:
                    print("DIAG_ORIENT: Rotating depth 90 degrees to match video orientation.")
                    depth_needs_rot90 = True
                elif rgb_shape != depth_shape:
                    print("DIAG_ORIENT: WARNING - Depth and video shapes do not match and are not simple transpose. Manual fix may be needed.")
                depth_orientation_checked = True
            if depth_needs_rot90:
                current_depth_frame = np.rot90(current_depth_frame)
            # --- Orientation diagnostic: try flips for depth (uncomment to test) ---
            # current_depth_frame = np.flipud(current_depth_frame)  # Try vertical flip
            # current_depth_frame = np.fliplr(current_depth_frame)  # Try horizontal flip
            # current_depth_frame = np.rot90(current_depth_frame)   # Try 90-degree rotation
            # --- FOV alignment: Upsample depth to match video frame resolution ---
            if video_frames:
                rgb_shape = video_frames[0].shape[:2]  # (height, width)
                if current_depth_frame.shape != rgb_shape:
                    # Use bilinear interpolation for upsampling
                    current_depth_frame_resized = cv2.resize(
                        current_depth_frame,
                        (rgb_shape[1], rgb_shape[0]),
                        interpolation=cv2.INTER_LINEAR
                    )
                    print(f"DIAG_FOV: Upsampled depth from {current_depth_frame.shape} to {current_depth_frame_resized.shape}")
                else:
                    current_depth_frame_resized = current_depth_frame
                # Optional: overlay for debug
                if i < 3:
                    # Normalize depth for visualization
                    dnorm = (current_depth_frame_resized - np.nanmin(current_depth_frame_resized)) / (np.nanmax(current_depth_frame_resized) - np.nanmin(current_depth_frame_resized) + 1e-6)
                    dvis = (dnorm * 255).astype(np.uint8)
                    dvis_color = cv2.applyColorMap(dvis, cv2.COLORMAP_JET)
                    overlay = cv2.addWeighted(video_frame, 0.7, dvis_color, 0.3, 0)
                    # Draw axes for orientation check
                    overlay_axes = overlay.copy()
                    h, w = overlay_axes.shape[:2]
                    # X axis (red, right)
                    cv2.arrowedLine(overlay_axes, (int(w*0.1), int(h*0.9)), (int(w*0.3), int(h*0.9)), (255,0,0), 3, tipLength=0.1)
                    cv2.putText(overlay_axes, 'X', (int(w*0.32), int(h*0.92)), cv2.FONT_HERSHEY_SIMPLEX, 1, (255,0,0), 2)
                    # Y axis (green, down)
                    cv2.arrowedLine(overlay_axes, (int(w*0.1), int(h*0.9)), (int(w*0.1), int(h*0.7)), (0,255,0), 3, tipLength=0.1)
                    cv2.putText(overlay_axes, 'Y', (int(w*0.12), int(h*0.68)), cv2.FONT_HERSHEY_SIMPLEX, 1, (0,255,0), 2)
                    rr.log(f"{base_camera_path}/debug_overlay", rr.Image(overlay_axes))
                rr.log(f"{base_camera_path}/depth", rr.DepthImage(current_depth_frame_resized, meter=1.0))
            else:
                rr.log(f"{base_camera_path}/depth", rr.DepthImage(current_depth_frame, meter=1.0))
        
        if i % 100 == 0 and i > 0:
            print(f"  Logged frame {i}/{num_frames_to_log} for {session_id} at time {current_time_sec:.2f}s")

    print(f"Logged {num_frames_to_log} synchronized frames to Rerun for session {session_id}")

    print("\nAll sessions processed. The Rerun viewer should be open.")
    print("If not, you can run 'rerun' from the command line to view the logged data ('roboclip-replay-all-sessions').")

def main():
    parser = argparse.ArgumentParser(description="Replay local scan data with Rerun.")
    parser.add_argument(
        "--session_id", 
        type=str, 
        default="Scan-20250521-0200",  # Default to a known session for easy testing
        help="The ID of the scan session to visualize (e.g., Scan-20250521-0200)"
    )
    args = parser.parse_args()

    session_to_visualize = args.session_id
    session_folder = DATA_DIR / session_to_visualize

    if not session_folder.exists() or not session_folder.is_dir():
        print(f"Error: Session folder {session_folder} not found.")
        scan_folders = find_scan_folders()
        if scan_folders:
            print("Available sessions are:")
            for sf in scan_folders:
                print(f"  {sf.name}")
        else:
            print("No scan sessions found in the data directory.")
        return

    print(f"Processing session: {session_to_visualize}")

    # Load IMU data for the specified session
    imu_events = []
    imu_file = locate_imu_file(session_folder)
    if imu_file:
        print(f"Parsing IMU data from {imu_file}")
        imu_events = parse_imu_bin(imu_file)
        print(f"Extracted {len(imu_events)} IMU events")
    else:
        print(f"No IMU file found in {session_folder}")

    # Load metadata for the specified session
    session_metadata = {}
    meta_path = session_folder / "meta.json"
    if meta_path.exists():
        try:
            with open(meta_path, 'r') as f:
                session_metadata = json.load(f)
            print(f"Loaded metadata for {session_to_visualize}: Device {session_metadata.get('device_model', 'N/A')}, Depth: {session_metadata.get('depthWidth')}x{session_metadata.get('depthHeight')}")
        except Exception as e:
            print(f"Error loading metadata for {session_to_visualize}: {e}")
    else:
        print(f"No meta.json found in {session_folder}. Depth processing will likely fail or be skipped.")

    # Load video frames
    video_frames, video_timestamps = [], []
    video_path = session_folder / "video.mov"
    if video_path.exists():
        print(f"Loading video frames from {video_path}")
        video_frames, video_timestamps = load_video_frames(video_path)
        if video_frames:
            print(f"Loaded {len(video_frames)} video frames for {session_to_visualize}")
        else:
            print(f"No frames could be loaded from {video_path}.")
    else:
        print(f"No video.mov found in {session_folder}.")

    # Load video timestamps from JSON
    video_timestamps_json_path = session_folder / "video_timestamps.json"
    if video_timestamps_json_path.exists():
        print(f"Loading video timestamps from {video_timestamps_json_path}")
        video_timestamps = load_video_timestamps_json(video_timestamps_json_path)
        print(f"Loaded {len(video_timestamps)} video timestamps for {session_to_visualize}")
    else:
        print(f"No video_timestamps.json found in {session_folder}.")

    # Load depth frames
    depth_frames, depth_timestamps = [], [] # depth_timestamps added
    depth_dir = session_folder / "depth"
    if depth_dir.exists():
        print(f"Loading depth frames from {depth_dir}")
        depth_frames, depth_timestamps = load_depth_frames(depth_dir, session_metadata) # Pass session_metadata
        if depth_frames:
            print(f"Loaded {len(depth_frames)} depth frames for {session_to_visualize}")
        else:
            print(f"No depth frames could be loaded from {depth_dir} (check metadata and file integrity).")
    else:
        print(f"No depth/ directory found in {session_folder}.")

    if not imu_events and not video_frames and not depth_frames:
        print(f"No data to visualize for session {session_to_visualize}. Exiting.")
        return

    # Visualize the single specified session
    # If camera_poses.json does not exist, create a placeholder (identity) version
    cam_poses_path = session_folder / "camera_poses.json"
    if not cam_poses_path.exists() and imu_events:
        save_camera_poses_from_imu(session_folder, imu_events)
    visualize_single_session_in_rerun(
        session_id=session_to_visualize,
        session_imu_events=imu_events,
        session_metadata=session_metadata,
        video_frames=video_frames,
        video_timestamps=video_timestamps,
        depth_frames=depth_frames,
        depth_timestamps=depth_timestamps
    )

if __name__ == "__main__":
    main()
