// RecordingManager.swift
// roboclip
//
// Handles writing video, depth, and IMU data to disk.

import Foundation
import AVFoundation
import ARKit
import CoreMotion
import Metal

class RecordingManager {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var depthFileHandle: FileHandle?
    private var imuFileHandle: FileHandle?
    private var videoFrameIndex: Int = 0
    private var outputDirectory: URL?
    private var isRecording = false
    private var pixelBufferPool: CVPixelBufferPool?
    private var cameraIntrinsics: simd_float3x3?
    private var recordingStartTime: CMTime?
    private var depthWidth: Int = 0
    private var depthHeight: Int = 0
    private var imageWidth: Int = 0
    private var imageHeight: Int = 0
    private var sessionStartWallClock: TimeInterval?
    private var sessionStartARKitTimestamp: TimeInterval?
    private var videoTimestampsJSON: [[String: Any]] = []
    private var audioRecorder: AVAudioRecorder?
    private var cameraPoses: [[String: Any]] = []
    /// Weak reference to the AR session so we can grab a world map and mesh
    /// when recording stops. Exposed as read-only so external callers can
    /// supply a session but not replace it mid-recording.
    private(set) weak var arSession: ARSession?

    func setCameraIntrinsics(_ m: simd_float3x3, imageResolution: CGSize) {
        cameraIntrinsics = m
        self.imageWidth = Int(imageResolution.width)
        self.imageHeight = Int(imageResolution.height)
        MCP.log("RecordingManager: Intrinsics and image resolution set - ImageSize: \(self.imageWidth)x\(self.imageHeight)")
    }
    
    func startRecording(device: MTLDevice, arSession session: ARSession) {
        MCP.log("RecordingManager.startRecording() called")
        isRecording = false
        let fileManager = FileManager.default
        MCP.log("RecordingManager temp dir: \(fileManager.temporaryDirectory.path)")
        let timestamp = RecordingManager.scanFolderDateFormatter.string(from: Date())
        let dir = fileManager.temporaryDirectory.appendingPathComponent("Scan-\(timestamp)")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        outputDirectory = dir
        recordingStartTime = nil
        videoFrameIndex = 0 // Reset frame index at start
        videoTimestampsJSON = [] // Reset JSON array at start
        cameraPoses = []
        self.arSession = session
        
        // Video
        let videoURL = dir.appendingPathComponent("video.mov")
        do {
            assetWriter = try AVAssetWriter(url: videoURL, fileType: .mov)
        } catch {
            MCP.log("RecordingManager: ERROR - Failed to initialize AVAssetWriter: \(error.localizedDescription)")
            return
        }

        guard let strongAssetWriter = assetWriter else {
            MCP.log("RecordingManager: ERROR - assetWriter is nil after init attempt.")
            return
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        
        guard let strongVideoInput = videoInput else {
            MCP.log("RecordingManager: ERROR - videoInput is nil after init attempt.")
            assetWriter = nil
            return
        }

        if strongAssetWriter.canAdd(strongVideoInput) {
            strongAssetWriter.add(strongVideoInput)
        } else {
            MCP.log("RecordingManager: ERROR - Cannot add videoInput to assetWriter.")
            videoInput = nil
            assetWriter = nil
            return
        }
        
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: strongVideoInput, sourcePixelBufferAttributes: attrs)
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pixelBufferPool)
        
        if !strongAssetWriter.startWriting() {
            MCP.log("RecordingManager: ERROR - assetWriter.startWriting() failed. Status: \(strongAssetWriter.status.rawValue). Error: \(strongAssetWriter.error?.localizedDescription ?? "Unknown error")")
            videoInput = nil
            assetWriter = nil
            return
        }
        strongAssetWriter.startSession(atSourceTime: .zero)
        
        if strongAssetWriter.status == .failed {
             MCP.log("RecordingManager: assetWriter status is FAILED after startWriting/startSession. Error: \(strongAssetWriter.error?.localizedDescription ?? "Unknown error")")
             videoInput = nil
             assetWriter = nil
             return
        }
        MCP.log("RecordingManager: AVAssetWriter started successfully.")

        // Depth
        let depthDir = dir.appendingPathComponent("depth")
        try? fileManager.createDirectory(at: depthDir, withIntermediateDirectories: true)
        // IMU
        let imuURL = dir.appendingPathComponent("imu.bin")
        fileManager.createFile(atPath: imuURL.path, contents: nil)
        imuFileHandle = try? FileHandle(forWritingTo: imuURL)

        // Audio
        let audioURL = dir.appendingPathComponent("audio.m4a")
        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        do {
            audioRecorder = try AVAudioRecorder(url: audioURL, settings: audioSettings)
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            MCP.log("RecordingManager: Started microphone recording")
        } catch {
            MCP.log("RecordingManager: ERROR starting audio recorder: \(error)")
        }
        
        isRecording = true
        MCP.log("RecordingManager: Created scan directory at \(dir.path). isRecording = true.")

        if let currentFrame = session.currentFrame {
            // Store wall-clock and ARKit timestamps for absolute time conversion
            self.sessionStartWallClock = Date().timeIntervalSince1970
            self.sessionStartARKitTimestamp = currentFrame.timestamp

            let depthMap = currentFrame.sceneDepth?.depthMap ?? currentFrame.smoothedSceneDepth?.depthMap
            if let validDepthMap = depthMap {
                self.depthWidth = CVPixelBufferGetWidth(validDepthMap)
                self.depthHeight = CVPixelBufferGetHeight(validDepthMap)
                print("RecordingManager: Depth dimensions set at start: \(self.depthWidth)x\(self.depthHeight)")
            } else {
                print("RecordingManager: Could not get depth map from current ARFrame at start of recording.")
            }
            if self.imageWidth == 0 || self.imageHeight == 0 {
                 self.imageWidth = Int(currentFrame.camera.imageResolution.width)
                 self.imageHeight = Int(currentFrame.camera.imageResolution.height)
                 print("RecordingManager: Image dimensions set from ARFrame at start: \(self.imageWidth)x\(self.imageHeight)")
            }
        } else {
            print("RecordingManager: No ARFrame available at start of recording to get depth/image dimensions.")
        }
    }
    
    func stopRecording(completion: (() -> Void)? = nil) {
        MCP.log("RecordingManager: stopRecording called. Current isRecording state: \(isRecording)")
        if !isRecording && assetWriter == nil {
            MCP.log("RecordingManager: stopRecording - recording was not active or already stopped, and assetWriter is nil. Calling completion.")
            completion?()
            return
        }
        isRecording = false
        recordingStartTime = nil
        
        videoInput?.markAsFinished()
        MCP.log("RecordingManager: videoInput marked as finished.")
        
        // Close file handles first
        depthFileHandle?.closeFile()
        imuFileHandle?.closeFile()
        MCP.log("RecordingManager: Closed depth and IMU file handles.")

        audioRecorder?.stop()
        audioRecorder = nil
        MCP.log("RecordingManager: Stopped audio recording.")

        // Write meta.json
        if let dir = self.outputDirectory {
            let metaURL = dir.appendingPathComponent("meta.json")
            var meta: [String: Any] = [
                "scan_id": self.outputDirectory?.lastPathComponent ?? UUID().uuidString,
                "timestamp_iso8601": ISO8601DateFormatter().string(from: Date()),
                "platform": "iOS",
                "device_model": UIDevice.current.model,
                "os_version": UIDevice.current.systemVersion,
                "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "N/A",
                "build_number": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "N/A",
                "depthWidth": self.depthWidth,
                "depthHeight": self.depthHeight,
                "depth_unit": "meters",
                "depth_format": "Float32",
                "imageWidth": self.imageWidth,
                "imageHeight": self.imageHeight
            ]
            if let intrinsics = self.cameraIntrinsics {
                meta["camera_intrinsics_matrix"] = [
                    [intrinsics.columns.0.x, intrinsics.columns.1.x, intrinsics.columns.2.x],
                    [intrinsics.columns.0.y, intrinsics.columns.1.y, intrinsics.columns.2.y],
                    [intrinsics.columns.0.z, intrinsics.columns.1.z, intrinsics.columns.2.z]
                ]
                meta["fx"] = intrinsics.columns.0.x
                meta["fy"] = intrinsics.columns.1.y
                meta["cx"] = intrinsics.columns.2.x
                meta["cy"] = intrinsics.columns.2.y
            } else {
                MCP.log("RecordingManager: WARNING - cameraIntrinsics are nil when writing meta.json.")
            }

            if let data = try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted) {
                do {
                    try data.write(to: metaURL)
                    MCP.log("RecordingManager: Wrote meta.json to \(metaURL.path)")
                } catch {
                    MCP.log("RecordingManager: ERROR writing meta.json: \(error)")
                }
            }
        } else {
            MCP.log("RecordingManager: ERROR - outputDirectory is nil, cannot write meta.json.")
        }

        // Write video_timestamps.json
        if let dir = self.outputDirectory {
            let jsonURL = dir.appendingPathComponent("video_timestamps.json")
            do {
                let data = try JSONSerialization.data(withJSONObject: videoTimestampsJSON, options: .prettyPrinted)
                try data.write(to: jsonURL)
                MCP.log("RecordingManager: Wrote video_timestamps.json to \(jsonURL.path)")
            } catch {
                MCP.log("RecordingManager: ERROR writing video_timestamps.json: \(error)")
            }
        }

        // Write camera_poses.json
        if let dir = self.outputDirectory {
            let poseURL = dir.appendingPathComponent("camera_poses.json")
            do {
                let data = try JSONSerialization.data(withJSONObject: cameraPoses, options: .prettyPrinted)
                try data.write(to: poseURL)
                MCP.log("RecordingManager: Wrote camera_poses.json to \(poseURL.path)")
            } catch {
                MCP.log("RecordingManager: ERROR writing camera_poses.json: \(error)")
            }
        }

        // Save ARKit world map and mesh
        if let session = self.arSession, let dir = self.outputDirectory {
            let mapURL = dir.appendingPathComponent("world_map.bin")
            session.getCurrentWorldMap { worldMap, error in
                if let worldMap = worldMap {
                    do {
                        let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
                        try data.write(to: mapURL)
                        MCP.log("RecordingManager: Saved world map to \(mapURL.path)")
                    } catch {
                        MCP.log("RecordingManager: ERROR saving world map: \(error)")
                    }
                } else if let error = error {
                    MCP.log("RecordingManager: ERROR retrieving world map: \(error.localizedDescription)")
                }
            }

            if let frame = session.currentFrame {
                let meshURL = dir.appendingPathComponent("mesh.obj")
                let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
                do {
                    try self.saveMeshOBJ(anchors: meshAnchors, to: meshURL)
                    MCP.log("RecordingManager: Saved mesh to \(meshURL.path)")
                } catch {
                    MCP.log("RecordingManager: ERROR saving mesh: \(error)")
                }
            }
        }

        guard let writer = assetWriter else {
            MCP.log("RecordingManager: stopRecording - assetWriter is nil. No video to finish. Calling completion.")
            completion?()
            return
        }
        
        MCP.log("RecordingManager: Attempting to finish writing video. AssetWriter status before finishWriting: \(writer.status.rawValue)")
        if writer.status == .failed {
            MCP.log("RecordingManager: AssetWriter status was ALREADY FAILED. Error: \(writer.error?.localizedDescription ?? "None")")
        }

        writer.finishWriting { [weak self] in
            MCP.log("RecordingManager: AVAssetWriter finishWriting completed. Final status: \(writer.status.rawValue)")
            if writer.status == .failed {
                MCP.log("RecordingManager: AVAssetWriter FAILED to write video. Error: \(writer.error?.localizedDescription ?? "Unknown error")")
            } else if writer.status == .completed {
                MCP.log("RecordingManager: AVAssetWriter COMPLETED video writing successfully.")
            } else {
                MCP.log("RecordingManager: AVAssetWriter finished with status: \(writer.status.rawValue). Error: \(writer.error?.localizedDescription ?? "None")")
            }
            
            if let dir = self?.outputDirectory {
                let videoURL = dir.appendingPathComponent("video.mov")
                let videoExists = FileManager.default.fileExists(atPath: videoURL.path)
                let imuExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent("imu.bin").path)
                let depthDir = dir.appendingPathComponent("depth")
                let depthFilesCount = (try? FileManager.default.contentsOfDirectory(atPath: depthDir.path).count) ?? 0
                let metaExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent("meta.json").path)
                
                MCP.log("Validation after finishWriting: video.mov exists = \(videoExists) at \(videoURL.path), imu.bin exists = \(imuExists), depth/ count = \(depthFilesCount), meta.json exists = \(metaExists)")
                
                if videoExists && imuExists && metaExists {
                     MCP.log("All essential files appear present. Calling completion for upload.")
                } else {
                    MCP.log("WARNING: Not all essential files present after finishWriting. Upload might be incomplete or fail.")
                }
            } else {
                MCP.log("RecordingManager: outputDirectory was nil during final validation.")
            }
            completion?()
        }
    }
    
    func appendVideoFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard isRecording else {
            MCP.log("appendVideoFrame: Not recording, skipping frame at time \(time.seconds)")
            return
        }
        // Compute wall-clock timestamp
        var wallClock: Double = 0.0
        if let startWall = sessionStartWallClock, let startAR = sessionStartARKitTimestamp {
            let frameTimestamp = time.seconds
            wallClock = startWall + (frameTimestamp - startAR)
        } else {
            wallClock = Date().timeIntervalSince1970
        }
        // Save to JSON array only
        videoTimestampsJSON.append(["wall_clock": wallClock, "frame_index": videoFrameIndex])
        videoFrameIndex += 1

        guard let input = videoInput, let adaptor = pixelBufferAdaptor else { return }
        if !input.isReadyForMoreMediaData {
            MCP.log("appendVideoFrame: Video input not ready for more media data. Skipping frame at time \(time.seconds), but timestamp was written.")
            return
        }
        if recordingStartTime == nil {
            recordingStartTime = time
            MCP.log("RecordingManager: First video frame, recordingStartTime set to \(time.seconds)")
        }
        guard let start = recordingStartTime else {
            MCP.log("RecordingManager: recordingStartTime is nil, cannot append video frame at time \(time.seconds).")
            return
        }
        let relativeTime = CMTimeSubtract(time, start)
        
        if let pool = pixelBufferPool {
            var reusableBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &reusableBuffer)
            if status != kCVReturnSuccess {
                 MCP.log("RecordingManager: Failed to create pixel buffer from pool. Status: \(status). Appending original buffer.")
                 if !adaptor.append(pixelBuffer, withPresentationTime: relativeTime) {
                    MCP.log("RecordingManager: ERROR - pixelBufferAdaptor.append (original buffer) failed. Writer status: \(assetWriter?.status.rawValue ?? -1), Error: \(assetWriter?.error?.localizedDescription ?? "N/A")")
                 }
                 return
            }

            if let reusableBuffer = reusableBuffer {
                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                CVPixelBufferLockBaseAddress(reusableBuffer, [])
                
                let srcPlaneCount = CVPixelBufferGetPlaneCount(pixelBuffer)
                let dstPlaneCount = CVPixelBufferGetPlaneCount(reusableBuffer)

                var copiedSuccessfully = false
                if srcPlaneCount == dstPlaneCount && srcPlaneCount > 0 { // Multi-plane (e.g., NV12)
                    copiedSuccessfully = true
                    for plane in 0..<srcPlaneCount {
                        guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane),
                              let dstBase = CVPixelBufferGetBaseAddressOfPlane(reusableBuffer, plane) else {
                            copiedSuccessfully = false; break
                        }
                        let height = min(CVPixelBufferGetHeightOfPlane(pixelBuffer, plane), CVPixelBufferGetHeightOfPlane(reusableBuffer, plane))
                        let bytesPerRowSrc = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                        let bytesPerRowDst = CVPixelBufferGetBytesPerRowOfPlane(reusableBuffer, plane)
                        let bytesToCopyThisRow = min(bytesPerRowSrc, bytesPerRowDst)

                        if height > 0 && bytesToCopyThisRow > 0 {
                            for row in 0..<height {
                                memcpy(dstBase.advanced(by: row * bytesPerRowDst), srcBase.advanced(by: row * bytesPerRowSrc), bytesToCopyThisRow)
                            }
                        }
                    }
                } else if srcPlaneCount == 0 && dstPlaneCount == 0 { // Single-plane (e.g., BGRA)
                     guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
                           let dstBase = CVPixelBufferGetBaseAddress(reusableBuffer) else {
                        copiedSuccessfully = false;
                        MCP.log("appendVideoFrame: Failed to get base address for single-plane copy.")
                        CVPixelBufferUnlockBaseAddress(reusableBuffer, [])
                        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                        MCP.log("appendVideoFrame: Critical failure getting base addresses for single-plane copy. Appending original buffer.")
                        if !adaptor.append(pixelBuffer, withPresentationTime: relativeTime) {
                            MCP.log("RecordingManager: ERROR - pixelBufferAdaptor.append (original buffer after critical base address fail) failed. Writer status: \(assetWriter?.status.rawValue ?? -1), Error: \(assetWriter?.error?.localizedDescription ?? "N/A")")
                        }
                        return
                     }
                     let height = min(CVPixelBufferGetHeight(pixelBuffer), CVPixelBufferGetHeight(reusableBuffer))
                     let bytesPerRow = min(CVPixelBufferGetBytesPerRow(pixelBuffer), CVPixelBufferGetBytesPerRow(reusableBuffer))
                     if height > 0 && bytesPerRow > 0 {
                        memcpy(dstBase, srcBase, height * bytesPerRow)
                        copiedSuccessfully = true
                     } else {
                        MCP.log("appendVideoFrame: Single plane has zero height or bytesPerRow.")
                        copiedSuccessfully = false
                     }
                } else {
                    MCP.log("appendVideoFrame: Plane count mismatch (src:\(srcPlaneCount), dst:\(dstPlaneCount)) or unsupported format. Will attempt to append original buffer.")
                    copiedSuccessfully = false
                }

                CVPixelBufferUnlockBaseAddress(reusableBuffer, [])
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

                if copiedSuccessfully {
                    if !adaptor.append(reusableBuffer, withPresentationTime: relativeTime) {
                        MCP.log("RecordingManager: ERROR - pixelBufferAdaptor.append (reusableBuffer) failed. Writer status: \(assetWriter?.status.rawValue ?? -1), Error: \(assetWriter?.error?.localizedDescription ?? "N/A")")
                    }
                } else {
                    MCP.log("appendVideoFrame: memcpy failed or plane mismatch, falling back to original buffer.")
                    if !adaptor.append(pixelBuffer, withPresentationTime: relativeTime) {
                        MCP.log("RecordingManager: ERROR - pixelBufferAdaptor.append (original buffer after copy fail) failed. Writer status: \(assetWriter?.status.rawValue ?? -1), Error: \(assetWriter?.error?.localizedDescription ?? "N/A")")
                    }
                }
            } else {
                MCP.log("RecordingManager: Failed to create reusableBuffer from pool (reusableBuffer is nil). Appending original buffer.")
                if !adaptor.append(pixelBuffer, withPresentationTime: relativeTime) {
                    MCP.log("RecordingManager: ERROR - pixelBufferAdaptor.append (original buffer after pool fail) failed. Writer status: \(assetWriter?.status.rawValue ?? -1), Error: \(assetWriter?.error?.localizedDescription ?? "N/A")")
                }
            }
        } else {
            MCP.log("RecordingManager: pixelBufferPool is nil. Appending original buffer directly.")
            if !adaptor.append(pixelBuffer, withPresentationTime: relativeTime) {
                MCP.log("RecordingManager: ERROR - pixelBufferAdaptor.append (original buffer, no pool) failed. Writer status: \(assetWriter?.status.rawValue ?? -1), Error: \(assetWriter?.error?.localizedDescription ?? "N/A")")
            }
        }
    }

    func appendCameraPose(_ transform: simd_float4x4, timestamp: TimeInterval) {
        guard isRecording else { return }
        let wallClock: TimeInterval
        if let startWall = sessionStartWallClock, let startAR = sessionStartARKitTimestamp {
            wallClock = startWall + (timestamp - startAR)
        } else {
            wallClock = Date().timeIntervalSince1970
        }
        let matrix: [[Float]] = [
            [transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w],
            [transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w],
            [transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w],
            [transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w]
        ]
        cameraPoses.append(["timestamp": wallClock, "matrix": matrix])
    }
    
    func appendDepthData(depthData: CVPixelBuffer, timestamp: TimeInterval) {
        guard isRecording, let dir = outputDirectory else { return }

        // Update depth dimensions if not already set or if they change (though they shouldn't mid-recording)
        let currentDepthWidth = CVPixelBufferGetWidth(depthData)
        let currentDepthHeight = CVPixelBufferGetHeight(depthData)
        if self.depthWidth == 0 || self.depthHeight == 0 {
            self.depthWidth = currentDepthWidth
            self.depthHeight = currentDepthHeight
            MCP.log("RecordingManager: Depth dimensions set during appendDepthData: \(self.depthWidth)x\(self.depthHeight)")
        } else if self.depthWidth != currentDepthWidth || self.depthHeight != currentDepthHeight {
            MCP.log("RecordingManager: WARNING - Depth dimensions changed mid-recording. Old: \(self.depthWidth)x\(self.depthHeight), New: \(currentDepthWidth)x\(currentDepthHeight)")
            // Optionally handle this case, e.g., by stopping recording or logging an error
            // For now, we'll update to the new dimensions, but this is unusual.
            self.depthWidth = currentDepthWidth
            self.depthHeight = currentDepthHeight
        }

        let depthDir = dir.appendingPathComponent("depth")
        // Convert ARKit timestamp to wall-clock time for filename
        let absoluteTimestamp: TimeInterval
        if let startWall = sessionStartWallClock, let startAR = sessionStartARKitTimestamp {
            absoluteTimestamp = startWall + (timestamp - startAR)
        } else {
            absoluteTimestamp = Date().timeIntervalSince1970 // fallback
        }
        let fileName = String(format: "%.6f.d32", absoluteTimestamp)
        let fileURL = depthDir.appendingPathComponent(fileName)
        MCP.log("RecordingManager: Saving depth frame with ARKit timestamp \(timestamp), wall-clock \(absoluteTimestamp) to \(fileName)")

        CVPixelBufferLockBaseAddress(depthData, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthData, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthData) else {
            MCP.log("RecordingManager: ERROR - Could not get base address of depth data for frame at timestamp \(timestamp).")
            return
        }

        let bufferSize = CVPixelBufferGetDataSize(depthData) // Total size in bytes
        let pixelFormat = CVPixelBufferGetPixelFormatType(depthData)

        // Ensure it's Float32 depth data as expected
        guard pixelFormat == kCVPixelFormatType_DepthFloat32 else {
            MCP.log("RecordingManager: ERROR - Unexpected depth pixel format: \(pixelFormat). Expected kCVPixelFormatType_DepthFloat32. Skipping frame at \(timestamp).")
            return
        }

        let data = Data(bytes: baseAddress, count: bufferSize)
        
        do {
            try data.write(to: fileURL, options: .atomic)
            // MCP.log("RecordingManager: Saved depth frame to \(fileURL.lastPathComponent) (Size: \(bufferSize) bytes)") // Log sparingly
        } catch {
            MCP.log("RecordingManager: ERROR - Failed to write depth data for frame at timestamp \(timestamp) to \(fileURL.path): \(error)")
        }
    }
    
    func appendIMUData(_ imu: (timestamp: TimeInterval, attitude: CMAttitude, rotationRate: CMRotationRate, userAcceleration: CMAcceleration, gravity: CMAcceleration)) {
        guard isRecording, let handle = imuFileHandle else { return }
        // Save wall-clock timestamp for IMU
        let wallClock: TimeInterval
        if let startWall = sessionStartWallClock, let startAR = sessionStartARKitTimestamp {
            wallClock = startWall + (imu.timestamp - startAR)
        } else {
            wallClock = Date().timeIntervalSince1970 // fallback
        }
        // Write as CSV row with header: wall_clock,roll,pitch,yaw,rotX,rotY,rotZ,accX,accY,accZ,gravX,gravY,gravZ
        let row = String(format: "%0.6f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f\n", wallClock, imu.attitude.roll, imu.attitude.pitch, imu.attitude.yaw, imu.rotationRate.x, imu.rotationRate.y, imu.rotationRate.z, imu.userAcceleration.x, imu.userAcceleration.y, imu.userAcceleration.z, imu.gravity.x, imu.gravity.y, imu.gravity.z)
        handle.write(row.data(using: .utf8)!)
    }

    private func saveMeshOBJ(anchors: [ARMeshAnchor], to url: URL) throws {
        var objLines: [String] = []
        var vertexOffset: Int32 = 0
        for anchor in anchors {
            let geometry = anchor.geometry

            // Extract vertices from ARGeometrySource buffer
            let vertexSource = geometry.vertices
            let vertexBuffer = vertexSource.buffer.contents().bindMemory(to: SIMD3<Float>.self,
                                                                        capacity: vertexSource.count)
            for v in 0..<vertexSource.count {
                let vertex = vertexBuffer[v]
                let world = anchor.transform * SIMD4<Float>(vertex, 1)
                objLines.append(String(format: "v %f %f %f", world.x, world.y, world.z))
            }

            // Extract triangle indices from ARGeometryElement buffer
            let faces = geometry.faces
            let indexBuffer = faces.buffer.contents().bindMemory(to: UInt32.self,
                                                                 capacity: faces.count * 3)
            for f in 0..<faces.count {
                let base = f * 3
                let i0 = Int32(indexBuffer[base])
                let i1 = Int32(indexBuffer[base + 1])
                let i2 = Int32(indexBuffer[base + 2])
                objLines.append("f \(i0 + 1 + vertexOffset) \(i1 + 1 + vertexOffset) \(i2 + 1 + vertexOffset)")
            }

            vertexOffset += Int32(vertexSource.count)
        }
        let data = objLines.joined(separator: "\n")
        try data.write(to: url, atomically: true, encoding: .utf8)
    }
    
    private func saveDepthData(_ depthMap: CVPixelBuffer, timestamp: TimeInterval, frameIndex: Int) {
    // ...existing code...
    }

    // Helper for scan folder naming
    private static let scanFolderDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmssSSS" // Increased precision for unique folder names
        return df
    }()
}
