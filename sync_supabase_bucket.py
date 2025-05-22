import os
import requests
import json
import time
from pathlib import Path

SUPABASE_URL = "https://rfprjaeyqomuvzempixf.supabase.co"
SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJmcHJqYWV5cW9tdXZ6ZW1waXhmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDc0NzM4NDAsImV4cCI6MjA2MzA0OTg0MH0.ODNn6Sh8MQvTwEkcUPT3tmVhehgTgEU51cWthou8XsM"
BUCKET = "roboclip-recordings"

# Path to store downloaded data
DATA_DIR = Path(os.path.dirname(os.path.abspath(__file__))) / "data"
METADATA_FILE = DATA_DIR / "bucket_metadata.json"


def setup_data_dir():
    DATA_DIR.mkdir(exist_ok=True)
    print(f"Data directory: {DATA_DIR}")


def list_bucket_files(prefix=""):
    headers = {
        "apikey": SUPABASE_ANON_KEY,
        "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
        "Content-Type": "application/json"
    }
    url = f"{SUPABASE_URL}/storage/v1/object/list/{BUCKET}"
    body = {"prefix": prefix, "limit": 1000, "offset": 0}
    resp = requests.post(url, headers=headers, json=body)
    try:
        resp.raise_for_status()
        return resp.json()
    except requests.HTTPError as e:
        print(f"Supabase API error: {e}")
        return []


def download_file(path, out_path):
    headers = {
        "apikey": SUPABASE_ANON_KEY,
        "Authorization": f"Bearer {SUPABASE_ANON_KEY}"
    }
    url = f"{SUPABASE_URL}/storage/v1/object/{BUCKET}/{path}"
    try:
        r = requests.get(url, headers=headers)
        r.raise_for_status()
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        with open(out_path, "wb") as f:
            f.write(r.content)
        return True
    except requests.HTTPError as e:
        print(f"Failed to download {path}: {e}")
        return False


def load_metadata():
    if METADATA_FILE.exists():
        with open(METADATA_FILE, 'r') as f:
            return json.load(f)
    return {"files": []}


def save_metadata(metadata):
    with open(METADATA_FILE, 'w') as f:
        json.dump(metadata, f, indent=2)


def sync_bucket():
    print(f"Syncing bucket {BUCKET} to {DATA_DIR}...")
    all_files = list_bucket_files()
    local_metadata = load_metadata()
    local_files = {f['name'] for f in local_metadata.get('files', [])}
    new_files = [f for f in all_files if f.get('name') and f['name'] not in local_files]
    print(f"Found {len(new_files)} new files to download.")
    success_count = 0
    for i, file_info in enumerate(new_files):
        file_path = file_info.get("name")
        if not file_path:
            continue
        print(f"[{i+1}/{len(new_files)}] Downloading {file_path}")
        out_path = DATA_DIR / file_path
        if download_file(file_path, out_path):
            success_count += 1
            local_metadata.setdefault('files', []).append(file_info)
    local_metadata['bucket'] = BUCKET
    local_metadata['last_synced'] = time.strftime("%Y-%m-%d %H:%M:%S")
    local_metadata['file_count'] = len(local_metadata.get('files', []))
    save_metadata(local_metadata)
    print(f"Successfully downloaded {success_count} new files.")
    print(f"Bucket is now synced to {DATA_DIR}")


def scan_local_data():
    if not DATA_DIR.exists():
        print("Data directory doesn't exist. Run sync_bucket() first.")
        return
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


def main():
    setup_data_dir()
    sync_bucket()
    scan_local_data()
    print("\nData is now stored locally and ready for analysis.")
    print(f"To use this data in your analysis scripts, use the data directory path: {DATA_DIR}")

if __name__ == "__main__":
    main()
