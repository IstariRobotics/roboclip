// ARPreviewView.swift
// roboclip
//
// Created by James Ball on 20/05/2025.

import SwiftUI
import ARKit
import UIKit
import CoreMotion

struct ARPreviewView: UIViewRepresentable {
    @Binding var isRecording: Bool

    class Coordinator: NSObject, ARSessionDelegate {
        let session = ARSession()
        let motionManager = CMMotionManager()
        var imuData: [(timestamp: TimeInterval, attitude: CMAttitude, rotationRate: CMRotationRate, userAcceleration: CMAcceleration, gravity: CMAcceleration)] = []
        
        // Frame buffer for synchronized data
        struct SyncedFrame {
            let timestamp: TimeInterval
            let cameraTransform: simd_float4x4
            // Optionally, you can store pixel buffer copies if needed for processing
        }
        var syncedFrames: [SyncedFrame] = []
        let maxFrames = 3 // Only keep a few frames to avoid memory issues

        var recordingManager: RecordingManager? = nil
        var isRecording: Bool = false
        var cameraIntrinsics: simd_float3x3? = nil
        var imageResolution: CGSize? = nil // Store image resolution

        // Queues for threading
        let captureQueue = DispatchQueue(label: "com.roboclip.capture")
        let encodeQueue = DispatchQueue(label: "com.roboclip.encode")
        let motionQueue = OperationQueue()

        var parent: ARPreviewView

        init(parent: ARPreviewView) {
            self.parent = parent
            super.init()
            session.delegate = self
            // Monitor thermal state changes
            NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
                let state = ProcessInfo.processInfo.thermalState
                MCP.log("Thermal state changed: \(state.rawValue)")
            }
            
            // Start IMU updates on motionQueue (OperationQueue)
            if motionManager.isDeviceMotionAvailable {
                motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // Recommended for AR
                motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
                    guard let self = self, let motion = motion else { return }
                    
                    let entry = (timestamp: motion.timestamp, attitude: motion.attitude, rotationRate: motion.rotationRate, userAcceleration: motion.userAcceleration, gravity: motion.gravity)
                    
                    // Safely append to imuData - this array is only modified on this motionQueue
                    self.imuData.append(entry)
                    // Keep imuData buffer from growing indefinitely
                    if self.imuData.count > 300 { // Approx 5 seconds of data at 60Hz
                        self.imuData.removeFirst()
                    }
                    
                    // Access recordingManager and isRecording state carefully
                    // Check isRecording flag first, then safely unwrap recordingManager
                    if self.isRecording, let manager = self.recordingManager {
                        manager.appendIMUData(entry)
                    }
                    
                    // Logging (consider reducing frequency or removing for release)
                    // DispatchQueue.main.async {
                    //     MCP.log("IMU: t=\(motion.timestamp), roll=\(motion.attitude.roll), pitch=\(motion.attitude.pitch), yaw=\(motion.attitude.yaw)")
                    // }
                }
            } else {
                MCP.log("IMU not available on this device.")
            }
        }
        
        deinit {
            // Clean up resources
            motionManager.stopDeviceMotionUpdates()
            recordingManager?.stopRecording()
            session.pause()
            MCP.log("Coordinator deinitialized: resources released.")
        }
        
        func startSession() {
            let config = ARWorldTrackingConfiguration()
            config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
            if let videoFormat = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
                config.videoFormat = videoFormat
            }
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
            MCP.log("ARKit session started with sceneDepth and high-res video.")
        }
        
        func startRecording(device: MTLDevice) { // Add MTLDevice parameter
            MCP.log("Coordinator.startRecording() called")
            recordingManager = RecordingManager()
            // Pass device and session to RecordingManager's startRecording
            recordingManager?.startRecording(device: device, arSession: self.session)
            isRecording = true
            MCP.log("Recording started.")
        }
        
        func stopRecording() {
            if let intrinsics = cameraIntrinsics, let resolution = imageResolution {
                recordingManager?.setCameraIntrinsics(intrinsics, imageResolution: resolution)
            } else {
                MCP.log("Error: Camera intrinsics or image resolution not available for meta.json")
            }
            recordingManager?.stopRecording()
            isRecording = false
            MCP.log("Recording stopped.")
        }
        
        func updateRecordingState(device: MTLDevice) { // Add MTLDevice parameter
            if parent.isRecording && !isRecording {
                startRecording(device: device) // Pass device
            } else if !parent.isRecording && isRecording {
                stopRecording()
            }
        }
        
        func session(_ session: ARSession, didFailWithError error: Error) {
            MCP.log("ARKit session failed: \(error.localizedDescription)")
        }
        
        func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
            MCP.log("ARKit camera tracking state: \(camera.trackingState)")
        }

        // ARSessionDelegate: called every frame
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // Thermal guard: downsample LiDAR if thermalState is serious
            let thermalState = ProcessInfo.processInfo.thermalState
            if thermalState == .serious || thermalState == .critical {
                // Example: skip every other frame to reduce load
                if Int(frame.timestamp * 10) % 2 == 0 { return }
                DispatchQueue.main.async {
                    MCP.log("Thermal guard active: downsampling LiDAR frames (thermalState=\(thermalState.rawValue))")
                }
            }

            captureQueue.async { [weak self] in
                guard let self = self else { return }
                let timestamp = frame.timestamp
                let cameraTransform = frame.camera.transform
                let synced = SyncedFrame(timestamp: timestamp, cameraTransform: cameraTransform)
                self.syncedFrames.append(synced)
                if self.syncedFrames.count > self.maxFrames {
                    self.syncedFrames.removeFirst()
                }
                let depthStatus = frame.sceneDepth != nil ? "depth=present" : "depth=absent"
                DispatchQueue.main.async {
                    MCP.log("Frame: t=\(timestamp), \(depthStatus), pose=\(cameraTransform.columns.3)")
                }
                if self.cameraIntrinsics == nil {
                    self.cameraIntrinsics = frame.camera.intrinsics
                    // Capture image resolution when intrinsics are first captured
                    let capturedImagePixelBuffer = frame.capturedImage
                    self.imageResolution = CGSize(width: CVPixelBufferGetWidth(capturedImagePixelBuffer), height: CVPixelBufferGetHeight(capturedImagePixelBuffer))
                    MCP.log("Captured camera intrinsics and image resolution: \(self.imageResolution!)")
                }
                if self.isRecording {
                    let time = CMTime(seconds: frame.timestamp, preferredTimescale: 600)
                    self.encodeQueue.async {
                        self.recordingManager?.appendVideoFrame(frame.capturedImage, at: time)
                        if let depth = frame.sceneDepth {
                            // Use depth.depthMap for CVPixelBuffer and add timestamp
                            self.recordingManager?.appendDepthData(depthData: depth.depthMap, timestamp: frame.timestamp)
                        }
                    }
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(parent: self)
        coordinator.startSession()
        return coordinator
    }
    
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = context.coordinator.session
        view.automaticallyUpdatesLighting = true
        return view
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {
        guard let device = uiView.device else {
            MCP.log("Error: MTLDevice not available in ARSCNView. Cannot update recording state.")
            return
        }
        context.coordinator.updateRecordingState(device: device) // Pass unwrapped device
    }
} 

// MARK: - MCP Logging
final class MCP {
    static func log(_ message: String) {
        print("[DEBUG] " + message)
    }
}
