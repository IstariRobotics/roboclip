import Foundation
import Supabase

class SupabaseUploader: ObservableObject {
    @Published var isUploading = false
    @Published var progress: Double = 0.0
    @Published var statusText: String = ""
    private let supabaseUrl: URL
    private let supabaseKey: String
    private let bucketName = "roboclip-recordings"
    private let client: SupabaseClient
    private var uploadTask: Task<Void, Never>? = nil
    private var isRecording: Bool = false

    init() {
        // Load secrets from xcconfig via environment or Info.plist (for demo, hardcoded)
        let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? "https://rfprjaeyqomuvzempixf.supabase.co"
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJmcHJqYWV5cW9tdXZ6ZW1waXhmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDc0NzM4NDAsImV4cCI6MjA2MzA0OTg0MH0.ODNn6Sh8MQvTwEkcUPT3tmVhehgTgEU51cWthou8XsM"
        self.supabaseUrl = URL(string: urlString)!
        self.supabaseKey = key
        self.client = SupabaseClient(supabaseURL: supabaseUrl, supabaseKey: supabaseKey)
    }

    func setIsRecording(_ recording: Bool) {
        isRecording = recording
        if !isRecording {
            startUploadProcess()
        }
    }

    func startUploadProcess() {
        guard !isUploading, !isRecording else { return }
        isUploading = true
        progress = 0.0
        statusText = ""
        uploadTask = Task {
            await uploadAllRecordings()
            await MainActor.run { self.isUploading = false; self.progress = 0.0; self.statusText = "" }
        }
    }

    private func uploadAllRecordings() async {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let scanFolders = (try? fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))?.filter { $0.lastPathComponent.hasPrefix("Scan-") && $0.hasDirectoryPath } ?? []
        let total = scanFolders.count
        for (idx, folder) in scanFolders.enumerated() {
            await MainActor.run {
                self.statusText = "Uploading session \(idx+1)/\(total): \(folder.lastPathComponent)"
            }
            await uploadRecordingFolder(folder)
            await MainActor.run { self.progress = Double(idx+1) / Double(max(total,1)) }
        }
    }

    private func uploadRecordingFolder(_ folder: URL) async {
        let bucket = client.storage.from(bucketName)
        let files = allFiles(in: folder)
        for file in files {
            let relPath = file.path.replacingOccurrences(of: folder.deletingLastPathComponent().path + "/", with: "")
            if await !remoteFileExists(bucket: bucket, path: relPath) {
                if let data = try? Data(contentsOf: file) {
                    do {
                        MCP.log("Uploading file: \(relPath)")
                        _ = try await bucket.upload(path: relPath, file: data)
                        MCP.log("Upload succeeded: \(relPath)")
                    } catch {
                        MCP.log("Upload failed: \(relPath) error: \(error)")
                    }
                } else {
                    MCP.log("Failed to read file: \(file.path)")
                }
            } else {
                MCP.log("File already exists remotely: \(relPath)")
            }
        }
    }

    private func allFiles(in folder: URL) -> [URL] {
        var result: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if !fileURL.hasDirectoryPath { result.append(fileURL) }
            }
        }
        return result
    }

    private func remoteFileExists(bucket: StorageFileApi, path: String) async -> Bool {
        do {
            _ = try await bucket.download(path: path)
            return true
        } catch {
            return false
        }
    }
}
