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

    func setCameraIntrinsics(_ m: simd_float3x3) { cameraIntrinsics = m }
    
    func startRecording() {
        MCP.log("RecordingManager.startRecording() called")
        let fileManager = FileManager.default
        MCP.log("RecordingManager temp dir: \(fileManager.temporaryDirectory.path)")
        let timestamp = RecordingManager.scanFolderName.string(from: Date())
        let dir = fileManager.temporaryDirectory.appendingPathComponent("Scan-\(timestamp)")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        outputDirectory = dir
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
    
    func stopRecording() {
        isRecording = false
        videoInput?.markAsFinished()
        assetWriter?.finishWriting {}
        depthFileHandle?.closeFile()
        imuFileHandle?.closeFile()
        // Write meta.json
        if let dir = outputDirectory {
            let metaURL = dir.appendingPathComponent("meta.json")
            var meta: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: Date()),
                "device": UIDevice.current.model,
                "systemVersion": UIDevice.current.systemVersion,
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
            ]
            if let intrinsics = cameraIntrinsics {
                meta["cameraIntrinsics"] = [
                    [intrinsics.columns.0.x, intrinsics.columns.0.y, intrinsics.columns.0.z],
                    [intrinsics.columns.1.x, intrinsics.columns.1.y, intrinsics.columns.1.z],
                    [intrinsics.columns.2.x, intrinsics.columns.2.y, intrinsics.columns.2.z]
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted) {
                try? data.write(to: metaURL)
                MCP.log("RecordingManager: Wrote meta.json to \(metaURL.path)")
            }
            // MCP validation: check all files exist
            let videoExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent("video.mov").path)
            let imuExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent("imu.bin").path)
            let depthDir = dir.appendingPathComponent("depth")
            let depthFiles = (try? FileManager.default.contentsOfDirectory(atPath: depthDir.path)) ?? []
            let metaExists = FileManager.default.fileExists(atPath: metaURL.path)
            MCP.log("Validation: video.mov=\(videoExists), imu.bin=\(imuExists), depth/ count=\(depthFiles.count), meta.json=\(metaExists)")
        }
    }
    
    func appendVideoFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard isRecording, let input = videoInput, let adaptor = pixelBufferAdaptor, input.isReadyForMoreMediaData else { return }
        // Use the pool to get a reusable buffer
        var reusableBuffer: CVPixelBuffer?
        if let pool = pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &reusableBuffer)
        }
        if let reusableBuffer = reusableBuffer {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferLockBaseAddress(reusableBuffer, [])
            let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer)
            let dstBase = CVPixelBufferGetBaseAddress(reusableBuffer)
            let height = min(CVPixelBufferGetHeight(pixelBuffer), CVPixelBufferGetHeight(reusableBuffer))
            let bytesPerRow = min(CVPixelBufferGetBytesPerRow(pixelBuffer), CVPixelBufferGetBytesPerRow(reusableBuffer))
            if let srcBase = srcBase, let dstBase = dstBase, height > 0, bytesPerRow > 0 {
                memcpy(dstBase, srcBase, height * bytesPerRow)
                CVPixelBufferUnlockBaseAddress(reusableBuffer, [])
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                adaptor.append(reusableBuffer, withPresentationTime: time)
            } else {
                CVPixelBufferUnlockBaseAddress(reusableBuffer, [])
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                MCP.log("appendVideoFrame: nil base address or invalid size, falling back to original buffer")
                adaptor.append(pixelBuffer, withPresentationTime: time)
            }
        } else {
            // Fallback: use the original buffer
            adaptor.append(pixelBuffer, withPresentationTime: time)
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
