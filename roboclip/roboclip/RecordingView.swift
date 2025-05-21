import SwiftUI

struct RecordingView: View {
    @Binding var isRecording: Bool
    @State private var startTime: Date? = nil
    @State private var timer: Timer? = nil
    @State private var elapsed: TimeInterval = 0
    @State private var showConfirmation = false
    @State private var pendingStop = false
    
    var body: some View {
        ZStack {
            ARPreviewView(isRecording: $isRecording)
                .id(isRecording)
                .edgesIgnoringSafeArea(.all)
            VStack {
                HStack {
                    Spacer()
                    if isRecording {
                        BlinkingDot()
                        Text(timerString)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.leading, 4)
                    }
                }
                .padding([.top, .trailing], 18)
                Spacer()
                HStack {
                    Spacer()
                    RecordButton(isRecording: isRecording) {
                        if isRecording {
                            timer?.invalidate()
                            timer = nil
                            isRecording = false
                            pendingStop = true
                            showConfirmation = true
                            MCP.log("Recording stopped from UI")
                        } else {
                            isRecording = true
                            startTime = Date()
                            elapsed = 0
                            timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
                                if let start = startTime {
                                    elapsed = Date().timeIntervalSince(start)
                                }
                            }
                            MCP.log("Recording started from UI")
                        }
                    }
                    Spacer()
                }
                .padding(.bottom, 40)
            }
        }
        .confirmationDialog("Keep this capture?", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Save", role: .none) {
                isRecording = false
                pendingStop = false
                MCP.log("User chose to save recording")
            }
            Button("Delete", role: .destructive) {
                isRecording = false
                pendingStop = false
                MCP.log("User chose to delete recording")
            }
            Button("Cancel", role: .cancel) {
                if pendingStop {
                    isRecording = true
                    startTime = Date().addingTimeInterval(-elapsed)
                    timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
                        if let start = startTime {
                            elapsed = Date().timeIntervalSince(start)
                        }
                    }
                }
                pendingStop = false
                MCP.log("User cancelled recording confirmation dialog")
            }
        } message: {
            Text("Do you want to keep or delete this recording?")
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { MCP.log("RecordingView appeared") }
    }
    
    var timerString: String {
        String(format: "%02d:%05.2f", Int(elapsed) / 60, elapsed.truncatingRemainder(dividingBy: 60))
    }
}

struct BlinkingDot: View {
    @State private var visible = true
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 16, height: 16)
            .opacity(visible ? 1 : 0.2)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: visible)
            .onAppear { visible.toggle() }
    }
}
