# LiDAR + Video Capture iOS App – End‑to‑End Technical Checklist

> **Goal:** ship an iPhone app that records synchronised LiDAR depth, RGB video and IMU pose while displaying a real‑time preview. The user can start a new capture, review existing captures, and return to the Home Screen at any time.

---

## 1 · Prerequisites

* **Devices:** iPhone 12 Pro or newer (LiDAR‑equipped).
* **OS:** iOS 17 SDK or later.
* **Languages:** Swift 5.9, SwiftUI, optional Objective‑C shim for Metal shaders.
* **Entitlements:** none beyond default; no background capture allowed.

---

## 2 · High‑level Architecture

| Layer       | Responsibility                             | Primary APIs                                                           |
| ----------- | ------------------------------------------ | ---------------------------------------------------------------------- |
| Capture     | LiDAR + RGB frame acquisition, IMU tap‑in | `ARKit (ARSession)`, or custom `AVCaptureSession` + `CoreMotion` |
| Processing  | Depth→point cloud, Metal conversion       | `Metal`, `RealityKit`                                              |
| Persistence | HEVC video, raw depth planes, IMU binary   | `AVAssetWriter`, `FileHandle`                                      |
| UI          | Real‑time preview, controls, navigation   | `SwiftUI`, `ARView` or custom `CAMetalLayer`                     |

---

## 3 · Capture Pipeline (ARKit default)

1. **Session bootstrap**
   ```swift
   let cfg = ARWorldTrackingConfiguration()
   cfg.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
   cfg.videoFormat = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing()
   session.run(cfg)
   ```
2. **Frame handler** – enqueue RGB, depth, and pose using shared timestamps.
3. **IMU** –** **`CMMotionManager.startDeviceMotionUpdates(to: queue)`.
4. **Recording** –** **`AVAssetWriter` (HEVC 4:2:0) + custom files:
   * `/depth/000123.d32` (Float32 plane)
   * `imu.bin` (struct rows including gravity)
   * `camera_poses.json` (ARKit camera transform per frame)
   * `audio.m4a` (microphone recording)
   * `world_map.bin` and `mesh.obj` (ARKit world map and environment mesh)
5. **Shutdown** – stop session, finish writers, free pools.

---

## 4 · Threading & Performance

* 3 dedicated** **`DispatchQueue`s:** ** **capture** ,** ** **encode** ,** ** **ui** .
* Reuse** **`CVPixelBuffer`s via pool; zero allocations in callback path.
* Thermal guard: down‑sample LiDAR to 30 FPS if** **`ProcessInfo.thermalState ≥ .serious`.

---

## 5 · UI / UX Flow

### 5.1 Navigation graph

```
HomeView
 └─ RecordingView (live capture)
      ↳ onFinish → Save/Delete confirmation → HomeView
```

> Use a** **`NavigationStack {}` and** **`navigationDestination` for type‑safe routing.

### 5.2 HomeView

* **Record Button** – primary action; pushes** **`RecordingView`.
* **View Recordings** – secondary button to browse saved sessions.
* Layout guideline:** **`VStack` centred, large icons; hide status bar.

### 5.3 RecordingView

| Zone         | Component                                        | Notes                                                                           |
| ------------ | ------------------------------------------------ | ------------------------------------------------------------------------------- |
| Background   | `ARPreviewView` – Metal or `ARView`         | Fills safe area.                                                                |
| Overlay      | `ControlBar` (bottom)                          | Record toggle, blinking timer, battery badge, Back button (leading, top‑left). |
| Confirmation | `confirmationDialog` – “Keep this capture?” | Buttons:**Save**(default), **Delete**(destructive).                 |

#### Back navigation

```swift
toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Home") { dismiss() } } }
```

### 5.4 Live Activity (optional)

Request when recording starts; update elapsed seconds every frame; end on stop.

---

## 6 · Reusable UI Components

* **RecordButton** – circle toggling white/ red, spring animation.
* **BlinkingIndicator** –** **`TimelineView(.animation)` toggles opacity.
* **MetalPreviewLayer** – wraps** **`CAMetalLayer`; exposes** **`DrawableProvider`.

---

## 7 · Data Model & File Structure

```
/Scan-YYYYMMDD-hhmm/
    video.mov              // HEVC 30–60 FPS
    audio.m4a             // microphone capture
    meta.json              // intrinsics, device, app build
    camera_poses.json      // per-frame camera transform
    world_map.bin          // ARKit world map
    mesh.obj               // reconstructed mesh
    depth/                 // 32‑bit little-endian planes
        000001.d32
    imu.bin                // timestamp + accel + gyro + gravity floats
```

> Keep RGB, depth, IMU separate to simplify post‑processing in Python or MATLAB.

---

## 8 · Testing Checklist

1. **Functional**
   * [ ] Start + stop recording produces expected files.
   * [ ] Real‑time preview ≤ 1 frame latency.
2. **Thermal / Power**
   * [ ] Simulate** **`thermalState = .serious`; verify FPS throttle.
3. **Interruptions**
   * [ ] Lock screen with Live Activity running.
   * [ ] Incoming call / audio route change.
4. **Accessibility**
   * [ ] VoiceOver labels on buttons.
   * [ ] Dynamic type respects system setting.
5. **Storage**
   * [ ] Low‑space handler (`URLResourceValues.volumeAvailableCapacityForImportantUsage`).

---

## 9 · Future Extensions (nice‑to‑have)

* HDR video via manual** **`AVCaptureSession` path.
* World map and environment mesh capture with on‑device meshing.
* Cloud sync of completed scans (iCloud Drive).
* Background upload with** **`BackgroundTasks` while on Wi‑Fi.

---

## 10 · Implementation & MCP Debug Checklist

### Phase 1: Project Setup & Architecture

- [X] Confirm Xcode project builds and runs on device simulator
- [X] Set up entitlements and minimum iOS version

### Phase 2: Core Capture Pipeline

- [x] Implement ARKit session bootstrap (scene depth, high-res video)
- [x] Add frame handler to enqueue RGB, depth, pose (timestamp sync)
- [x] Integrate IMU capture with CMMotionManager
- [x] Set up AVAssetWriter for video, custom file output for depth/IMU
- [x] Implement clean shutdown and resource release
- [x] Use MCP to debug frame sync, data integrity, and error handling

### Phase 3: Threading & Performance

- [x] Create dedicated DispatchQueues (capture, encode, UI)
- [x] Implement CVPixelBuffer pool reuse
- [x] Add thermal guard (downsample LiDAR if thermalState ≥ .serious)
- [x] Use MCP to monitor performance and thermal events

### Phase 4: UI/UX Implementation

- [x] Build HomeView with navigation to RecordingView
- [x] Implement RecordingView with ARPreview, ControlBar, and confirmation dialog
- [x] Add reusable UI components (RecordButton, BlinkingIndicator, MetalPreviewLayer)
- [x] Use MCP to debug navigation and UI state
- [ ] Optional: Add Live Activity for recording status
- [ ] Use MCP to debug navigation and UI state

### Phase 5: Data Model & Persistence

- [x] Ensure meta.json includes intrinsics, device, app build info
- [x] Validate file output and structure with MCP
- [ ] Implement file structure: /Scan-YYYYMMDD-hhmm/ with video, meta.json, depth, imu.bin
- [ ] Validate file output and structure with MCP

### Phase 6: Testing & Validation

- [ ] Functional: Start/stop recording, file output, real-time preview latency
- [ ] Thermal/Power: Simulate thermalState, verify FPS throttle
- [ ] Interruptions: Test lock screen, calls, audio route changes
- [ ] Accessibility: VoiceOver, dynamic type
- [ ] Storage: Low-space handler
- [ ] Use MCP for automated and manual test logging

### Phase 7: Review & Polish

- [ ] Code review and refactor for clarity and maintainability
- [ ] Final MCP debug pass for edge cases
- [ ] Prepare for App Store/TestFlight submission

---

> Use MCP throughout to debug, log, and validate each phase. Check off each item as you progress.

### ✦ Ready to Build

Follow the checklist in order; each section is intentionally atomic so tasks can be ticked off during implementation or sprint planning.
