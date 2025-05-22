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

## Notes
- The file `roboclip/roboclip/SupabaseSecrets.xcconfig` is ignored by git for security.
- The Python virtual environment (`venv/`) is also ignored by git.

---

Feel free to extend these scripts for your workflow or rerun.io integration!
