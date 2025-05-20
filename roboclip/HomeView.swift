import SwiftUI

struct HomeView: View {
    @StateObject private var uploader = SupabaseUploader()
    @AppStorage("isRecording") private var isRecording: Bool = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                NavigationLink(destination: RecordingView(isRecording: $isRecording)) {
                    Label("Record", systemImage: "record.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                }
                NavigationLink(destination: RecordingsListView()) {
                    Label("View Recordings", systemImage: "folder.fill")
                        .font(.title2)
                }
                Spacer()
                if uploader.isUploading {
                    VStack(spacing: 2) {
                        ProgressView(value: uploader.progress)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(maxWidth: .infinity)
                        Text(uploader.statusText)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 12)
                }
            }
            .padding()
            .navigationTitle("roboclip")
        }
        .onAppear {
            MCP.log("HomeView appeared")
            uploader.setIsRecording(isRecording)
        }
        .onChange(of: isRecording) { newValue in
            uploader.setIsRecording(newValue)
        }
    }
}
