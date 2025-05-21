// RecordingManager.swift
// roboclip
//
// Handles writing video, depth, and IMU data to disk.

import Foundation
import AVFoundation
import ARKit
import CoreMotion

class RecordingManager {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var depthFileHandle: FileHandle?
    private var imuFileHandle: FileHandle?
    private var outputDirectory: URL?
    private var isRecording = false
    private var pixelBufferPool: CVPixelBufferPool?
    private var cameraIntrinsics: simd_float3x3?
    private var recordingStartTime: CMTime?

    func setCameraIntrinsics(_ m: simd_float3x3) { cameraIntrinsics = m }
    
    func startRecording() {
        MCP.log("RecordingManager.startRecording() called")
        let fileManager = FileManager.default
        MCP.log("RecordingManager temp dir: \(fileManager.temporaryDirectory.path)")
        let timestamp = RecordingManager.scanFolderName.string(from: Date())
        let dir = fileManager.temporaryDirectory.appendingPathComponent("Scan-\(timestamp)")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        outputDirectory = dir
        recordingStartTime = nil
        // Video
        let videoURL = dir.appendingPathComponent("video.mov")
        assetWriter = try? AVAssetWriter(url: videoURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        if let assetWriter = assetWriter, let videoInput = videoInput {
            assetWriter.add(videoInput)
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                kCVPixelBufferWidthKey as String: 1920,
                kCVPixelBufferHeightKey as String: 1080,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: attrs)
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pixelBufferPool)
        }
        assetWriter?.startWriting()
        assetWriter?.startSession(atSourceTime: .zero)
        // Depth
        let depthDir = dir.appendingPathComponent("depth")
        try? fileManager.createDirectory(at: depthDir, withIntermediateDirectories: true)
        // IMU
        let imuURL = dir.appendingPathComponent("imu.bin")
        fileManager.createFile(atPath: imuURL.path, contents: nil)
        imuFileHandle = try? FileHandle(forWritingTo: imuURL)
        isRecording = true
        MCP.log("RecordingManager: Created scan directory at \(dir.path)")
    }
    
    func stopRecording(completion: (() -> Void)? = nil) {
        isRecording = false
        recordingStartTime = nil
        videoInput?.markAsFinished()
        
        // Close file handles first
        depthFileHandle?.closeFile()
        imuFileHandle?.closeFile()
        MCP.log("RecordingManager: Closed depth and IMU file handles.")

        // Write meta.json immediately
        var metaWritten = false
        if let dir = self.outputDirectory {
            let metaURL = dir.appendingPathComponent("meta.json")
            var meta: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: Date()),
                "device": UIDevice.current.model,
                "systemVersion": UIDevice.current.systemVersion,
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
            ]
            if let intrinsics = self.cameraIntrinsics {
                meta["cameraIntrinsics"] = [ // Storing as array of arrays (rows)
                    [intrinsics.columns.0.x, intrinsics.columns.1.x, intrinsics.columns.2.x], // Row 1
                    [intrinsics.columns.0.y, intrinsics.columns.1.y, intrinsics.columns.2.y], // Row 2
                    [intrinsics.columns.0.z, intrinsics.columns.1.z, intrinsics.columns.2.z]  // Row 3
                ]
                 // Also store fx, fy, cx, cy directly for easier access by Python script
                meta["intrinsics"] = [
                    "fx": intrinsics.columns.0.x,
                    "fy": intrinsics.columns.1.y,
                    "cx": intrinsics.columns.2.x,
                    "cy": intrinsics.columns.2.y
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted) {
                do {
                    try data.write(to: metaURL)
                    MCP.log("RecordingManager: Wrote meta.json to \(metaURL.path)")
                    metaWritten = true
                } catch {
                    MCP.log("RecordingManager: ERROR writing meta.json: \(error)")
                }
            }
        } else {
            MCP.log("RecordingManager: ERROR - outputDirectory is nil, cannot write meta.json.")
        }

        assetWriter?.finishWriting { [weak self] in
            MCP.log("RecordingManager: AVAssetWriter finished writing.")
            // MCP validation: check all files exist
            if let dir = self?.outputDirectory {
                let videoExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent("video.mov").path)
                let imuExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent("imu.bin").path)
                let depthDir = dir.appendingPathComponent("depth")
                let depthFiles = (try? FileManager.default.contentsOfDirectory(atPath: depthDir.path)) ?? []
                let metaExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent("meta.json").path)
                MCP.log("Validation: video.mov=\(videoExists), imu.bin=\(imuExists), depth/ count=\(depthFiles.count), meta.json=\(metaExists)")
                
                if videoExists && imuExists && metaExists { // Assuming depth can be empty but dir exists
                     MCP.log("All essential files present. Calling completion for upload.")
                } else {
                    MCP.log("WARNING: Not all essential files present. Upload might be incomplete.")
                }
            }
            completion?() // Call completion after everything, including meta.json attempt
        }
    }
    
    func appendVideoFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard isRecording, let input = videoInput, let adaptor = pixelBufferAdaptor, input.isReadyForMoreMediaData else { return }
        // Set recordingStartTime if this is the first frame
        if recordingStartTime == nil {
            recordingStartTime = time
        }
        guard let start = recordingStartTime else { return }
        let relativeTime = CMTimeSubtract(time, start)
        // If the buffer is already compatible, append directly
        if let pool = pixelBufferPool {
            var reusableBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &reusableBuffer)
            if let reusableBuffer = reusableBuffer {
                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                CVPixelBufferLockBaseAddress(reusableBuffer, [])
                let srcPlaneCount = CVPixelBufferGetPlaneCount(pixelBuffer)
                let dstPlaneCount = CVPixelBufferGetPlaneCount(reusableBuffer)
                if srcPlaneCount == dstPlaneCount && srcPlaneCount > 0 {
                    // Multi-plane (e.g., NV12)
                    for plane in 0..<srcPlaneCount {
                        let srcBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
                        let dstBase = CVPixelBufferGetBaseAddressOfPlane(reusableBuffer, plane)
                        let height = min(CVPixelBufferGetHeightOfPlane(pixelBuffer, plane), CVPixelBufferGetHeightOfPlane(reusableBuffer, plane))
                        let bytesPerRow = min(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane), CVPixelBufferGetBytesPerRowOfPlane(reusableBuffer, plane))
                        if let srcBase = srcBase, let dstBase = dstBase, height > 0, bytesPerRow > 0 {
                            for row in 0..<height {
                                let srcPtr = srcBase.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane))
                                let dstPtr = dstBase.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(reusableBuffer, plane))
                                memcpy(dstPtr, srcPtr, bytesPerRow)
                            }
                        }
                    }
                } else if srcPlaneCount == 0 && dstPlaneCount == 0 {
                    // Single-plane (e.g., RGB, Grayscale)
                    if let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer), let dstBase = CVPixelBufferGetBaseAddress(reusableBuffer) {
                        let height = min(CVPixelBufferGetHeight(pixelBuffer), CVPixelBufferGetHeight(reusableBuffer))
                        let bytesPerRow = min(CVPixelBufferGetBytesPerRow(pixelBuffer), CVPixelBufferGetBytesPerRow(reusableBuffer))
                        memcpy(dstBase, srcBase, height * bytesPerRow)
                    }
                } else {
                    MCP.log("appendVideoFrame: plane count mismatch or unsupported format, falling back to original buffer")
                    adaptor.append(pixelBuffer, withPresentationTime: relativeTime)
                    CVPixelBufferUnlockBaseAddress(reusableBuffer, [])
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                    return
                }
                CVPixelBufferUnlockBaseAddress(reusableBuffer, [])
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                adaptor.append(reusableBuffer, withPresentationTime: relativeTime)
            } else {
                // Fallback: use the original buffer
                adaptor.append(pixelBuffer, withPresentationTime: relativeTime)
            }
        } else {
            // No pool, just append
            adaptor.append(pixelBuffer, withPresentationTime: relativeTime)
        }
    }
    
    func appendDepthData(_ depth: ARDepthData) {
        guard isRecording, let dir = outputDirectory else { return }
        let fileManager = FileManager.default
        let depthDir = dir.appendingPathComponent("depth")
        let frameIdx = (try? fileManager.contentsOfDirectory(atPath: depthDir.path).count) ?? 0
        let fileURL = depthDir.appendingPathComponent(String(format: "%06d.d16", frameIdx))
        let buffer = depth.depthMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let size = CVPixelBufferGetDataSize(buffer)
            let data = Data(bytes: base, count: size)
            try? data.write(to: fileURL)
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }
    
    func appendIMUData(_ imu: (timestamp: TimeInterval, attitude: CMAttitude, rotationRate: CMRotationRate, userAcceleration: CMAcceleration, gravity: CMAcceleration)) {
        guard isRecording, let handle = imuFileHandle else { return }
        // Example: Write as CSV row
        let row = String(format: "%f,%f,%f,%f,%f,%f,%f,%f,%f,%f\n", imu.timestamp, imu.attitude.roll, imu.attitude.pitch, imu.attitude.yaw, imu.rotationRate.x, imu.rotationRate.y, imu.rotationRate.z, imu.userAcceleration.x, imu.userAcceleration.y, imu.userAcceleration.z)
        if let data = row.data(using: String.Encoding.utf8) {
            handle.write(data)
        }
    }
    
    private func saveDepthData(_ depthMap: CVPixelBuffer, timestamp: TimeInterval, frameIndex: Int) {
        let depthFilename = String(format: "depth_%05d_%f.d16", frameIndex, timestamp)
        let depthFileURL = outputDirectory?.appendingPathComponent("depth").appendingPathComponent(depthFilename)

        guard let fileURL = depthFileURL else {
            print("Error: Depth file URL is nil.")
            return
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            print("Error: Could not get base address of depth map.")
            return
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        
        // Ensure we are saving raw Float32 data, tightly packed.
        // ARKit kCVPixelFormatType_DepthFloat32 is typically Float32 in meters.
        // The data size should be width * height * size_of_float.
        let expectedPixelFormat = kCVPixelFormatType_DepthFloat32
        let actualPixelFormat = CVPixelBufferGetPixelFormatType(depthMap)

        if actualPixelFormat != expectedPixelFormat {
            print("Warning: Depth map pixel format is \(actualPixelFormat) (expected \(expectedPixelFormat)). Data might not be Float32 meters.")
            // Consider converting or handling this case if other formats are possible.
        }

        // Calculate the size of the data assuming it's tightly packed Float32.
        let dataSize = width * height * MemoryLayout<Float32>.stride 

        let data = Data(bytes: baseAddress, count: dataSize)

        do {
            try data.write(to: fileURL)
            // print("Saved depth frame: \(depthFilename)")
        } catch {
            print("Error writing depth data to \(fileURL): \(error)")
        }
    }

    // Helper for scan folder naming
    private static let scanFolderDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        return df
    }()

    private static var scanFolderName: DateFormatter {
        scanFolderDateFormatter
    }
}
