// ARPreviewView.swift
// roboclip
//
// Created by James Ball on 20/05/2025.

import SwiftUI
import ARKit
import UIKit
import CoreMotion

struct ARPreviewView: UIViewRepresentable {
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

        // Queues for threading
        let captureQueue = DispatchQueue(label: "com.roboclip.capture")
        let encodeQueue = DispatchQueue(label: "com.roboclip.encode")
        let motionQueue = OperationQueue()

        override init() {
            super.init()
            session.delegate = self
            // Monitor thermal state changes
            NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
                let state = ProcessInfo.processInfo.thermalState
                MCP.log("Thermal state changed: \(state.rawValue)")
            }
            
            // Start IMU updates on motionQueue (OperationQueue)
            if motionManager.isDeviceMotionAvailable {
                motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
                motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
                    guard let self = self, let motion = motion else { return }
                    let entry = (timestamp: motion.timestamp, attitude: motion.attitude, rotationRate: motion.rotationRate, userAcceleration: motion.userAcceleration, gravity: motion.gravity)
                    self.imuData.append(entry)
                    if self.imuData.count > 300 { self.imuData.removeFirst() }
                    if self.isRecording {
                        self.recordingManager?.appendIMUData(entry)
                    }
                    DispatchQueue.main.async {
                        MCP.log("IMU: t=\(motion.timestamp), roll=\(motion.attitude.roll), pitch=\(motion.attitude.pitch), yaw=\(motion.attitude.yaw)")
                    }
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
        
        func startRecording() {
            recordingManager = RecordingManager()
            recordingManager?.startRecording()
            isRecording = true
            MCP.log("Recording started.")
        }
        
        func stopRecording() {
            recordingManager?.stopRecording()
            isRecording = false
            MCP.log("Recording stopped.")
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
                if self.isRecording {
                    let time = CMTime(seconds: frame.timestamp, preferredTimescale: 600)
                    self.encodeQueue.async {
                        self.recordingManager?.appendVideoFrame(frame.capturedImage, at: time)
                        if let depth = frame.sceneDepth {
                            self.recordingManager?.appendDepthData(depth)
                        }
                    }
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.startSession()
        return coordinator
    }
    
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = context.coordinator.session
        view.automaticallyUpdatesLighting = true
        return view
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: - MCP Logging
final class MCP {
    static func log(_ message: String) {
        print("[DEBUG] " + message)
    }
}
