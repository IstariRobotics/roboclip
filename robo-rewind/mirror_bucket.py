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
    """Scan and report on local data"""
    if not DATA_DIR.exists():
        print("Data directory doesn't exist. Run mirror_bucket() first.")
        return
        
    # Count files
    file_count = 0
    dir_count = 0
    scan_dirs = []
    total_size = 0
    
    for root, dirs, files in os.walk(DATA_DIR):
        for d in dirs:
            if d.startswith("Scan-"):
                scan_dirs.append(d)
            dir_count += 1
                
        for f in files:
            if f != "bucket_metadata.json":
                file_path = os.path.join(root, f)
                file_count += 1
                total_size += os.path.getsize(file_path)
    
    print(f"Local data summary:")
    print(f"- {len(scan_dirs)} scan directories")
    print(f"- {file_count} files (excluding metadata)")
    print(f"- {dir_count} directories")
    print(f"- {total_size / (1024*1024):.2f} MB total size")

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
