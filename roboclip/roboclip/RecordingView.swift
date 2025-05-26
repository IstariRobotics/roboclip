// RecordingView.swift
// roboclip
//
// Main recording interface with dynamic UI orientation support

import SwiftUI
import Foundation

struct RecordingView: View {
    @Binding var isRecording: Bool
    @State private var startTime: Date? = nil
    @State private var timer: Timer? = nil
    @State private var elapsed: TimeInterval = 0
    @State private var showConfirmation = false
    @State private var pendingStop = false // Used to manage state during confirmation
    @State private var showCameraSettings = false

    @EnvironmentObject private var uploader: SupabaseUploader
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass // Corrected key path syntax
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ARPreviewView(isRecording: $isRecording)
                .id(isRecording) // Re-create view if isRecording changes, might be useful for ARKit state
                .ignoresSafeArea() // Use ignoresSafeArea for newer SwiftUI versions

            // Determine if the device is in landscape orientation
            let isLandscape: Bool = {
                // Prefer checking against actual device orientation if possible,
                // but size classes are the SwiftUI way.
                // This logic is a common approximation for iPhones.
                // On iPad, .compact width can occur in portrait.
                if verticalSizeClass == .compact { return true } // Most reliable indicator for landscape on iPhone
                // Fallback for some edge cases or specific device types if needed,
                // but verticalSizeClass == .compact is generally sufficient for iPhone landscape.
                return false
            }()

            VStack(spacing: 0) { // Main VStack for controls
                // Top Controls (Timer and Back Button)
                HStack {
                    // Back button - always on the left
                    Button(action: handleBackButton) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.3))
                            .clipShape(Circle())
                    }
                    .padding(.leading)

                    if isRecording { // Only show timer when recording
                        if isLandscape { // Landscape: Timer after back button
                            BlinkingDot()
                                .padding(.leading, 8)
                            Text(timerString)
                                .font(.system(.body, design: .monospaced).weight(.medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.4).cornerRadius(8)) // Better contrast with white text
                            Spacer() // Pushes content to the left
                        } else { // Portrait: Timer on the top-right
                            Spacer() // Pushes timer to the right
                            BlinkingDot()
                            Text(timerString)
                                .font(.system(.body, design: .monospaced).weight(.medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.4).cornerRadius(8)) // Better contrast with white text
                        }
                    } else {
                        Spacer() // Pushes content to center/right
                    }
                    
                    // Camera settings button (always visible)
                    Button(action: { showCameraSettings = true }) {
                        Image(systemName: "camera.badge.ellipsis")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.3))
                            .clipShape(Circle())
                    }
                    .padding(.trailing)
                }
                .padding(.top, isLandscape ? 20 : 20) // Simplified padding

                Spacer() // Pushes controls to top and bottom

                // Bottom Controls (Record Button)
                HStack {
                    if isLandscape { // Landscape: Button on the right, vertically somewhat centered by Spacer
                        Spacer() // Pushes button to the right
                        RecordButton(isRecording: isRecording, action: handleRecordButtonTap)
                            .padding(.trailing, 40) // Padding from the edge
                            .padding(.bottom, 20) // Padding from bottom
                    } else { // Portrait: Button at the bottom-center
                        Spacer()
                        RecordButton(isRecording: isRecording, action: handleRecordButtonTap)
                        Spacer()
                    }
                }
                .padding(.bottom, isLandscape ? 20 : 34) // Simplified padding (34 is a common bottom safe area for iPhones)
            }
        }
        .confirmationDialog("Finish Recording?", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Save Recording") {
                completeRecording(shouldSave: true)
            }
            Button("Delete Recording", role: .destructive) {
                completeRecording(shouldSave: false)
            }
            Button("Cancel", role: .cancel) {
                resumeRecordingAfterCancel()
            }
        } message: {
            Text("Do you want to save or delete this recording?")
        }
        .sheet(isPresented: $showCameraSettings) {
            CameraSettingsView()
        }
        // .navigationBarHidden(true) // Keep it immersive - Original line
        // Conditional navigationBarHidden for iOS
        #if os(iOS)
        .navigationBarHidden(true)
        #endif
        .onAppear {
            print("RecordingView appeared. isRecording: \(isRecording)") // Using print temporarily
            if isRecording && timer == nil { // If view appears while already recording (e.g. app resume)
                // Ensure timer is running if isRecording is true from a previous state.
                // This might need more robust state restoration depending on app lifecycle.
                startTimer()
            }
        }
        .onChange(of: isRecording) { _, newValue in
             print("isRecording changed to: \(newValue)") // Using print temporarily
             if !newValue && timer != nil { // If recording is stopped externally
                 stopTimer()
                 // Optionally trigger confirmation or auto-save/delete here
             }
        }
    }

    private func handleBackButton() {
        if isRecording {
            // If recording, stop and show confirmation before going back
            timer?.invalidate() // Pause timer updates while confirming
            pendingStop = true
            showConfirmation = true
            print("Back button tapped while recording. Showing confirmation.")
        } else {
            // If not recording, go back immediately
            dismiss()
            print("Back button tapped. Returning to home.")
        }
    }

    private func handleRecordButtonTap() {
        if isRecording {
            // Currently recording, so stop and show confirmation
            timer?.invalidate() // Pause timer updates while confirming
            pendingStop = true
            showConfirmation = true
            print("Record button tapped to STOP. Showing confirmation.")
        } else {
            // Not recording, so start
            isRecording = true // This will trigger ARRecorder to start
            startTimer()
            print("Record button tapped to START.")
        }
    }

    private func startTimer() {
        startTime = Date().addingTimeInterval(-elapsed) // Preserve elapsed time if resuming
        timer?.invalidate() // Ensure no multiple timers
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            if let start = startTime {
                elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        // Elapsed time is preserved
    }

    private func completeRecording(shouldSave: Bool) {
        stopTimer()
        isRecording = false // This will trigger ARRecorder to stop
        pendingStop = false

        if shouldSave {
            print("User chose to SAVE recording. Elapsed: \(timerString)")
            // ARRecorder should have saved the data. Now trigger upload.
            uploader.refreshPendingUploads() // Tell uploader to look for new sessions
            uploader.startUploadProcess()
        } else {
            print("User chose to DELETE recording. Elapsed: \(timerString)")
            // Delete the just-recorded session files
            uploader.deleteLastRecordingSession()
        }
        elapsed = 0 // Reset for next recording
        
        // Return to home view after completing recording
        dismiss()
    }

    private func resumeRecordingAfterCancel() {
        if pendingStop {
            // If we were about to stop, but user cancelled, resume the timer.
            // isRecording should still be true at this point.
            startTimer() // Restart timer
            pendingStop = false
            print("User cancelled stop confirmation. Resuming recording.")
        }
    }

    var timerString: String {
        let minutes = Int(elapsed) / 60
        let seconds = elapsed.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%05.2f", minutes, seconds)
    }
}

struct BlinkingDot: View {
    @State private var visible = true
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 12, height: 12) // Slightly smaller
            .opacity(visible ? 1 : 0.3)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: visible)
            .onAppear { visible.toggle() } // Start animation
    }
}

// Example Preview (ensure your App's main preview setup provides necessary EnvironmentObjects)
#if DEBUG
struct RecordingView_Previews: PreviewProvider {
    static var previews: some View {
        // Mock isRecording state for preview
        @State var mockIsRecording_Portrait = false
        @State var mockIsRecording_Landscape = true // Start landscape preview as recording

        // Mock Uploader
        let mockAuthManager = AuthManager()
        let mockUploader = SupabaseUploader(authManager: mockAuthManager)

        return Group {
            RecordingView(isRecording: $mockIsRecording_Portrait)
                .environmentObject(mockUploader)
                .previewDisplayName("Portrait - Not Recording")

            RecordingView(isRecording: $mockIsRecording_Landscape)
                .environmentObject(mockUploader)
                .previewInterfaceOrientation(.landscapeRight)
                .previewDisplayName("Landscape - Recording")
        }
    }
}
#endif
