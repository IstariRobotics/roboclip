import SwiftUI

/// Home screen rebuilt with modern SwiftUI patterns and clearer component boundaries.
struct HomeView: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var uploader: SupabaseUploader
    @AppStorage("isRecording") private var isRecording: Bool = false
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                // Modern bold header
                HStack {
                    Text("roboclip")
                        .font(.largeTitle.bold())
                        .foregroundColor(.primary)
                    Spacer()
                    SettingsLink()
                }
                .padding([.top, .horizontal])
                .padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 24) {
                        // Card-style record button
                        FeatureButton(title: "Record",
                                      systemImage: "record.circle.fill",
                                      tint: .red) {
                            navPath.append(Destination.record)
                        }
                        .padding(.horizontal)

                        // Uploads section
                        if !uploader.sessionStatuses.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Uploads")
                                    .font(.title3.bold())
                                ForEach(uploader.sessionStatuses) { session in
                                    UploadRow(session: session)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarHidden(true)
            .onAppear {
                MCP.log("HomeView appeared")
                uploader.setIsRecording(isRecording)
                uploader.refreshPendingUploads()
                uploader.startUploadProcess()
            }
            .onChange(of: isRecording) { _, value in
                uploader.setIsRecording(value)
            }
            .navigationDestination(for: Destination.self) { dest in
                switch dest {
                case .record:
                    RecordingView(isRecording: $isRecording)
                }
            }
        }
    }

    private enum Destination: Hashable { case record }
}

// Add this helper at file scope (outside HomeView struct):
private func getScanFolderDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    return formatter
}

// MARK: - Reusable components -----------------------------------------------------------

/// Big button used in the grid.
struct FeatureButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.18))
                        .frame(width: 70, height: 70)
                        .shadow(color: tint.opacity(0.18), radius: 8, y: 4)
                    Image(systemName: systemImage)
                        .font(.system(size: 38, weight: .bold))
                        .foregroundColor(tint)
                }
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(isPressed ? 0.08 : 0.13), radius: isPressed ? 2 : 8, y: isPressed ? 1 : 4)
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in isPressed = true }
            .onEnded { _ in isPressed = false })
    }
}

/// Row showing progress for an uploading session.
struct UploadRow: View {
    var session: SessionStatus

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.folderName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                ProgressView(value: session.progress)
            }
            Spacer()
            Text("\(Int(session.progress * 100))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        )
        .padding(.vertical, 2)
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
                HStack { Text("Device"); Spacer(); Text(UIDevice.current.modelName).foregroundColor(.secondary) }
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
    let authManager = AuthManager()
    let uploader = SupabaseUploader(authManager: authManager)
    return HomeView()
        .environmentObject(uploader)
        .environmentObject(authManager)
}
