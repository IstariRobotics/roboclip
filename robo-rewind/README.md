# robo-rewind

This folder contains scripts and utilities to fetch and replay Supabase session data for use with rerun.io.

## Setup

1. Open a terminal and navigate to this folder:
   ```zsh
   cd robo-rewind
   ```
2. Run the setup script to create a Python virtual environment and install dependencies:
   ```zsh
   source setup.sh
   # or, if you prefer
   ./setup.sh
   ```

## Usage

- To fetch and transform Supabase sessions, run:
  ```zsh
  python replay_local_data.py
  ```
- The output will be saved as `rerun_sessions.json` by default.
- `rerun_sessions.json` is listed in `.gitignore`, so your results won't be committed.

## Replay Local Data

This script, `replay_local_data.py`, allows you to visualize data sessions captured by the RoboClip iOS application using the [Rerun viewer](https://www.rerun.io/). It can display video, depth, and IMU data, along with camera poses if available.

### Setup

1.  **Create a Python Virtual Environment (Optional but Recommended)**:
    It's good practice to use a virtual environment to manage dependencies. This script is tested with Python 3.11.

    ```bash
    # Navigate to the root of the roboclip repository
    cd /path/to/your/roboclip

    # Create a virtual environment named 'venv-py311' (or your preferred name)
    python3.11 -m venv venv-py311 
    ```

2.  **Activate the Virtual Environment**:

    ```bash
    source venv-py311/bin/activate
    ```
    Your terminal prompt should now indicate that you are in the virtual environment.

3.  **Install Dependencies**:
    Install the required Python packages from `requirements.txt` located in the `robo-rewind` directory.

    ```bash
    pip install -r robo-rewind/requirements.txt
    ```

### Running the Script

Once the setup is complete, you can run the replay script:

```bash
python robo-rewind/replay_local_data.py
```

**Behavior**:

*   By default, the script will look for the most recent session in the `data/` directory and attempt to replay it.
*   The `data/` directory is expected to be at `/Users/jamesball/Documents/GitHub/roboclip/data`.
*   If the Rerun viewer doesn't open automatically, you might need to run `rerun` in your terminal after the script finishes processing.

**Command-line Arguments**:

*   `--session_id <SESSION_NAME>`: You can specify a particular session to replay by providing its name (e.g., `Scan-20250522-131418087`).

    ```bash
    python robo-rewind/replay_local_data.py --session_id Scan-20250522-131418087
    ```

### Data Structure

The script expects data to be organized in session folders (e.g., `Scan-YYYYMMDD-HHMMSSXXX`) within the `data/` directory. Each session folder might contain:

*   `imu.bin`: IMU data (CSV format).
*   `video.mov`: Video recording.
*   `video_timestamps.json`: Timestamps for video frames.
*   `depth/`: A directory containing `.d32` depth frames.
*   `meta.json`: Metadata for the session, including camera intrinsics and depth resolution.
*   `camera_poses.json`: Camera poses (4x4 transformation matrices) with timestamps.

If `camera_poses.json` is not present, the script will attempt to use IMU data for orientation and will generate a placeholder `camera_poses.json` with identity matrices.

### Troubleshooting

*   **`Data directory ... doesn't exist`**: Ensure the `data/` directory exists at the expected location (`/Users/jamesball/Documents/GitHub/roboclip/data`) and contains session folders. You might need to run `mirror_bucket.py` first if your data is sourced from a remote bucket.
*   **Missing `python3.11`**: If you don't have Python 3.11, you'll need to install it. You can use tools like `pyenv` to manage multiple Python versions.
*   **Rerun Viewer Issues**: If the Rerun viewer doesn't display data correctly or doesn't open, check the console output from the script for any errors. Ensure Rerun is installed correctly in your environment (`pip show rerun-sdk`).
*   **Coordinate System Misalignment**: If the camera, depth, or IMU data appears misaligned in Rerun, it might indicate an issue with the coordinate system transformations within the script. The script attempts to convert ARKit coordinate systems to Rerun's RDF (Right, Down, Forward) convention.

## Notes
- The file `roboclip/roboclip/SupabaseSecrets.xcconfig` is ignored by git for security.
- The Python virtual environment (`venv/`) is also ignored by git.

---

Feel free to extend these scripts for your workflow or rerun.io integration!
