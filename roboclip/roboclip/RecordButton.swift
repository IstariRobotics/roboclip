import SwiftUI

struct RecordButton: View {
    var isRecording: Bool
    var action: () -> Void
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer ring
                Circle()
                    .stroke(Color.white, lineWidth: 5)
                    .frame(width: 80, height: 80)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                
                // Inner circle
                Circle()
                    .fill(isRecording ? Color.red : Color(red: 0.10, green: 0.18, blue: 0.34)) // Red when recording, Istari navy when not
                    .frame(width: isRecording ? 35 : 65, height: isRecording ? 35 : 65)
                    .scaleEffect(isPressed ? 0.95 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isRecording)
                    .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isPressed)
                
                // Recording indicator (square shape when recording)
                if isRecording {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                        .frame(width: 18, height: 18)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in isPressed = true }
            .onEnded { _ in isPressed = false })
    }
}
