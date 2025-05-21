import os
import json
import struct
from pathlib import Path
import rerun as rr
import glob
import numpy as np

# Path to downloaded data
DATA_DIR = Path(os.path.dirname(os.path.abspath(__file__))) / "../data"

def find_scan_folders():
    """Find all Scan-* folders in the local data directory"""
    if not DATA_DIR.exists():
        print(f"Data directory {DATA_DIR} doesn't exist.")
        print("Please run sync_supabase_bucket.py first to download data.")
        return []
        
    # Look for Scan-* folders
    scan_folders = []
    for item in DATA_DIR.glob("Scan-*"):
        if item.is_dir():
            scan_folders.append(item)
            
    return scan_folders

def parse_imu_bin(file_path):
    """Parse an IMU binary file into a list of events"""
    events = []
    
    try:
        with open(file_path, "rb") as f:
            data = f.read()
        
        # The format of the binary file is a sequence of records:
        # timestamp (float), roll (float), pitch (float), yaw (float),
        # rotationRate.x (float), rotationRate.y (float), rotationRate.z (float), 
        # userAcceleration.x (float), userAcceleration.y (float), userAcceleration.z (float)
        # Each float is 4 bytes, so each record is 40 bytes (10 floats)
        record_size = 4 * 10  # 10 floats, 4 bytes each
        
        for i in range(0, len(data), record_size):
            if i + record_size <= len(data):
                record = struct.unpack('10f', data[i:i+record_size])
                t, roll, pitch, yaw, rx, ry, rz, ax, ay, az = record
                events.append({
                    "timestamp": t,
                    "attitude": {"roll": roll, "pitch": pitch, "yaw": yaw},
                    "rotationRate": {"x": rx, "y": ry, "z": rz},
                    "userAcceleration": {"x": ax, "y": ay, "z": az}
                })
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

def visualize_in_rerun(all_sessions):
    """Visualize IMU data in rerun.io"""
    print("Visualizing data in rerun.io...")
    
    # Initialize rerun
    app_name = "roboclip-replay"
    rr.init(app_name)
    rr.spawn()
    
    for session_id, session_events in all_sessions.items():
        print(f"Visualizing session: {session_id} ({len(session_events)} events)")
        
        # Sort events by timestamp
        session_events.sort(key=lambda e: e["timestamp"])
        
        # Log events to rerun
        for i, event in enumerate(session_events):
            # Set time at this frame
            rr.set_time("frame", i)
            
            # Extract IMU data
            attitude = event["attitude"]
            rotation = event["rotationRate"]
            accel = event["userAcceleration"]
            
            # Log attitude as 3D transform
            rr.log(f"{session_id}/attitude", 
                  rr.Transform3D(
                      rotation=rr.Quaternion.from_euler_angles(
                          roll=attitude["roll"], 
                          pitch=attitude["pitch"],
                          yaw=attitude["yaw"]
                      )
                  ))
            
            # Log angular velocity
            rr.log(f"{session_id}/angular_velocity", 
                  rr.Vector3D(
                      x=rotation["x"],
                      y=rotation["y"],
                      z=rotation["z"]
                  ))
            
            # Log acceleration
            rr.log(f"{session_id}/acceleration", 
                  rr.Vector3D(
                      x=accel["x"],
                      y=accel["y"],
                      z=accel["z"]
                  ))
            
            # Log some stats as timeseries
            rr.log(f"{session_id}/stats/roll", rr.Scalar(attitude["roll"]))
            rr.log(f"{session_id}/stats/pitch", rr.Scalar(attitude["pitch"]))
            rr.log(f"{session_id}/stats/yaw", rr.Scalar(attitude["yaw"]))
            
            # Add a 3D coordinate system to visualize orientation
            if i % 10 == 0:  # Only add every 10th frame to avoid visual clutter
                rr.log(f"{session_id}/coord_system", 
                      rr.Arrows3D(
                          origins=[[0.0, 0.0, 0.0]],
                          vectors=[[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
                          colors=[[255, 0, 0], [0, 255, 0], [0, 0, 255]]
                      ),
                      parent=f"{session_id}/attitude")
    
    print(f"Visualized {len(all_sessions)} sessions in rerun.io")
    print("The viewer should now be open. If not, you can run 'rerun' from the command line.")

def main():
    scan_folders = find_scan_folders()
    print(f"Found {len(scan_folders)} scan folders")
    
    if not scan_folders:
        return
    
    all_sessions = {}
    
    # Process each scan folder
    for folder in scan_folders:
        session_id = folder.name
        print(f"Processing session: {session_id}")
        
        # Find the IMU file
        imu_file = locate_imu_file(folder)
        
        if imu_file:
            print(f"Parsing IMU data from {imu_file}")
            events = parse_imu_bin(imu_file)
            print(f"Extracted {len(events)} IMU events")
            
            # Add events to all sessions
            if events:
                all_sessions[session_id] = events
        else:
            print(f"No IMU file found in {folder}")
    
    if all_sessions:
        # Visualize all sessions in rerun
        visualize_in_rerun(all_sessions)
    else:
        print("No IMU events found in any scan folder")

if __name__ == "__main__":
    main()
