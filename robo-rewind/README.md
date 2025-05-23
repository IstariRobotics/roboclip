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
- To compute optical flow from depth frames and camera poses, run:
  ```zsh
  python compute_optical_flow.py --session_id Scan-YYYYMMDD-HHMM
  ```
  Optical flow files (`.flow.npy`) will be written next to the depth data of the specified session.

## Notes
- The file `roboclip/roboclip/SupabaseSecrets.xcconfig` is ignored by git for security.
- The Python virtual environment (`venv/`) is also ignored by git.

---

Feel free to extend these scripts for your workflow or rerun.io integration!
