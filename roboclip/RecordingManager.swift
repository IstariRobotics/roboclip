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
    
    func startRecording() {
        let fileManager = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
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
            // Create a pool for pixel buffer reuse
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pixelBufferPool)
        }
        assetWriter?.startWriting()
        assetWriter?.startSession(atSourceTime: .zero)
        // Depth
        let depthURL = dir.appendingPathComponent("depth.bin")
        fileManager.createFile(atPath: depthURL.path, contents: nil)
        depthFileHandle = try? FileHandle(forWritingTo: depthURL)
        // IMU
        let imuURL = dir.appendingPathComponent("imu.bin")
        fileManager.createFile(atPath: imuURL.path, contents: nil)
        imuFileHandle = try? FileHandle(forWritingTo: imuURL)
        isRecording = true
    }
    
    func stopRecording() {
        isRecording = false
        videoInput?.markAsFinished()
        assetWriter?.finishWriting {}
        depthFileHandle?.closeFile()
        imuFileHandle?.closeFile()
    }
    
    func appendVideoFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard isRecording, let input = videoInput, let adaptor = pixelBufferAdaptor, input.isReadyForMoreMediaData else { return }
        // Use the pool to get a reusable buffer
        var reusableBuffer: CVPixelBuffer?
        if let pool = pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &reusableBuffer)
        }
        if let reusableBuffer = reusableBuffer {
            // Copy the frame data into the reusable buffer
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferLockBaseAddress(reusableBuffer, [])
            let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer)
            let dstBase = CVPixelBufferGetBaseAddress(reusableBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            memcpy(dstBase, srcBase, height * bytesPerRow)
            CVPixelBufferUnlockBaseAddress(reusableBuffer, [])
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            adaptor.append(reusableBuffer, withPresentationTime: time)
        } else {
            // Fallback: use the original buffer
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }
    }
    
    func appendDepthData(_ depth: ARDepthData) {
        guard isRecording, let handle = depthFileHandle else { return }
        // Example: Write depth map as raw float16 data
        let buffer = depth.depthMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let size = CVPixelBufferGetDataSize(buffer)
            handle.write(Data(bytes: base, count: size))
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
}
