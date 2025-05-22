import os
import sys
import requests
import json
import time
import shutil
from pathlib import Path
from supabase import create_client, Client
from concurrent.futures import ThreadPoolExecutor, as_completed

# Ensure the script is running in a virtual environment
if not hasattr(sys, 'real_prefix') and not (hasattr(sys, 'base_prefix') and sys.base_prefix != sys.prefix):
    print("Error: This script must be run within a virtual environment.")
    sys.exit(1)

SUPABASE_URL = "https://rfprjaeyqomuvzempixf.supabase.co"
SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJmcHJqYWV5cW9tdXZ6ZW1waXhmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDc0NzM4NDAsImV4cCI6MjA2MzA0OTg0MH0.ODNn6Sh8MQvTwEkcUPT3tmVhehgTgEU51cWthou8XsM"
BUCKET = "roboclip-recordings"

# Initialize Supabase client
supabase: Client = create_client(SUPABASE_URL, SUPABASE_ANON_KEY)

# Path to store downloaded data
DATA_DIR = Path(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))) / "data"
METADATA_FILE = DATA_DIR / "bucket_metadata.json"

def setup_data_dir():
    """Create data directory if it doesn't exist"""
    DATA_DIR.mkdir(exist_ok=True)
    print(f"Data directory: {DATA_DIR}")

def list_bucket_files(prefix=""):
    """Recursively list all files in the bucket using Supabase client"""
    all_files = []
    try:
        response = supabase.storage.from_(BUCKET).list(
            path=prefix,
            options={"limit": 1000, "offset": 0}
        )
        for item in response:
            # If 'metadata' is present, it's a file; otherwise, it's a folder
            if item.get("metadata") is not None:
                file_path = f"{prefix}/{item['name']}" if prefix else item['name']
                all_files.append({"name": file_path})
            else:
                folder_prefix = f"{prefix}/{item['name']}" if prefix else item['name']
                all_files.extend(list_bucket_files(folder_prefix))
        return all_files
    except Exception as e:
        print(f"Error listing files: {e}")
        return []

def download_file(path, out_path):
    """Download a file from Supabase Storage using Supabase client"""
    try:
        response = supabase.storage.from_(BUCKET).download(path)
        # Ensure directory exists
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        with open(out_path, "wb") as f:
            f.write(response)
        print(f"Successfully downloaded: {path}")
        return True
    except Exception as e:
        print(f"Failed to download {path}: {e}")
        return False

def mirror_bucket():
    """Mirror the entire bucket structure locally"""
    print(f"Mirroring bucket {BUCKET} to {DATA_DIR}...")
    
    # List all files in the bucket
    all_files = list_bucket_files()
    total_files = len(all_files)
    print(f"Found {total_files} files in bucket")
    
    # Save bucket metadata
    with open(METADATA_FILE, 'w') as f:
        json.dump({
            "bucket": BUCKET,
            "downloaded_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "file_count": total_files,
            "files": all_files
        }, f, indent=2)
    
    # Download each file in parallel
    success_count = 0
    def download_task(file_info):
        file_path = file_info.get("name")
        if not file_path:
            return False
        out_path = DATA_DIR / file_path
        # Skip if file already exists
        if out_path.exists():
            print(f"Skipping (already exists): {file_path}")
            return True
        return download_file(file_path, out_path)

    print("Starting parallel downloads...")
    with ThreadPoolExecutor(max_workers=32) as executor:
        futures = [executor.submit(download_task, file_info) for file_info in all_files]
        for i, future in enumerate(as_completed(futures), 1):
            result = future.result()
            if result:
                success_count += 1
            print(f"[{i}/{total_files}] Download {'succeeded' if result else 'failed'}")

    print(f"Successfully downloaded {success_count} of {total_files} files")
    print(f"Bucket mirrored to {DATA_DIR}")

def scan_local_data():
    """Scan and report on local data, comparing with bucket metadata for upload status."""
    if not DATA_DIR.exists():
        print("Data directory doesn't exist. Run mirror_bucket() first.")
        return

    bucket_files_info = []
    if METADATA_FILE.exists():
        with open(METADATA_FILE, 'r') as f:
            bucket_metadata = json.load(f)
            bucket_files_info = bucket_metadata.get("files", [])
            print(f"Loaded bucket metadata with {len(bucket_files_info)} file records.")
    else:
        print(f"Warning: {METADATA_FILE} not found. Cannot determine upload status.")

    # Create a set of PosixPath objects for efficient lookup
    bucket_file_paths = {Path(file_info["name"]) for file_info in bucket_files_info if "name" in file_info}

    scan_dirs_details = []
    total_size_bytes = 0
    total_local_files_in_scans = 0

    for item in DATA_DIR.iterdir():
        if item.is_dir() and item.name.startswith("Scan-"):
            scan_id = item.name
            session_path = DATA_DIR / scan_id
            session_bucket_path = Path(scan_id) # Relative path for bucket checking

            local_meta = (session_path / "meta.json").exists()
            local_video = (session_path / "video.mov").exists()
            local_imu = (session_path / "imu.bin").exists()
            local_depth_dir = (session_path / "depth").is_dir()
            local_depth_files = list((session_path / "depth").glob("*.d32")) if local_depth_dir else []
            local_depth_files_count = len(local_depth_files)
            local_depth_present = local_depth_dir and local_depth_files_count > 0

            uploaded_meta = (session_bucket_path / "meta.json") in bucket_file_paths
            uploaded_video = (session_bucket_path / "video.mov") in bucket_file_paths
            uploaded_imu = (session_bucket_path / "imu.bin") in bucket_file_paths
            
            uploaded_depth_files_count = 0
            if local_depth_dir:
                for local_depth_file_path in local_depth_files:
                    # Construct the expected path in the bucket
                    expected_bucket_depth_file_path = session_bucket_path / "depth" / local_depth_file_path.name
                    if expected_bucket_depth_file_path in bucket_file_paths:
                        uploaded_depth_files_count += 1
            
            all_depth_uploaded = False
            if local_depth_present:
                all_depth_uploaded = (uploaded_depth_files_count == local_depth_files_count)
            elif not local_depth_present and uploaded_depth_files_count > 0:
                # Edge case: depth files in bucket but not locally (maybe deleted locally after mirror)
                pass # Or mark as "orphaned in bucket"
            elif not local_depth_present and uploaded_depth_files_count == 0:
                all_depth_uploaded = True # No local depth, no uploaded depth = consistent

            scan_details = {
                "id": scan_id,
                "local": {
                    "meta": local_meta,
                    "video": local_video,
                    "imu": local_imu,
                    "depth_files": local_depth_files_count
                },
                "uploaded": {
                    "meta": uploaded_meta,
                    "video": uploaded_video,
                    "imu": uploaded_imu,
                    "depth_files": uploaded_depth_files_count,
                    "all_depth_fully_uploaded": all_depth_uploaded
                }
            }
            scan_dirs_details.append(scan_details)

            for f_path in session_path.rglob('*'):
                if f_path.is_file():
                    total_local_files_in_scans += 1
                    total_size_bytes += f_path.stat().st_size
    
    # Account for bucket_metadata.json itself
    num_other_files = 0
    if METADATA_FILE.exists():
        num_other_files +=1
        total_size_bytes += METADATA_FILE.stat().st_size

    print("\n--- Local Data Scan & Upload Status ---")
    if not scan_dirs_details:
        print("No local 'Scan-' directories found.")
    else:
        scan_dirs_details.sort(key=lambda x: x['id'])
        for details in scan_dirs_details:
            print(f"\nSession: {details['id']}")
            print(f"  Meta:     Local: {'Yes' if details['local']['meta'] else 'No '}{'*' if details['local']['meta'] and not details['uploaded']['meta'] else ' '} | Uploaded: {'Yes' if details['uploaded']['meta'] else 'No '}")
            print(f"  Video:    Local: {'Yes' if details['local']['video'] else 'No '}{'*' if details['local']['video'] and not details['uploaded']['video'] else ' '} | Uploaded: {'Yes' if details['uploaded']['video'] else 'No '}")
            print(f"  IMU:      Local: {'Yes' if details['local']['imu'] else 'No '}{'*' if details['local']['imu'] and not details['uploaded']['imu'] else ' '} | Uploaded: {'Yes' if details['uploaded']['imu'] else 'No '}")
            depth_local_count = details['local']['depth_files']
            depth_uploaded_count = details['uploaded']['depth_files']
            depth_fully_uploaded = details['uploaded']['all_depth_fully_uploaded']
            depth_sync_marker = '*' if depth_local_count > 0 and not depth_fully_uploaded else ' '
            print(f"  Depth:    Local: {depth_local_count:>3} files{depth_sync_marker} | Uploaded: {depth_uploaded_count:>3} files (All: {'Yes' if depth_fully_uploaded else 'No'})")

    print("\n(* indicates present locally but not confirmed uploaded based on last mirror metadata)")

    print("\n--- Local Storage Summary ---")
    print(f"- {len(scan_dirs_details)} scan directories processed")
    print(f"- {total_local_files_in_scans} files within scan directories")
    if num_other_files > 0:
        print(f"- {num_other_files} other file(s) (e.g., bucket_metadata.json)")
    print(f"- {total_size_bytes / (1024*1024):.2f} MB total local size")

def clear_local_data():
    """Clear the local data directory"""
    if DATA_DIR.exists():
        shutil.rmtree(DATA_DIR)
        print(f"Cleared data directory: {DATA_DIR}")
    
    # Recreate empty directory
    DATA_DIR.mkdir()
    print(f"Created empty data directory: {DATA_DIR}")

if __name__ == "__main__":
    setup_data_dir()
    mirror_bucket()
    scan_local_data()
    
    print("\nData is now stored locally and ready for analysis.")
    print("To use this data in your analysis scripts, use the data directory path:")
    print(f"  {DATA_DIR}")
