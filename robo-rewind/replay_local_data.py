import os
import json
import struct
from pathlib import Path
from scipy.spatial.transform import Rotation as R
import rerun as rr
import glob
import numpy as np
import cv2
import argparse  # Added for command-line arguments
import re # Ensure re is imported

# Path to downloaded data
DATA_DIR = Path(os.path.dirname(os.path.abspath(__file__))) / "../data"

def find_scan_folders():
    """Find all Scan-* folders in the local data directory, sorted from newest to oldest."""
    if not DATA_DIR.exists():
        print(f"Data directory {DATA_DIR} doesn't exist.")
        print("Please run mirror_bucket.py first to download data.")
        return []
        
    # Look for Scan-* folders
    scan_folders = []
    for item in DATA_DIR.glob("Scan-*"):
        if item.is_dir():
            scan_folders.append(item)
            
    # Sort folders by name in descending order (newest first)
    scan_folders.sort(key=lambda x: x.name, reverse=True)
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

# Helper for quaternion multiplication (xyzw format)
def quaternion_multiply(q1_xyzw, q2_xyzw):
    """Multiplies two quaternions in [x,y,z,w] format. q_total = q1 * q2 (apply q2 then q1)."""
    # SciPy's Rotation expects scalar-last (xyzw)
    r1 = R.from_quat(q1_xyzw)
    r2 = R.from_quat(q2_xyzw)
    r_total = r1 * r2
    return r_total.as_quat()

def arkit_device_orientation_from_imu(roll, pitch, yaw, sensor_to_device_rotation_xyzw=None):
    """
    Calculates the ARKit device orientation quaternion in the world frame from IMU data.
    Assumes roll, pitch, yaw (in radians) define the orientation of the IMU sensor frame.
    An optional sensor_to_device_rotation can be provided if the IMU sensor frame
    is not aligned with the ARKit device frame (+X right, +Y up, +Z out of screen).

    Args:
        roll, pitch, yaw: In radians.
        sensor_to_device_rotation_xyzw: Optional [x,y,z,w] quaternion for sensor -> device frame.
                                       If None or identity, assumes IMU frame = device frame.
    Returns:
        [x,y,z,w] numpy array for q_world_from_arkitDevice.
    """
    # Order ZYX for yaw, pitch, roll. ARKit attitude is typically given in this sequence.
    # This creates q_world_from_sensor
    q_world_from_sensor = R.from_euler('zyx', [yaw, pitch, roll], degrees=False).as_quat() # xyzw

    if sensor_to_device_rotation_xyzw is not None and \
       not np.allclose(sensor_to_device_rotation_xyzw, [0.0, 0.0, 0.0, 1.0], atol=1e-7):
        # q_world_from_device = q_world_from_sensor * q_sensor_to_device
        q_world_from_device = quaternion_multiply(q_world_from_sensor, sensor_to_device_rotation_xyzw)
        return q_world_from_device
    else:
        # Assumes IMU sensor frame is already the ARKit device frame
        return q_world_from_sensor

def rotate_vector_by_quaternion(v, q_xyzw):
    """Rotates vector v by quaternion q (xyzw)."""
    # Convert v to a pure quaternion
    v_quat = np.array([v[0], v[1], v[2], 0.0])
    # Conjugate of q
    q_conj = np.array([-q_xyzw[0], -q_xyzw[1], -q_xyzw[2], q_xyzw[3]])
    # Rotated vector: q * v_pure * q_conjugate
    # Step 1: q * v_pure
    qv = quaternion_multiply(q_xyzw, v_quat)
    # Step 2: (q * v_pure) * q_conjugate
    qv_q_conj = quaternion_multiply(qv, q_conj)
    return qv_q_conj[:3] # Return the vector part

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

    app_name = f"roboclip-replay-{session_id}"
    rr.init(app_name) # Removed spawn=True, will call rr.spawn() later
    # rr.spawn() # Spawns the Rerun viewer application - moved later

    # Log the ARKit world coordinate system (Right, Up, Back)
    rr.log("/", rr.ViewCoordinates.RUB, static=True)
    print(f"[COORD_SYS] Logged ARKit world coordinate system (RUB) to path '/'.")

    # --- IMU to ARKit Device extrinsic rotation setup ---
    # This defines the rotation from the IMU's native sensor frame to ARKit's device frame
    # (+X right, +Y up, +Z out of screen).
    # For now, "none" means IMU frame is assumed to be already aligned with ARKit device frame.
    imu_sensor_to_arkit_device_extrinsic_name = "none" 
    q_imuSensor_to_arkitDevice_xyzw = np.array([0.0, 0.0, 0.0, 1.0]) # Identity quaternion
    
    # if imu_sensor_to_arkit_device_extrinsic_name == "y90": # Example for future use
    #     q_imuSensor_to_arkitDevice_xyzw = R.from_euler('y', 90, degrees=True).as_quat()
    # Add other named extrinsics here if they become necessary.
    print(f"[IMU_SETUP] Using IMU sensor to ARKit device extrinsic: {imu_sensor_to_arkit_device_extrinsic_name}")

    # --- Define ARKit Device to Rerun Camera coordinate system rotation ---
    # ARKit device frame: +X right, +Y up, +Z out of screen (towards user/backwards from scene)
    # Rerun RDF camera frame: +X right, +Y down, +Z into scene (forwards)
    # This matrix rotates ARKit device coordinates to Rerun camera coordinates (180 deg around X).
    M_arkitDevice_to_rerunCam = np.array([[1,0,0], [0,-1,0], [0,0,-1]], dtype=np.float32)
    q_arkitDevice_to_rerunCam_xyzw = R.from_matrix(M_arkitDevice_to_rerunCam).as_quat() # xyzw
    print(f"[COORD_SYS] ARKit Device to Rerun Camera RDF transform (q_arkitDevice_to_rerunCam_xyzw): {q_arkitDevice_to_rerunCam_xyzw}")

    # Create a 4x4 transformation matrix for post-multiplication
    T_arkitDevice_from_rerunCamera_4x4 = np.eye(4, dtype=np.float32)
    T_arkitDevice_from_rerunCamera_4x4[0:3, 0:3] = M_arkitDevice_to_rerunCam

    # app_name = f"roboclip-replay-{session_id}"
    # rr.init(app_name)
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
    # Log RDF view coordinates to the camera entity path so images are interpreted correctly
    rr.log(base_camera_path, rr.ViewCoordinates.RDF, static=True)
    print(f"Logged Pinhole camera model and RDF ViewCoordinates for {session_id} to {base_camera_path}")

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
            # 1. Get device orientation in ARKit frame
            q_world_from_arkitDevice_xyzw = arkit_device_orientation_from_imu(
                attitude["roll"], attitude["pitch"], attitude["yaw"],
                sensor_to_device_rotation_xyzw=q_imuSensor_to_arkitDevice_xyzw
            )
            # 2. Convert to Rerun RDF camera orientation
            q_world_from_camera_final_xyzw = quaternion_multiply(q_world_from_arkitDevice_xyzw, q_arkitDevice_to_rerunCam_xyzw)
            
            # Use q_world_from_arkitDevice_xyzw directly as the camera pose
            # q_world_from_camera_final_xyzw = q_world_from_arkitDevice_xyzw # This was the previous line

            norm_q_world_camera_final = np.linalg.norm(q_world_from_camera_final_xyzw)
            if norm_q_world_camera_final > 1e-6:
                q_world_from_camera_final_xyzw /= norm_q_world_camera_final # Normalize

            if np.isfinite(q_world_from_camera_final_xyzw).all():
                rr.log(
                    base_camera_path,
                    rr.Transform3D(
                        rotation=rr.Quaternion(xyzw=q_world_from_camera_final_xyzw), # Rerun expects xyzw
                        # Assuming [0,0,0] translation when only IMU is present for camera pose
                        translation=[0.0, 0.0, 0.0] 
                    )
                )
            # ... rest of IMU-only logging ...
            # Log IMU scalar data (raw, untransformed by camera orientation here, or choose a frame)
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

        # Initialize variables for camera transform
        translation_from_pose = None # Stores [x,y,z] from camera_poses.json if available
        pose_matrix_for_transform = None # Stores full 4x4 matrix if valid and non-identity

        if camera_poses:
            pose = find_closest_pose(current_time_sec, camera_poses)
            if pose and "matrix" in pose:
                # Always extract translation. If matrix is identity, this will be [0,0,0].
                translation_from_pose = extract_translation_from_matrix(pose["matrix"])
                
                current_pose_matrix_np = np.array(pose["matrix"], dtype=np.float32)
                identity_4x4 = np.eye(4, dtype=np.float32)
                # Check if the matrix is significantly different from an identity matrix
                # Use a much stricter tolerance since our translation values are in the millimeter range
                if not np.allclose(current_pose_matrix_np, identity_4x4, atol=1e-8):
                    pose_matrix_for_transform = current_pose_matrix_np # Use the full matrix from JSON
                    if i < 5 or (num_frames_to_log // 2 - 2 <= i < num_frames_to_log // 2 + 1) or i >= num_frames_to_log - 5:
                        print(f"DIAG_POSE: Frame {i}: Using full pose matrix from camera_poses.json for transform. Translation: {translation_from_pose}")
                elif i < 5: # Matrix is identity or close to it
                    print(f"DIAG_POSE: Frame {i}: Matrix in camera_poses.json is identity/near-identity. Will use IMU for rotation if available. Translation from pose: {translation_from_pose}")
            elif i < 5: # pose or matrix key missing
                print(f"DIAG_POSE: Frame {i}: No valid pose or matrix key in camera_poses.json entry for timestamp {current_time_sec:.3f}s.")
        elif i < 5: # camera_poses is None
            print(f"DIAG_POSE: Frame {i}: camera_poses.json not loaded or empty.")

        # ---- START DIAGNOSTIC PRINTS (can be kept or adjusted) ----
        if i < 5 or (num_frames_to_log // 2 - 2 <= i < num_frames_to_log // 2 + 1) or i >= num_frames_to_log - 5:
            if closest_imu_event:
                attitude_diag = closest_imu_event.get("attitude", {})
                print(f"DIAG: Frame {i}: Video time={current_time_sec:.3f}s -> IMU time={closest_imu_event['timestamp']:.3f}s, Attitude (R/P/Y): {attitude_diag.get('roll', 0):.2f}, {attitude_diag.get('pitch', 0):.2f}, {attitude_diag.get('yaw', 0):.2f}")
            else:
                print(f"DIAG: Frame {i}: Video time={current_time_sec:.3f}s -> No corresponding IMU event found.")
        # ---- END DIAGNOSTIC PRINTS ----

        camera_orientation_quat_for_imu_vectors = None # Quaternion [x,y,z,w] representing camera's final orientation

        if pose_matrix_for_transform is not None:
            # Case 1: Valid, non-identity matrix from camera_poses.json.
            # This matrix is T_world_from_arkitDevice (RUB), as world is RUB.
            if i < 5: # Reduced verbosity, but keep for a few frames
                print(f"DIAG_CAM_TRANSFORM: Frame {i}: Using pose_matrix_for_transform (from camera_poses.json, assumed RUB), will apply Rx(180)")
            
            M_world_from_arkitDevice_4x4 = pose_matrix_for_transform # This is already a 4x4 np.array
            
            # Apply the Rx(180) transformation: T_world_from_rerunCam = T_world_from_arkitDevice * T_arkitDevice_from_rerunCam
            M_world_from_rerunCamera_4x4 = M_world_from_arkitDevice_4x4 @ T_arkitDevice_from_rerunCamera_4x4

            R_world_from_rerunCamera = M_world_from_rerunCamera_4x4[0:3, 0:3]
            t_world_from_rerunCamera = M_world_from_rerunCamera_4x4[0:3, 3]

            rr.log(base_camera_path, rr.Transform3D(translation=t_world_from_rerunCamera.tolist(), mat3x3=R_world_from_rerunCamera))
            if i < 5 or (num_frames_to_log // 2 - 2 <= i < num_frames_to_log // 2 + 1) or i >= num_frames_to_log - 5:
                print(f"DIAG_POSE_LOG: Frame {i}: Logged Transform3D from camera_poses.json * Rx(180). Translation: {t_world_from_rerunCamera.tolist()}")
            
            # This quaternion represents the orientation of the Rerun camera in the world.
            # q_world_from_rerunCam_xyzw = R.from_matrix(R_world_from_rerunCam).as_quat() # xyzw
            # camera_orientation_quat_for_imu_vectors = q_world_from_rerunCam_xyzw # Store for IMU vector rotation

        elif closest_imu_event:
            # Case 2: No valid full matrix from camera_poses.json, fallback to IMU for orientation.
            # Translation might still come from camera_poses.json if it had an identity matrix, or default to [0,0,0].
            if i < 5: # Reduced verbosity
                print(f"DIAG_CAM_TRANSFORM: Frame {i}: Using IMU for orientation.")
            
            attitude = closest_imu_event.get("attitude", {})
            # 1. Get device orientation in ARKit frame from IMU
            q_world_from_arkitDevice_xyzw = arkit_device_orientation_from_imu(
                attitude.get("roll", 0.0), attitude.get("pitch", 0.0), attitude.get("yaw", 0.0),
                sensor_to_device_rotation_xyzw=q_imuSensor_to_arkitDevice_xyzw
            )
            # 2. Convert to Rerun RDF camera orientation
            q_world_from_camera_final_xyzw = quaternion_multiply(q_world_from_arkitDevice_xyzw, q_arkitDevice_to_rerunCam_xyzw)
            
            # Use q_world_from_arkitDevice_xyzw directly
            # q_world_from_camera_final_xyzw = q_world_from_arkitDevice_xyzw # This was the previous line

            norm_q_world_camera_final = np.linalg.norm(q_world_from_camera_final_xyzw)
            if norm_q_world_camera_final > 1e-6:
                q_world_from_camera_final_xyzw_normalized = q_world_from_camera_final_xyzw / norm_q_world_camera_final
            else:
                q_world_from_camera_final_xyzw_normalized = np.array([0.0, 0.0, 0.0, 1.0]) # Default to identity if norm is zero

            # Determine translation: use from camera_poses.json if available (even if matrix was identity), else [0,0,0]
            translation_for_log = translation_from_pose if translation_from_pose is not None else [0.0, 0.0, 0.0]

            if np.isfinite(q_world_from_camera_final_xyzw_normalized).all() and np.isfinite(translation_for_log).all():
                rr.log(
                    base_camera_path,
                    rr.Transform3D(
                        rotation=rr.Quaternion(xyzw=q_world_from_camera_final_xyzw_normalized), # Rerun expects xyzw
                        translation=translation_for_log 
                    )
                )
                if i < 5 or (num_frames_to_log // 2 - 2 <= i < num_frames_to_log // 2 + 1) or i >= num_frames_to_log - 5:
                    print(f"DIAG_POSE_LOG: Frame {i}: Logged Transform3D from IMU orientation (RUB). Translation: {translation_for_log}")
            # camera_orientation_quat_for_imu_vectors = q_world_from_camera_final_xyzw_normalized # Store for IMU vector rotation
        else:
            # Case 3: No pose from JSON, no IMU data for this frame. Log identity? Or skip?
            # For now, camera pose won't be updated for this frame if this branch is hit.
            if i < 5:
                print(f"DIAG_CAM_TRANSFORM: Frame {i}: No pose data (JSON or IMU) to update camera transform.")

        # Log IMU scalar data (if available for this timestamp)
        if closest_imu_event:
            attitude = closest_imu_event.get("attitude", {})
            rotation = closest_imu_event.get("rotationRate", {})
            accel = closest_imu_event.get("userAcceleration", {})
            # gravity = closest_imu_event.get("gravity", {}) # Not currently logged as scalar

            # Extract raw values, defaulting to None if keys are missing
            rotation_x = rotation.get("x")
            rotation_y = rotation.get("y")
            rotation_z = rotation.get("z")
            accel_x = accel.get("x")
            accel_y = accel.get("y")
            accel_z = accel.get("z")
            attitude_roll = attitude.get("roll")
            attitude_pitch = attitude.get("pitch")
            attitude_yaw = attitude.get("yaw")

            values_for_check = [
                rotation_x, rotation_y, rotation_z,
                accel_x, accel_y, accel_z,
                attitude_roll, attitude_pitch, attitude_yaw
            ]
            
            cleaned_values = [0.0] * 9 # Initialize with Python floats
            all_values_originally_valid = True

            for val_idx, val in enumerate(values_for_check):
                val_to_assign = 0.0 # Default to Python float 0.0
                if val is None:
                    if i < 2 : print(f"DIAG_IMU_SCALARS_CLEAN: Value at index {val_idx} is None, replacing with 0.0.")
                    all_values_originally_valid = False
                    val_to_assign = 0.0
                elif not isinstance(val, (int, float, np.number)): # Check if it's a number type
                    if i < 2 : print(f"DIAG_IMU_SCALARS_CLEAN: Value '{val}' at index {val_idx} is not a number (type: {type(val)}), replacing with 0.0.")
                    all_values_originally_valid = False
                    val_to_assign = 0.0
                elif np.isnan(val) or np.isinf(val):
                    if i < 2 : print(f"DIAG_IMU_SCALARS_CLEAN: Value '{val}' at index {val_idx} is NaN or Inf, replacing with 0.0.")
                    all_values_originally_valid = False
                    val_to_assign = 0.0
                else: # It's a valid number
                    val_to_assign = val 
                
                cleaned_values[val_idx] = float(val_to_assign) # Ensure it's a Python float after cleaning

            imu_data_path = f"{session_id}/device/imu"
            
            # Explicitly cast to Python float when building the dictionary for rr.Scalars
            imu_data_to_log = {
                "angular_velocity_x": float(cleaned_values[0]),
                "angular_velocity_y": float(cleaned_values[1]),
                "angular_velocity_z": float(cleaned_values[2]),
                "acceleration_x": float(cleaned_values[3]),
                "acceleration_y": float(cleaned_values[4]),
                "acceleration_z": float(cleaned_values[5]),
                "attitude_roll": float(cleaned_values[6]),
                "attitude_pitch": float(cleaned_values[7]),
                "attitude_yaw": float(cleaned_values[8]),
            }

            if i < 5 or (num_frames_to_log // 2 - 2 <= i < num_frames_to_log // 2 + 1) or i >= num_frames_to_log - 5:
                if not all_values_originally_valid:
                    print(f"DIAG_IMU_PRE_CHECK_CLEANED: Frame {i}, IMU time {closest_imu_event['timestamp']:.3f}s. Some IMU scalar values were cleaned (None, NaN, Inf, or non-numeric).")
                else: # This is the equivalent of DIAG_AGGRESSIVE_CHECK_PASSED
                    print(f"DIAG_AGGRESSIVE_CHECK_PASSED: Frame {i}, IMU time {closest_imu_event['timestamp']:.3f}s. All 9 values for rr.Scalars appear valid. Proceeding to log individually.")
                
                # This print remains useful to see the whole dictionary that *would* have gone to rr.Scalars
                print(f"DIAG_PREPARED_IMU_DATA_DICT: Frame {i}, IMU time {closest_imu_event['timestamp']:.3f}s. Data: {imu_data_to_log}")
            
            try:
                # --- MODIFIED: Log each scalar individually ---
                for key, value in imu_data_to_log.items():
                    # This check should be redundant given prior cleaning and float casting, but for absolute safety:
                    if not isinstance(value, float):
                        print(f"DIAG_RR_LOG_SCALAR_INDIVIDUAL_TYPE_ERROR: Frame {i}, IMU time {closest_imu_event['timestamp']:.3f}s. Key '{key}' has non-float value '{value}' (type: {type(value)}) before individual log. Attempting to cast again.")
                        try:
                            value_to_log = float(value)
                        except (ValueError, TypeError) as cast_err:
                            print(f"DIAG_RR_LOG_SCALAR_INDIVIDUAL_CAST_FAIL: Frame {i}, IMU time {closest_imu_event['timestamp']:.3f}s. Could not cast key '{key}' value '{value}' to float: {cast_err}. Skipping this scalar.")
                            continue
                    else:
                        value_to_log = value

                    if i < 1 or (num_frames_to_log // 2 - 1 <= i < num_frames_to_log // 2 + 0) or i >= num_frames_to_log - 1: # Reduced verbosity
                         print(f"DIAG_ATTEMPTING_RR_LOG_SCALAR_INDIVIDUAL: Frame {i}, IMU time {closest_imu_event['timestamp']:.3f}s. Logging {key}={value_to_log} (type: {type(value_to_log)}) to {imu_data_path}/{key}")
                    
                    rr.log(
                        f"{imu_data_path}/{key}", # Log to a sub-path for each scalar
                        rr.Scalar(value_to_log)   # Use rr.Scalar for individual values
                    )
                
                if i < 5 or (num_frames_to_log // 2 - 2 <= i < num_frames_to_log // 2 + 1) or i >= num_frames_to_log - 5: # Keep this less verbose
                    print(f"DIAG_RR_LOG_SCALARS_INDIVIDUAL_SUCCESS: Frame {i}, IMU time {closest_imu_event['timestamp']:.3f}s. All scalars logged individually.")

            except Exception as e_log_individual:
                # This top-level exception for the loop is less likely to be hit if individual logging fails,
                # but good to have. The specific error would likely be from rr.Scalar() itself.
                print(f"DIAG_RR_LOG_SCALARS_INDIVIDUAL_LOOP_EXCEPTION: Frame {i}, IMU time {closest_imu_event['timestamp']:.3f}s. Exception during individual rr.log(rr.Scalar) loop: {e_log_individual}")
                if 'key' in locals() and 'value_to_log' in locals(): # locals() might not have them if error is early
                    print(f"DIAG_RR_LOG_SCALARS_INDIVIDUAL_EXCEPTION_DETAILS: Last attempted Key='{key}', Value='{value_to_log}', Type={type(value_to_log)}")
        else: # Corresponds to 'if closest_imu_event:'
            if i < 5 or (num_frames_to_log // 2 - 2 <= i < num_frames_to_log // 2 + 1) or i >= num_frames_to_log - 5:
                print(f"DIAG_IMU_SKIP: Frame {i}: No closest IMU event found for video timestamp {current_time_sec:.3f}s. Skipping IMU-related logging for this frame.")

        # Log Video Frame (if available and within bounds)
        if video_frames and i < len(video_frames):
            # Log the video frame in its original orientation (no vertical flip)
            video_frame = video_frames[i]
            rr.log(f"{base_camera_path}/rgb", rr.Image(video_frame))

        # Log Depth Frame if available
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
        help="The ID of the scan session to visualize (e.g., Scan-20250521-0200). If not provided, the latest session will be used."
    )
    args = parser.parse_args()

    session_to_visualize = args.session_id
    
    if session_to_visualize is None:
        print("No session_id provided, attempting to find the latest session...")
        scan_folders = find_scan_folders()
        if scan_folders:
            session_to_visualize = scan_folders[0].name # Get the newest session
            print(f"Using latest session: {session_to_visualize}")
        else:
            print("No scan sessions found in the data directory. Please specify a session_id or ensure data exists.")
            return
    
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
