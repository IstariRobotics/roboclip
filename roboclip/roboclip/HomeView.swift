import SwiftUI

/// Home screen rebuilt with modern SwiftUI patterns and clearer component boundaries.
struct HomeView: View {
    @EnvironmentObject private var authManager: AuthManager
    @StateObject private var uploader = SupabaseUploader(authManager: AuthManager())
    @AppStorage("isRecording") private var isRecording: Bool = false
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollView {
                VStack(spacing: 24) {
                    // 1️⃣ Primary feature buttons --------------------------------------------------
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 16) {
                        FeatureButton(title: "Record",
                                      systemImage: "record.circle.fill",
                                      tint: .red) {
                            navPath.append(Destination.record)
                        }
                        FeatureButton(title: "Recordings",
                                      systemImage: "folder.fill",
                                      tint: .accentColor) {
                            navPath.append(Destination.list)
                        }
                    }
                    // 2️⃣ Upload status bar -------------------------------------------------------
                    if uploader.isUploading {
                        UploadStatusBar(progress: uploader.progress,
                                        text: uploader.statusText)
                    }
                }
                .padding()
            }
            .navigationTitle("roboclip")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SettingsLink()
                }
            }
            // 3️⃣ Lifecycle & recording state -----------------------------------------------
            .task {
                MCP.log("HomeView appeared")
                uploader.setIsRecording(isRecording)
                uploader.startUploadProcess()
            }
            .onChange(of: isRecording) { _, value in
                uploader.setIsRecording(value)
                if !value { uploader.startUploadProcess() }
            }
            // 4️⃣ Navigation destinations ----------------------------------------------------
            .navigationDestination(for: Destination.self) { dest in
                switch dest {
                case .record:
                    RecordingView(isRecording: $isRecording)
                case .list:
                    RecordingsListView()
                }
            }
        }
    }

    private enum Destination: Hashable { case record, list }
}

// MARK: - Reusable components -----------------------------------------------------------

/// Big button used in the grid.
struct FeatureButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 44))
                Text(title)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .foregroundColor(.white)
            .background(tint.gradient)
            .cornerRadius(14)
            .shadow(radius: 4, y: 2)
        }
    }
}

/// Compact progress bar with status text.
struct UploadStatusBar: View {
    var progress: Double
    var text: String

    var body: some View {
        VStack(spacing: 4) {
            ProgressView(value: progress)
            Text(text)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Settings gear that pushes a SettingsView (placeholder).
struct SettingsLink: View {
    var body: some View {
        NavigationLink {
            SettingsView()
        } label: {
            Image(systemName: "gearshape")
        }
    }
}

/// Settings screen with upload cache management, app info, upload behavior, and debug tools.
struct SettingsView: View {
    @EnvironmentObject var uploader: SupabaseUploader
    @AppStorage("autoUploadOnStartup") private var autoUploadOnStartup: Bool = true
    @AppStorage("parallelUploads") private var parallelUploads: Bool = true
    @AppStorage("maxParallelUploads") private var maxParallelUploads: Int = 4
    @AppStorage("verboseLogging") private var verboseLogging: Bool = false
    @State private var showClearAlert = false
    var body: some View {
        Form {
            Section(header: Text("Upload Cache")) {
                Button(role: .destructive) {
                    showClearAlert = true
                } label: {
                    Label("Clear Upload Cache", systemImage: "trash")
                }
                .alert("Clear all local Scan-* folders? This cannot be undone.", isPresented: $showClearAlert) {
                    Button("Delete", role: .destructive) { uploader.clearUploadCache() }
                    Button("Cancel", role: .cancel) {}
                }
            }
            Section(header: Text("App Info")) {
                HStack { Text("Version"); Spacer(); Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").foregroundColor(.secondary) }
                HStack { Text("Build"); Spacer(); Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "").foregroundColor(.secondary) }
                HStack { Text("Device"); Spacer(); Text(UIDevice.current.model).foregroundColor(.secondary) }
                HStack { Text("System"); Spacer(); Text(UIDevice.current.systemVersion).foregroundColor(.secondary) }
            }
            Section(header: Text("Upload Behavior")) {
                Toggle("Auto-upload on startup", isOn: $autoUploadOnStartup)
                Toggle("Parallel uploads", isOn: $parallelUploads)
                if parallelUploads {
                    Stepper(value: $maxParallelUploads, in: 1...16) {
                        Text("Max parallel uploads: \(maxParallelUploads)")
                    }
                }
            }
            Section(header: Text("Debug / Developer")) {
                Toggle("Verbose logging", isOn: $verboseLogging)
                Button("Export Logs") {
                    // TODO: Implement log export if you keep a log file
                }
            }
        }
        .navigationTitle("Settings")
    }
}

// MARK: - Preview ----------------------------------------------------------------------

#Preview {
    HomeView()
        .environmentObject(AuthManager())
}
