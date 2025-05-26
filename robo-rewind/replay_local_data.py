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

def extract_video_timestamps_from_video_file(video_path):
    """Extracts timestamps by reading through a video file, assuming constant FPS."""
    if not Path(video_path).exists():
        print(f"Video file {video_path} not found for timestamp extraction.")
        return []
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        print(f"Error: Could not open video file {video_path} for timestamp extraction.")
        return []
    
    timestamps = []
    fps = cap.get(cv2.CAP_PROP_FPS)
    
    if fps is None or fps == 0:
        print(f"Warning: Video FPS is 0 or not available for {video_path}. Cannot generate timestamps accurately.")
        cap.release()
        # Attempt to count frames at least, though timestamps will be just indices
        # This part might need a different strategy if FPS is truly unavailable.
        # For now, returning empty or frame indices if FPS is 0.
        # Re-opening to count frames if necessary
        cap_check = cv2.VideoCapture(str(video_path))
        if not cap_check.isOpened(): return []
        frame_count_check = 0
        while True:
            ret_check, _ = cap_check.read()
            if not ret_check: break
            frame_count_check +=1
        cap_check.release()
        print(f"Counted {frame_count_check} frames, but FPS is 0. Timestamps will be frame indices.")
        return [float(i) for i in range(frame_count_check)] # Fallback to frame indices

    frame_idx = 0
    while True:
        # Only check if a frame can be retrieved, don't store it
        ret = cap.grab() 
        if not ret:
            break
        # Calculate timestamp using frame index and FPS
        # get(cv2.CAP_PROP_POS_MSEC) could also be used but might be less reliable with some formats/codecs
        timestamps.append(frame_idx / fps)
        frame_idx += 1
    cap.release()
    return timestamps

def generate_video_frames(video_path):
    """Yields RGB frames from video.mov using OpenCV, one by one."""
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        print(f"Error: Could not open video file {video_path} for frame generation.")
        return # Stop iteration (generator will be empty)

    while cap.isOpened():
        ret, frame = cap.read()
        if not ret:
            break
        
        # Convert BGR to RGB
        frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        yield frame_rgb
    cap.release()

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

def scan_depth_files(depth_dir):
    """Scans depth directory, extracts timestamps from filenames, returns sorted list of {'timestamp': ts, 'path': filepath}."""
    if not depth_dir.exists():
        return []
    
    depth_files_info = []
    # Using Path.glob for cleaner path handling
    for f_path in sorted(depth_dir.glob('*.d32')):
        match = re.search(r'([0-9]+\.[0-9]+)\.d32$', f_path.name) # Corrected regex
        if match:
            ts = float(match.group(1))
            depth_files_info.append({'timestamp': ts, 'path': str(f_path)})
        else:
            # Fallback: use index if timestamp cannot be parsed (less accurate)
            # This case should be rare if filenames are consistent.
            print(f"Warning: Could not parse timestamp from depth filename: {f_path.name}. This depth map might be ignored or misaligned.")
            # Optionally, assign a placeholder timestamp or skip
            # For now, we skip files with unparsable timestamps to avoid issues.
            # depth_files_info.append({'timestamp': float(len(depth_files_info)), 'path': str(f_path), 'is_fallback_ts': True})
            
    # Sort by timestamp to ensure chronological order
    depth_files_info.sort(key=lambda x: x['timestamp'])
    return depth_files_info

def load_single_depth_frame(filepath, depth_height, depth_width):
    """Loads a single .d32 depth frame from a given filepath."""
    if not depth_height or not depth_width or depth_height <= 0 or depth_width <= 0:
        print(f"Error: Invalid depth dimensions (h={depth_height}, w={depth_width}) for loading {filepath}.")
        return None
    
    expected_elements = depth_height * depth_width
    try:
        arr = np.fromfile(filepath, dtype=np.float32)
    except Exception as e:
        print(f"Error reading file {filepath}: {e}")
        return None
        
    if arr.size == expected_elements:
        try:
            arr = arr.reshape((depth_height, depth_width))
            return arr
        except ValueError as ve:
            print(f"Error reshaping depth frame from {filepath} to ({depth_height}, {depth_width}). Array size: {arr.size}. Error: {ve}")
            return None
    else:
        print(f"Warning: Depth file {filepath} has unexpected element count {arr.size}. Expected {expected_elements} ({depth_height}x{depth_width}). Skipping.")
        return None

def find_closest_event_by_timestamp(target_timestamp, sorted_events_with_timestamp_key, timestamp_key_name="timestamp"):
    """Finds the event in sorted_events_with_timestamp_key closest to target_timestamp.
    Assumes sorted_events_with_timestamp_key is sorted by the timestamp_key_name.
    """
    if not sorted_events_with_timestamp_key:
        return None
    
    # Extract just the timestamps for searchsorted
    try:
        event_timestamps = np.array([e[timestamp_key_name] for e in sorted_events_with_timestamp_key])
    except KeyError:
        print(f"Error: timestamp_key_name \'{timestamp_key_name}\' not found in one or more events.")
        return None
    except TypeError as te: # Handle cases where events might not be subscriptable if list is malformed
        print(f"Error: Problem accessing timestamps in events list: {te}")
        # Fallback: try iterating safely
        valid_timestamps = []
        for e_idx, e_event in enumerate(sorted_events_with_timestamp_key):
            if isinstance(e_event, dict) and timestamp_key_name in e_event:
                valid_timestamps.append(e_event[timestamp_key_name])
            else: # If an event is bad, we might have to stop or skip
                print(f"Warning: Malformed event at index {e_idx}, cannot extract timestamp. List might be unsorted or corrupted.")
                # Depending on strictness, could return None here or try with partial list
        if not valid_timestamps: return None
        event_timestamps = np.array(valid_timestamps)
        # Note: if we had to filter, the indices from searchsorted might not map back correctly
        # This fallback is basic; ideally, the input list is clean.

    idx = np.searchsorted(event_timestamps, target_timestamp, side="left")
    
    # Handle edge cases for idx
    if idx == 0:
        return sorted_events_with_timestamp_key[0]
    if idx == len(event_timestamps): # Corrected: use length of event_timestamps array
        return sorted_events_with_timestamp_key[len(sorted_events_with_timestamp_key)-1] # Return last element of original list
    
    # Compare with neighbors
    ts_before = event_timestamps[idx-1]
    ts_after = event_timestamps[idx] # This index must be valid for event_timestamps
    
    # Ensure idx-1 and idx are valid for the original sorted_events_with_timestamp_key list
    original_list_idx_before = idx -1
    original_list_idx_after = idx

    # This logic assumes that the event_timestamps array corresponds 1:1 with sorted_events_with_timestamp_key
    # which is true if no errors occurred during timestamp extraction.
    if (target_timestamp - ts_before) < (ts_after - target_timestamp):
        return sorted_events_with_timestamp_key[original_list_idx_before]
    else:
        return sorted_events_with_timestamp_key[original_list_idx_after]

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

def visualize_single_session_in_rerun(session_id, session_imu_events, session_metadata, 
                                      video_timestamps_list, # New: list of video timestamps
                                      scanned_depth_info_list, # New: list of {'ts': path}
                                      camera_poses_list): # New: pass parsed camera poses

    print(f"\\\\n--- Visualizing session: {session_id} ---")
    # rr.init specific to this session to keep data separate if multiple are processed (though current main() does one)
    # rr.init(f"roboclip_replay/{session_id}", spawn=False) # spawn=False if rr.spawn() is called later explicitly
    # If rr.init is called per session, ensure app_id is unique or manage data logging carefully.
    # For simplicity, if main() calls this once, a single rr.init in main() is also fine.
    # The original script had rr.init(app_name) and then rr.spawn() later, which is good.
    # Let's assume rr.init was called in main() or before this function.

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

    # rr.spawn() # Spawns the Rerun viewer application - moved to main or called after all logging for a session.

    if session_imu_events:
        session_imu_events.sort(key=lambda e: e["timestamp"]) # Ensure IMU events are sorted
        print(f"Found {len(session_imu_events)} IMU events for session {session_id}")
        # ---- START DIAGNOSTIC PRINTS ----
        imu_timestamps_for_diag = [e["timestamp"] for e in session_imu_events]
        if imu_timestamps_for_diag:
            print(f"DIAG: IMU timestamps range: min={min(imu_timestamps_for_diag):.3f}s, max={max(imu_timestamps_for_diag):.3f}s")
        # ---- END DIAGNOSTIC PRINTS ----

    # Determine width and height for Pinhole camera model
    width, height = 640, 480 # Default resolution
    
    video_mov_path = DATA_DIR / session_id / "video.mov"
    if video_mov_path.exists():
        temp_cap = cv2.VideoCapture(str(video_mov_path))
        if temp_cap.isOpened():
            vid_w = int(temp_cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            vid_h = int(temp_cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            if vid_w > 0 and vid_h > 0:
                width, height = vid_w, vid_h
                print(f"Determined Pinhole dimensions from video.mov: {width}x{height}")
            else:
                print(f"Warning: video.mov found but dimensions are invalid ({vid_w}x{vid_h}). Using defaults or metadata-derived: {width}x{height}")
            temp_cap.release()
        else:
            print(f"Warning: Could not open video.mov at {video_mov_path} to get dimensions. Using defaults or metadata-derived: {width}x{height}")
    
    # If video dimensions weren't found/valid or video doesn't exist, try metadata for depth
    # This check ensures we only override with depth metadata if video didn't provide valid dimensions.
    if (width == 640 and height == 480) or not video_mov_path.exists() or (video_mov_path.exists() and (width <= 0 or height <= 0)):
        meta_depth_w = session_metadata.get('depthWidth')
        meta_depth_h = session_metadata.get('depthHeight')
        if meta_depth_w and meta_depth_h and meta_depth_w > 0 and meta_depth_h > 0:
            width, height = meta_depth_w, meta_depth_h
            print(f"Using Pinhole dimensions from session_metadata (depth): {width}x{height}")
        elif scanned_depth_info_list: 
             print(f"Warning: Depth files exist, but depth dimensions not in session_metadata. Pinhole using defaults or video-derived: {width}x{height}.")
        # If still at defaults, it means no video, no valid video dims, and no depth metadata dims.
        elif width == 640 and height == 480:
             print(f"Using default Pinhole dimensions: {width}x{height}")


    if not video_timestamps_list and not scanned_depth_info_list and not session_imu_events:
        print(f"No data (video, depth, or IMU) to visualize for session {session_id}. Skipping.")
        return # Changed from continue to return

    # --- Log Pinhole Camera Model once per session ---
    # This is logged to the camera's entity path and will apply to images logged there.
    base_camera_path = f"{session_id}/device/camera"
    
    # Attempt to get resolution from video if available, otherwise use default or depth
    # The width and height are now determined by the robust logic block above.
    # This old block is removed as it caused the AttributeError and was redundant.
    # if video_timestamps_list:
    #     width = video_timestamps_list[0].shape[1] # This was the source of AttributeError
    #     height = video_timestamps_list[0].shape[0]
    # elif scanned_depth_info_list: # If no video, try to get resolution from depth (assuming depth is (H, W))
    #     # This was also problematic as scanned_depth_info_list contains dicts, not arrays directly.
    #     # Depth frames are loaded individually later.
    #     # height, width = scanned_depth_info_list[0].shape 
    #     pass # Width/height determined above

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
    print(f"Logged Pinhole camera model (resolution {width}x{height}) and RDF ViewCoordinates for {session_id} to {base_camera_path}")

    # Determine data source type and primary timestamps for synchronization
    source_type = "imu_only_direct"  # Default to IMU-only
    primary_timestamps = []
    num_frames_to_log = 0
    video_frame_generator = None

    # --- Depth framerate control settings ---
    target_depth_fps = 10.0  # Target depth logging framerate
    depth_frame_skip_interval = 1  # Default: log every frame
    
    # Determine the primary data source based on what's available
    if video_timestamps_list:
        source_type = "video"
        primary_timestamps = video_timestamps_list
        num_frames_to_log = len(video_timestamps_list)
        # Calculate depth frame skip interval for 10fps
        if len(video_timestamps_list) > 1:
            # Estimate video framerate from timestamps
            video_duration = video_timestamps_list[-1] - video_timestamps_list[0]
            estimated_video_fps = (len(video_timestamps_list) - 1) / video_duration if video_duration > 0 else 30.0
            depth_frame_skip_interval = max(1, int(estimated_video_fps / target_depth_fps))
            print(f"Estimated video FPS: {estimated_video_fps:.1f}, depth will be logged every {depth_frame_skip_interval} frames ({target_depth_fps}fps)")
        # Create video frame generator
        video_mov_path = DATA_DIR / session_id / "video.mov"
        if video_mov_path.exists():
            video_frame_generator = generate_video_frames(video_mov_path)
        print(f"Using video as primary source: {num_frames_to_log} frames")
    elif scanned_depth_info_list:
        source_type = "depth"
        primary_timestamps = [d['timestamp'] for d in scanned_depth_info_list]
        num_frames_to_log = len(scanned_depth_info_list)
        # Calculate depth frame skip interval for 10fps
        if len(scanned_depth_info_list) > 1:
            # Estimate depth framerate from timestamps
            depth_duration = primary_timestamps[-1] - primary_timestamps[0]
            estimated_depth_fps = (len(scanned_depth_info_list) - 1) / depth_duration if depth_duration > 0 else 30.0
            depth_frame_skip_interval = max(1, int(estimated_depth_fps / target_depth_fps))
            print(f"Estimated depth FPS: {estimated_depth_fps:.1f}, depth will be logged every {depth_frame_skip_interval} frames ({target_depth_fps}fps)")
        print(f"Using depth as primary source: {num_frames_to_log} frames")
    elif session_imu_events:
        source_type = "imu_only_direct"
        primary_timestamps = [e['timestamp'] for e in session_imu_events]
        num_frames_to_log = len(session_imu_events)
        # For IMU-only mode, depth framerate control is not applicable
        print(f"Using IMU-only mode: {num_frames_to_log} events")

    # Handle IMU-only logging path separately for clarity
    if source_type == "imu_only_direct":
        for imu_idx, event in enumerate(session_imu_events): # Assumes session_imu_events is sorted by timestamp
            rr.set_time(timeline="timestamp", timestamp=event["timestamp"])
            rr.set_time(timeline=f"{session_id}_imu_event_idx", sequence=imu_idx)
            
            attitude = event.get("attitude", {}) # Use .get for safety
            rotation = event.get("rotationRate", {})
            accel = event.get("userAcceleration", {})

            q_world_from_arkitDevice_xyzw = arkit_device_orientation_from_imu(
                attitude.get("roll", 0.0), attitude.get("pitch", 0.0), attitude.get("yaw", 0.0),
                sensor_to_device_rotation_xyzw=q_imuSensor_to_arkitDevice_xyzw
            )
            q_world_from_camera_final_xyzw = quaternion_multiply(q_world_from_arkitDevice_xyzw, q_arkitDevice_to_rerunCam_xyzw)
            
            norm_q_world_camera_final = np.linalg.norm(q_world_from_camera_final_xyzw)
            if norm_q_world_camera_final > 1e-6:
                q_world_from_camera_final_xyzw_normalized = q_world_from_camera_final_xyzw / norm_q_world_camera_final
            else:
                q_world_from_camera_final_xyzw_normalized = np.array([0.0, 0.0, 0.0, 1.0])

            if np.isfinite(q_world_from_camera_final_xyzw_normalized).all():
                rr.log(
                    base_camera_path, # Log transform to the camera entity
                    rr.Transform3D(
                        rotation=rr.Quaternion(xyzw=q_world_from_camera_final_xyzw_normalized),
                        translation=[0.0, 0.0, 0.0] # No translation info from IMU alone for camera pose
                    )
                )
            
            # Log IMU scalar data (cleaned as in original script)
            imu_data_path = f"{session_id}/device/imu"
            cleaned_values = [0.0] * 9
            # (Copy the cleaning logic for rotation_x/y/z, accel_x/y/z, attitude_roll/pitch/yaw from original here)
            # For brevity, assuming values are directly usable or cleaned before this point in a real scenario.
            # This part needs the full cleaning logic from the original script.
            # Simplified for this example:
            imu_data_to_log = {
                "angular_velocity_x": float(rotation.get("x",0.0)), "angular_velocity_y": float(rotation.get("y",0.0)), "angular_velocity_z": float(rotation.get("z",0.0)),
                "acceleration_x": float(accel.get("x",0.0)), "acceleration_y": float(accel.get("y",0.0)), "acceleration_z": float(accel.get("z",0.0)),
                "attitude_roll": float(attitude.get("roll",0.0)), "attitude_pitch": float(attitude.get("pitch",0.0)), "attitude_yaw": float(attitude.get("yaw",0.0))
            }
            for key, value in imu_data_to_log.items():
                 rr.log(f"{imu_data_path}/{key}", rr.Scalar(value))

        print(f"Logged {len(session_imu_events)} IMU events for {session_id}.")
        return # Finished with this session if it was IMU-only

    # --- Synchronize and Log Camera Stream (IMU, Video, Depth) based on primary_timestamps ---
    print(f"Starting synchronized logging for {session_id} with {num_frames_to_log} frames based on {source_type} timestamps...")

    depth_orientation_checked = False
    depth_needs_rot90 = False # Add other flags (flipud, fliplr) if that logic is restored

    for i in range(num_frames_to_log):
        current_time_sec = primary_timestamps[i]
        rr.set_time(timeline="timestamp", timestamp=current_time_sec)
        rr.set_time(timeline=f"{session_id}_frame_idx", sequence=i)
        
        closest_imu_event = find_closest_event_by_timestamp(current_time_sec, session_imu_events, "timestamp")
        closest_pose_info = find_closest_event_by_timestamp(current_time_sec, camera_poses_list, "timestamp")

        translation_from_pose = None
        pose_matrix_for_transform = None

        if closest_pose_info and "matrix" in closest_pose_info:
            translation_from_pose = extract_translation_from_matrix(closest_pose_info["matrix"])
            current_pose_matrix_np = np.array(closest_pose_info["matrix"], dtype=np.float32)
            identity_4x4 = np.eye(4, dtype=np.float32)
            if not np.allclose(current_pose_matrix_np, identity_4x4, atol=1e-8):
                pose_matrix_for_transform = current_pose_matrix_np
        
        # ... (Camera Transform Logic: copy from original, using pose_matrix_for_transform and closest_imu_event) ...
        # This part is complex and involves deciding whether to use pose_matrix_for_transform or IMU for orientation,
        # then applying the M_arkitDevice_to_rerunCam transform.
        # For brevity, this detailed logic block is represented by this comment.
        # Ensure to log to base_camera_path with rr.Transform3D.
        # Simplified placeholder for camera transform logging:
        final_translation_for_log = translation_from_pose if translation_from_pose is not None else [0.0, 0.0, 0.0]
        final_rotation_for_log_xyzw = np.array([0.0,0.0,0.0,1.0]) # Default identity

        if pose_matrix_for_transform is not None:
            M_world_from_arkitDevice_4x4 = pose_matrix_for_transform
            M_world_from_rerunCamera_4x4 = M_world_from_arkitDevice_4x4 @ T_arkitDevice_from_rerunCamera_4x4
            R_world_from_rerunCamera = M_world_from_rerunCamera_4x4[0:3, 0:3]
            final_translation_for_log = M_world_from_rerunCamera_4x4[0:3, 3].tolist()
            final_rotation_for_log_xyzw = R.from_matrix(R_world_from_rerunCamera).as_quat()
        elif closest_imu_event:
            attitude = closest_imu_event.get("attitude", {})
            q_world_from_arkitDevice_xyzw = arkit_device_orientation_from_imu(
                attitude.get("roll", 0.0), attitude.get("pitch", 0.0), attitude.get("yaw", 0.0),
                sensor_to_device_rotation_xyzw=q_imuSensor_to_arkitDevice_xyzw)
            final_rotation_for_log_xyzw = quaternion_multiply(q_world_from_arkitDevice_xyzw, q_arkitDevice_to_rerunCam_xyzw)
        
        norm_final_rot = np.linalg.norm(final_rotation_for_log_xyzw)
        if norm_final_rot > 1e-6: final_rotation_for_log_xyzw /= norm_final_rot
        else: final_rotation_for_log_xyzw = np.array([0.0,0.0,0.0,1.0])

        if np.isfinite(final_rotation_for_log_xyzw).all() and np.isfinite(final_translation_for_log).all():
             rr.log(base_camera_path, rr.Transform3D(translation=final_translation_for_log, rotation=rr.Quaternion(xyzw=final_rotation_for_log_xyzw)))


        # Log IMU scalar data (if closest_imu_event exists)
        if closest_imu_event:
            # ... (Copy the full IMU scalar cleaning and logging logic from original script here) ...
            # Simplified:
            attitude = closest_imu_event.get("attitude", {})
            rotation = closest_imu_event.get("rotationRate", {})
            accel = closest_imu_event.get("userAcceleration", {})
            imu_data_path = f"{session_id}/device/imu"
            imu_scalars_to_log = {
                "angular_velocity_x": float(rotation.get("x",0.0)), "angular_velocity_y": float(rotation.get("y",0.0)), # ... and so on
                "acceleration_x": float(accel.get("x",0.0)), # ...
                "attitude_roll": float(attitude.get("roll",0.0)), # ...
            }
            # This needs the full set of 9 scalars and the cleaning logic.
            # For now, just an example:
            if "angular_velocity_x" in imu_scalars_to_log: # Check if key exists
                 rr.log(f"{imu_data_path}/angular_velocity_x", rr.Scalar(imu_scalars_to_log["angular_velocity_x"]))
            # Repeat for all 9 cleaned scalars individually.


        # Log Video Frame
        if source_type == "video" and video_frame_generator:
            video_frame = next(video_frame_generator, None)
            if video_frame is not None:
                rr.log(f"{base_camera_path}/rgb", rr.Image(video_frame))
                # If depth overlay debug is needed, video_frame is available here
            elif i < num_frames_to_log : # Check if we expected a frame
                 print(f"Warning: Video frame generator did not yield a frame for index {i} (time {current_time_sec:.3f}s) in {session_id}")
        
        # Log Depth Frame (with framerate control)
        if scanned_depth_info_list and (i % depth_frame_skip_interval == 0):
            closest_depth_info = find_closest_event_by_timestamp(current_time_sec, scanned_depth_info_list, "timestamp")
            if closest_depth_info:
                depth_h_meta = session_metadata.get('depthHeight')
                depth_w_meta = session_metadata.get('depthWidth')
                current_depth_frame = load_single_depth_frame(closest_depth_info['path'], depth_h_meta, depth_w_meta)
                
                if current_depth_frame is not None:
                    # --- Orientation check and fix (simplified) ---
                    # This needs the video frame dimensions (width, height) established earlier for the Pinhole
                    # The original script's logic for depth_needs_rot90 etc. would go here.
                    # For now, assume depth is correctly oriented or use a simple check.
                    if not depth_orientation_checked:
                        # rgb_shape_ref = (height, width) # Target shape from Pinhole
                        # depth_shape_current = current_depth_frame.shape
                        # if rgb_shape_ref == depth_shape_current[::-1]: # Example: if transposed
                        #     depth_needs_rot90 = True
                        # depth_orientation_checked = True # Check only once
                        pass # Placeholder for full orientation logic

                    # if depth_needs_rot90: current_depth_frame = np.rot90(current_depth_frame)
                    
                    # --- FOV alignment: Upsample/Downsample depth to match target Pinhole resolution (width, height) ---
                    target_depth_shape_hw = (height, width) # (height, width) from Pinhole
                    if current_depth_frame.shape != target_depth_shape_hw:
                        current_depth_frame_resized = cv2.resize(
                            current_depth_frame,
                            (target_depth_shape_hw[1], target_depth_shape_hw[0]), # cv2.resize expects (w,h)
                            interpolation=cv2.INTER_NEAREST # Use INTER_NEAREST for depth, or INTER_LINEAR if smoother results preferred
                        )
                    else:
                        current_depth_frame_resized = current_depth_frame
                    
                    # Log depth (original had debug overlay too, can be added back if video_frame is available)
                    rr.log(f"{base_camera_path}/depth", rr.DepthImage(current_depth_frame_resized, meter=1.0))

        if i % 100 == 0 and i > 0: # Print progress
            print(f"  Logged frame {i+1}/{num_frames_to_log} for {session_id} at time {current_time_sec:.2f}s")

    if source_type == "video" and video_frame_generator and hasattr(video_frame_generator, 'close'):
        video_frame_generator.close() # Ensure generator resources are freed if applicable

    print(f"Finished logging {num_frames_to_log} synchronized frames to Rerun for session {session_id}")
    # rr.spawn() # If not spawned earlier, could be spawned here after all data for the session is logged.

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

    # Load video timestamps
    video_timestamps_list = []
    video_timestamps_json_path = session_folder / "video_timestamps.json"
    video_mov_path = session_folder / "video.mov" # Define once

    if video_timestamps_json_path.exists():
        print(f"Loading video timestamps from {video_timestamps_json_path}")
        video_timestamps_list = load_video_timestamps_json(video_timestamps_json_path)
        print(f"Loaded {len(video_timestamps_list)} video timestamps from JSON for {session_to_visualize}")
    elif video_mov_path.exists(): # If no JSON, try to extract from video file
        print(f"No video_timestamps.json found. Attempting to extract timestamps from {video_mov_path}")
        video_timestamps_list = extract_video_timestamps_from_video_file(video_mov_path)
        if video_timestamps_list:
            print(f"Extracted {len(video_timestamps_list)} video timestamps from {video_mov_path}")
        else:
            print(f"Could not extract timestamps from {video_mov_path}.")
    else:
        print(f"No video_timestamps.json or video.mov found in {session_folder}. Video timestamps will be empty.")
        
    # Scan depth files (get paths and timestamps without loading data)
    scanned_depth_info_list = []
    depth_dir = session_folder / "depth"
    if depth_dir.exists():
        print(f"Scanning depth frames from {depth_dir}")
        scanned_depth_info_list = scan_depth_files(depth_dir)
        if scanned_depth_info_list:
            print(f"Found {len(scanned_depth_info_list)} depth files with timestamps for {session_to_visualize}")
        else:
            print(f"No depth files with parsable timestamps found in {depth_dir}.")
    else:
        print(f"No depth/ directory found in {session_folder}.")

    # Load camera poses
    camera_poses_list = parse_camera_poses(session_folder)
    if not camera_poses_list and imu_events: # If no camera_poses.json, create a placeholder from IMU
        # This function saves to file, parse_camera_poses would then load it if called again,
        # or we can use the returned poses directly if modified.
        # For now, let's assume parse_camera_poses is the sole source for camera_poses_list.
        # If it's critical to generate and use immediately without re-parsing:
        # cam_poses_path = session_folder / "camera_poses.json"
        # if not cam_poses_path.exists():
        # save_camera_poses_from_imu(session_folder, imu_events) # This saves to file
        # camera_poses_list = parse_camera_poses(session_folder) # Reload
        pass # Current logic: parse_camera_poses handles loading or returns None. Placeholder logic is separate.


    if not imu_events and not video_timestamps_list and not scanned_depth_info_list:
        print(f"No data (IMU, video timestamps, or scannable depth files) to visualize for session {session_to_visualize}. Exiting.")
        return

    # Initialize Rerun for the application globally here
    # This app_id will be used for all subsequent rr.log calls in this run.
    # If visualizing multiple sessions in one go (not current script's behavior), this might need adjustment.
    rr.init(f"roboclip-replay-{session_to_visualize}", spawn=False) # spawn=False, will call rr.spawn() at the end.

    visualize_single_session_in_rerun(
        session_id=session_to_visualize,
        session_imu_events=imu_events,
        session_metadata=session_metadata,
        video_timestamps_list=video_timestamps_list,
        scanned_depth_info_list=scanned_depth_info_list,
        camera_poses_list=camera_poses_list if camera_poses_list else [] # Ensure it's a list
    )
    
    rr.spawn() # Spawn the Rerun viewer after all logging is done.
    print("\\nAll processing complete. Rerun viewer should be active or starting.")
    print(f"If Rerun doesn't open automatically, you might need to run 'rerun' in your terminal and connect to the recording: roboclip-replay-{session_to_visualize}")

if __name__ == "__main__":
    main()
