import SwiftUI

struct RecordButton: View {
    var isRecording: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isRecording ? Color.gray : Color.red)
                .frame(width: 64, height: 64)
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: 4)
                        .scaleEffect(isRecording ? 1.1 : 1.0)
                        .opacity(isRecording ? 0.7 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: isRecording)
                )
                .shadow(radius: 4)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
