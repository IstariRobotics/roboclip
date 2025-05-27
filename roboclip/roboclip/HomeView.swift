import SwiftUI
import UIKit

/// Home screen rebuilt with modern SwiftUI patterns and clearer component boundaries.
struct HomeView: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var uploader: SupabaseUploader
    @AppStorage("isRecording") private var isRecording: Bool = false
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                // Animated background gradient
                ColorPalette.spaceGradient
                    .ignoresSafeArea()
                    .animatedBackground()
                
                VStack(spacing: 0) {
                    // Modern header with glass morphism
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("roboclip")
                                .font(.largeTitle.bold())
                                .foregroundColor(.white)
                            
                            Text("AR Reality Capture")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        
                        Spacer()
                        
                        SettingsLink()
                            .foregroundColor(.white)
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .background {
                                Circle()
                                    .fill(ColorPalette.glassBackground)
                                    .overlay {
                                        Circle()
                                            .stroke(ColorPalette.glassBorder, lineWidth: 1)
                                    }
                            }
                    }
                    .padding()
                    .glassMorphism()
                    .padding(.horizontal)
                    .padding(.top, 8)

                    ScrollView {
                        VStack(spacing: 24) {
                            // Hero record button with modern styling
                            VStack(spacing: 16) {
                                Button {
                                    navPath.append(Destination.record)
                                } label: {
                                    VStack(spacing: 12) {
                                        Image(systemName: "video.circle.fill")
                                            .font(.system(size: 60))
                                            .foregroundStyle(ColorPalette.recordGradient)
                                            .neonGlow(color: ColorPalette.errorRed, radius: 15)
                                        
                                        Text("Start Recording")
                                            .font(.title2.bold())
                                            .foregroundColor(.white)
                                        
                                        Text("Capture AR depth and IMU data")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.7))
                                            .multilineTextAlignment(.center)
                                    }
                                    .padding(24)
                                    .frame(maxWidth: .infinity)
                                }
                                .modernCard()
                                .scaleEffect(1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: false)
                            }
                            .padding(.horizontal)
                            .padding(.top, 24)

                            // Uploads section with modern styling
                            if !uploader.sessionStatuses.isEmpty {
                                VStack(alignment: .leading, spacing: 16) {
                                    HStack {
                                        Image(systemName: "icloud.and.arrow.up")
                                            .font(.title3)
                                            .foregroundColor(ColorPalette.neonBlue)
                                            .neonGlow(color: ColorPalette.neonBlue, radius: 5)
                                        
                                        Text("Uploads")
                                            .font(.title3.bold())
                                            .foregroundColor(.white)
                                        
                                        Spacer()
                                        
                                        Text("\(uploader.sessionStatuses.count)")
                                            .font(.caption.bold())
                                            .foregroundColor(.white.opacity(0.7))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background {
                                                Capsule()
                                                    .fill(ColorPalette.glassBackground)
                                                    .overlay {
                                                        Capsule()
                                                            .stroke(ColorPalette.glassBorder, lineWidth: 1)
                                                    }
                                            }
                                    }
                                    
                                    LazyVStack(spacing: 12) {
                                        ForEach(uploader.sessionStatuses) { session in
                                            UploadRow(session: session)
                                        }
                                    }
                                }
                                .padding()
                                .glassMorphism()
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                print("HomeView appeared") // Temporarily using print until AppLogger is in scope
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

/// Big button used in the grid with modern branding and dark mode support.
struct FeatureButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
    @State private var isPressed = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                // Special handling for record button - just a big red circle
                if systemImage == "record.circle.fill" {
                    Circle()
                        .fill(colorScheme == .dark ? Color.red.opacity(0.9) : Color.red)
                        .frame(width: 80, height: 80)
                        .shadow(color: Color.red.opacity(0.3), radius: 8, y: 4)
                } else {
                    // Other icons use the complex styling
                    ZStack {
                        // Adaptive background for the icon circle
                        Circle()
                            .fill(adaptiveIconBackground)
                            .frame(width: 80, height: 80)
                            .overlay(
                                Circle()
                                    .stroke(adaptiveIconBorder, lineWidth: 2)
                            )
                            .shadow(color: adaptiveIconShadow, radius: 12, y: 6)
                        
                        // Other icons use the tint color
                        Image(systemName: systemImage)
                            .font(.system(size: 42, weight: .bold))
                            .foregroundColor(adaptiveIconColor)
                    }
                }
                
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
            .background(
                // Only show background styling for non-record buttons
                Group {
                    if systemImage == "record.circle.fill" {
                        Color.clear
                    } else {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color(UIColor.secondarySystemBackground))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
                            )
                            .shadow(color: Color.primary.opacity(isPressed ? 0.1 : 0.15), radius: isPressed ? 4 : 12, y: isPressed ? 2 : 6)
                    }
                }
            )
            .scaleEffect(isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in isPressed = true }
            .onEnded { _ in isPressed = false })
    }
    
    // Adaptive colors for better dark mode support
    private var adaptiveIconBackground: Color {
        return tint.opacity(0.15)
    }
    
    private var adaptiveIconBorder: Color {
        return Color.accentColor.opacity(0.3)
    }
    
    private var adaptiveIconShadow: Color {
        return tint.opacity(0.2)
    }
    
    private var adaptiveIconColor: Color {
        return tint
    }
}

/// Row showing progress for an uploading session with modern glass morphism styling.
struct UploadRow: View {
    var session: SessionStatus

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.folderName)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                // Custom progress bar with glass morphism
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background track
                        RoundedRectangle(cornerRadius: 4)
                            .fill(ColorPalette.glassBackground.opacity(0.3))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(ColorPalette.glassBorder.opacity(0.5), lineWidth: 0.5)
                            }
                            .frame(height: 6)
                        
                        // Progress fill with gradient
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: session.progress < 1.0 ? 
                                        [ColorPalette.neonBlue, ColorPalette.neonPurple] :
                                        [ColorPalette.successGreen, ColorPalette.neonGreen],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * session.progress, height: 6)
                            .animation(.easeInOut(duration: 0.3), value: session.progress)
                    }
                }
                .frame(height: 6)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(Int(session.progress * 100))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundColor(.white)
                
                if session.progress < 1.0 {
                    Text("uploading")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                } else {
                    Text("complete")
                        .font(.caption2)
                        .foregroundColor(ColorPalette.successGreen)
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ColorPalette.glassBackground)
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        }
    }
}

/// Settings gear that pushes a SettingsView with Istari branding.
struct SettingsLink: View {
    var body: some View {
        NavigationLink {
            SettingsView()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title2)
                .foregroundColor(.white)
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
