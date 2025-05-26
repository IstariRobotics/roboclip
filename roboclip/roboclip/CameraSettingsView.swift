//
//  CameraSettingsView.swift
//  roboclip
//
//  Settings view for camera recording options
//

import SwiftUI

struct CameraSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                Section("File Information") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recording will create:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• video.mov (Main camera - 1920x1080)")
                            Text("• depth/ (LiDAR depth frames)")
                            Text("• imu.bin (Motion sensor data)")
                            Text("• audio.m4a (Microphone audio)")
                            Text("• meta.json (Recording metadata)")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Camera Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    CameraSettingsView()
}
