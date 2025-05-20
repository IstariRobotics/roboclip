import SwiftUI
import Foundation

struct Recording: Identifiable {
    let id: String // folder name
    let date: Date
    let folderURL: URL
    let meta: Meta
    struct Meta: Decodable {
        let date: String?
        let device: String?
        let systemVersion: String?
        let appVersion: String?
        let build: String?
        let cameraIntrinsics: [[Float]]?
    }
}

struct RecordingsListView: View {
    @State private var recordings: [Recording] = []
    @State private var loading = true
    
    var body: some View {
        List {
            if recordings.isEmpty && !loading {
                Text("(No recordings yet)")
            } else {
                ForEach(recordings) { rec in
                    VStack(alignment: .leading) {
                        Text(rec.id)
                            .font(.headline)
                        if let dateStr = rec.meta.date {
                            Text(dateStr)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let device = rec.meta.device {
                            Text(device)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Recordings")
        .onAppear(perform: loadRecordings)
    }
    
    private func loadRecordings() {
        loading = true
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        MCP.log("RecordingsListView temp dir: \(tempDir.path)")
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory
            let scanFolders = (try? fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))?.filter { $0.lastPathComponent.hasPrefix("Scan-") && $0.hasDirectoryPath } ?? []
            var found: [Recording] = []
            for folder in scanFolders {
                let metaURL = folder.appendingPathComponent("meta.json")
                guard let data = try? Data(contentsOf: metaURL),
                      let meta = try? JSONDecoder().decode(Recording.Meta.self, from: data) else { continue }
                // Use folder name as id, parse date from meta if possible
                let date = ISO8601DateFormatter().date(from: meta.date ?? "") ?? Date()
                found.append(Recording(id: folder.lastPathComponent, date: date, folderURL: folder, meta: meta))
            }
            found.sort { $0.date > $1.date }
            DispatchQueue.main.async {
                self.recordings = found
                self.loading = false
                MCP.log("Loaded \(found.count) recordings from temp dir")
            }
        }
    }
}
