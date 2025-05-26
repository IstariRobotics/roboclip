// ARPreviewView.swift
// roboclip
//
// Created by James Ball on 20/05/2025.

import SwiftUI
import ARKit
import UIKit
import CoreMotion

struct ARPreviewView: View {
    @Binding var isRecording: Bool
    
    var body: some View {
        ARKitLiveView(isRecording: $isRecording)
    }
}

// MARK: - ARKit Live View (Traditional)
struct ARKitLiveView: UIViewRepresentable {
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

        var parent: ARKitLiveView

        init(parent: ARKitLiveView) {
            self.parent = parent
            super.init()

            motionQueue.name = "com.roboclip.motionQueue" // Name the queue for easier debugging
            motionQueue.maxConcurrentOperationCount = 1    // Ensure serial execution of motion updates

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
            
            // Enable plane detection to help establish world coordinate system
            config.planeDetection = [.horizontal, .vertical]
            
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
            } else {
                MCP.log("Scene reconstruction not supported on this device")
            }
            if let videoFormat = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
                config.videoFormat = videoFormat
            }
            
            // Use less aggressive reset options to preserve world tracking
            session.run(config, options: [.removeExistingAnchors])
            MCP.log("ARKit session started with sceneDepth, mesh reconstruction, plane detection, and high-res video.")
        }
        
        func startRecording() {
            MCP.log("Coordinator.startRecording() called")
            recordingManager = RecordingManager()
            
            recordingManager?.startRecording(arSession: self.session)
            isRecording = true
            MCP.log("Recording started")
        }
        
        func stopRecording() {
            if let intrinsics = cameraIntrinsics, let resolution = imageResolution {
                recordingManager?.setCameraIntrinsics(intrinsics, imageResolution: resolution)
            } else {
                MCP.log("Error: Camera intrinsics or image resolution not available for meta.json")
            }
            session.getCurrentWorldMap { [weak self] map, error in
                if let map = map, let data = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true) {
                    self?.recordingManager?.setWorldMapData(data)
                }
                self?.recordingManager?.stopRecording()
                self?.isRecording = false
                MCP.log("Recording stopped.")
            }
        }
        
        func updateRecordingState() {
            if parent.isRecording && !isRecording {
                startRecording()
            } else if !parent.isRecording && isRecording {
                stopRecording()
            }
        }
        
        func session(_ session: ARSession, didFailWithError error: Error) {
            MCP.log("ARKit session failed: \(error.localizedDescription)")
        }
        
        func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
            let stateString: String
            switch camera.trackingState {
            case .normal:
                stateString = "normal"
            case .limited(let reason):
                switch reason {
                case .excessiveMotion:
                    stateString = "limited(excessiveMotion)"
                case .insufficientFeatures:
                    stateString = "limited(insufficientFeatures)"
                case .initializing:
                    stateString = "limited(initializing)"
                case .relocalizing:
                    stateString = "limited(relocalizing)"
                @unknown default:
                    stateString = "limited(unknown)"
                }
            case .notAvailable:
                stateString = "notAvailable"
            @unknown default:
                stateString = "unknown"
            }
            MCP.log("ARKit camera tracking state changed to: \(stateString)")
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
                
                // Debug camera position
                let translation = cameraTransform.columns.3
                let position = simd_float3(translation.x, translation.y, translation.z)
                
                DispatchQueue.main.async {
                    MCP.log("Frame: t=\(timestamp), \(depthStatus), pose=\(cameraTransform.columns.3), trackingState=\(frame.camera.trackingState), position=\(position)")
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
                        self.recordingManager?.appendCameraPose(cameraTransform, timestamp: frame.timestamp)
                    }
                }
            }
        }

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            for anchor in anchors {
                if let meshAnchor = anchor as? ARMeshAnchor {
                    recordingManager?.addMeshAnchor(meshAnchor)
                }
            }
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            for anchor in anchors {
                if let meshAnchor = anchor as? ARMeshAnchor {
                    recordingManager?.addMeshAnchor(meshAnchor)
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
        context.coordinator.updateRecordingState()
    }
}
