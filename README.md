# roboclip & robo-rewind

This repository contains two complementary pieces:

- **roboclip** – a Swift iOS app for capturing LiDAR depth, RGB video and IMU pose data. Recordings are saved in timestamped folders and can be uploaded to Supabase Storage. See [roboclip/README.md](roboclip/README.md) for a tour of the app and its architecture.
- **robo-rewind** – a set of Python tools for mirroring your Supabase bucket and replaying sessions with [rerun.io](https://www.rerun.io/). Details are in [robo-rewind/README.md](robo-rewind/README.md).

## Quick setup

### iOS app
1. Create a Supabase project and add your `SUPABASE_URL` and `SUPABASE_ANON_KEY` to `roboclip/SupabaseSecrets.xcconfig` (this file is ignored by git).
2. Open `roboclip.xcodeproj` in Xcode on a LiDAR-capable device.
3. Build and run to start capturing sessions and uploading them to your Supabase bucket.

### Python tools
1. Navigate to the tools folder:
   ```bash
   cd robo-rewind
   ```
2. Run the setup script to create a virtual environment and install dependencies:
   ```bash
   source setup.sh
   ```
3. Use `python replay_sessions.py` or other scripts in the folder to work with your recordings. The helper `robo-rewind/mirror_bucket.py` can download the entire bucket for offline replay:
   ```bash
   python robo-rewind/mirror_bucket.py
   ```

For full instructions and advanced usage, read the READMEs in each subdirectory.
