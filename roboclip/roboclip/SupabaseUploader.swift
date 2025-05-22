import Foundation
import Supabase
import Combine
import Atomics
import SwiftUI

// Atomic integer wrapper for Swift concurrency compatibility
final class ManagedAtomicInt {
    private let atomic = ManagedAtomic<Int>(0)
    func increment() -> Int {
        return atomic.wrappingIncrementThenLoad(ordering: .relaxed)
    }
}

// Allow passing the atomic counter across concurrency domains
extension ManagedAtomicInt: @unchecked Sendable {}

/// Tracks progress for an individual session upload
struct SessionStatus: Identifiable, Equatable {
    let id: UUID
    let folderURL: URL
    var progress: Double

    var folderName: String { folderURL.lastPathComponent }
}

class SupabaseUploader: ObservableObject {
    @Published var isUploading = false
    @Published var progress: Double = 0.0
    @Published var statusText: String = ""
    @Published var currentFile: String = ""
    @Published var estimatedTime: String = ""
    /// Progress for each session being uploaded
    @Published var sessionStatuses: [SessionStatus] = []
    private let supabaseUrl: URL
    private let supabaseKey: String
    private let bucketName = "roboclip-recordings"
    private var client: SupabaseClient
    private var uploadTask: Task<Void, Never>? = nil
    private var isRecording: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private var uploadStartTime: Date? = nil

    /// Upload settings stored in UserDefaults
    @AppStorage("parallelUploads") private var parallelUploads: Bool = true
    @AppStorage("maxParallelUploads") private var storedMaxParallelUploads: Int = 4

    /// Current limit on concurrent uploads based on settings
    private var maxConcurrentUploads: Int { parallelUploads ? storedMaxParallelUploads : 1 }
    
    @Published var isSignedIn: Bool = false
    private var accessToken: String? = nil

    init(authManager: AuthManager) {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? "https://rfprjaeyqomuvzempixf.supabase.co"
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJmcHJqYWV5cW9tdXZ6ZW1waXhmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDc0NzM4NDAsImV4cCI6MjA2MzA0OTg0MH0.ODNn6Sh8MQvTwEkcUPT3tmVhehgTgEU51cWthou8XsM"
        self.supabaseUrl = URL(string: urlString)!
        self.supabaseKey = key
        self.client = SupabaseClient(supabaseURL: supabaseUrl, supabaseKey: supabaseKey)
        
        // Observe AuthManager for sign-in state and access token
        authManager.$isSignedIn
            .receive(on: DispatchQueue.main)
            .sink { [weak self] signedIn in
                self?.isSignedIn = signedIn
            }
            .store(in: &cancellables)
        // Remove updateAccessToken (not available in AuthClient)
        authManager.$supabaseSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                self?.accessToken = session?.accessToken
                // No direct way to update token in SupabaseClient; for anon-only, nothing to do
            }
            .store(in: &cancellables)
    }

    func setIsRecording(_ recording: Bool) {
        isRecording = recording
        if !recording {
            Task { [weak self] in
                // Give the recording manager a moment to finish writing files
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.refreshPendingUploads()
                self?.startUploadProcess()
            }
        }
    }

    func finishUploadUI() async {
        await MainActor.run {
            self.isUploading = false
            self.progress = 1.0
            self.statusText = "All uploads complete"
            self.currentFile = ""
            self.estimatedTime = ""
            self.sessionStatuses.removeAll()
        }
        // Optionally, add a short delay to let the user see the completed bar
        try? await Task.sleep(nanoseconds: 700_000_000) // 0.7s
        await MainActor.run {
            self.progress = 0.0
            self.statusText = ""
        }
    }

    func startUploadProcess() {
        guard !isUploading, !isRecording else { return }
        Task { @MainActor in
            self.isUploading = true
            self.progress = 0.0
            self.statusText = ""
            self.currentFile = ""
            self.estimatedTime = ""
            self.uploadStartTime = Date()
        }
        uploadTask = Task {
            await uploadAllRecordings()
            await finishUploadUI()
        }
    }

    /// Scan for pending folders and update `sessionStatuses` without starting an upload.
    func refreshPendingUploads() {
        let folders = scanPendingFolders()
        Task { @MainActor in
            var updated: [SessionStatus] = []
            for folder in folders {
                if let existing = self.sessionStatuses.first(where: { $0.folderURL == folder }) {
                    updated.append(existing)
                } else {
                    updated.append(SessionStatus(id: UUID(), folderURL: folder, progress: 0.0))
                }
            }
            self.sessionStatuses = updated
        }
    }

    /// Find all non-empty `Scan-*` folders in the temp directory and remove any empty ones.
    private func scanPendingFolders() -> [URL] {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let scanFolders = (try? fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))?.filter { $0.lastPathComponent.hasPrefix("Scan-") && $0.hasDirectoryPath } ?? []
        var pending: [URL] = []
        for folder in scanFolders {
            if allFiles(in: folder).isEmpty {
                try? fileManager.removeItem(at: folder)
            } else {
                pending.append(folder)
            }
        }
        return pending.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func uploadAllRecordings() async {
        var pendingFolders = scanPendingFolders()
        await MainActor.run {
            self.sessionStatuses = pendingFolders.map { SessionStatus(id: UUID(), folderURL: $0, progress: 0.0) }
        }
        var foldersToUpload = pendingFolders
        var uploadedFolders: Set<URL> = []
        while !foldersToUpload.isEmpty {
            let folder = foldersToUpload.removeFirst()
            await MainActor.run {
                self.statusText = "Uploading: \(folder.lastPathComponent)"
            }
            let sessionID = await MainActor.run {
                self.sessionStatuses.first(where: { $0.folderURL == folder })?.id ?? UUID()
            }
            await uploadRecordingFolder(folder, sessionID: sessionID)
            uploadedFolders.insert(folder)
            // After upload, check for new folders
            let currentPendingFolders = scanPendingFolders()
            let newFolders = currentPendingFolders.filter { !pendingFolders.contains($0) && !uploadedFolders.contains($0) && !foldersToUpload.contains($0) }
            if !newFolders.isEmpty {
                foldersToUpload.append(contentsOf: newFolders)
                await MainActor.run {
                    for newFolder in newFolders {
                        self.sessionStatuses.append(SessionStatus(id: UUID(), folderURL: newFolder, progress: 0.0))
                    }
                }
                pendingFolders.append(contentsOf: newFolders)
            }
            await MainActor.run {
                let completedCount = pendingFolders.firstIndex(of: folder).map { $0 + 1 } ?? 1
                self.progress = Double(completedCount) / Double(max(pendingFolders.count, 1))
            }
        }
    }

    private func uploadRecordingFolder(_ folder: URL, sessionID: UUID) async {
        let bucket = client.storage.from(bucketName)
        let files = allFiles(in: folder)
        let total = files.count
        await MainActor.run {
            self.currentFile = ""
        }
        // Limit concurrency using TaskGroup and chunking
        let chunkSize = maxConcurrentUploads
        let fileChunks = stride(from: 0, to: files.count, by: chunkSize).map { Array(files[$0..<min($0+chunkSize, files.count)]) }
        let completed = ManagedAtomicInt()
        for chunk in fileChunks {
            await withTaskGroup(of: Void.self) { group in
                for file in chunk {
                    group.addTask { [self] in
                        let relPath = file.path.replacingOccurrences(of: folder.deletingLastPathComponent().path + "/", with: "")
                        await MainActor.run {
                            self.currentFile = relPath
                        }
                        if await !self.remoteFileExists(bucket: bucket, path: relPath) {
                            if let data = try? Data(contentsOf: file) {
                                MCP.log("Uploading file: \(relPath)")
                                let success = await self.uploadWithRetry(bucket: bucket, path: relPath, data: data)
                                if success {
                                    MCP.log("Upload succeeded for file: \(relPath)")
                                    try? FileManager.default.removeItem(at: file)
                                } else {
                                    MCP.log("Upload failed for file: \(relPath)")
                                }
                            } else {
                                MCP.log("Failed to read file: \(file.path)")
                            }
                        } else {
                            MCP.log("File already exists remotely (skipped): \(relPath)")
                            try? FileManager.default.removeItem(at: file)
                        }
                        let newCompleted = completed.increment()
                        await MainActor.run {
                            let elapsed = Date().timeIntervalSince(self.uploadStartTime ?? Date())
                            let sessionProgress = Double(newCompleted) / Double(max(total, 1))
                            if let idx = self.sessionStatuses.firstIndex(where: { $0.id == sessionID }) {
                                var statuses = self.sessionStatuses
                                statuses[idx].progress = sessionProgress
                                self.sessionStatuses = statuses
                            }
                            self.progress = sessionProgress
                            if newCompleted > 1 {
                                let avgTime = elapsed / Double(newCompleted)
                                let remaining = Double(total - newCompleted) * avgTime
                                let formatter = DateComponentsFormatter()
                                formatter.allowedUnits = [.minute, .second]
                                formatter.unitsStyle = .abbreviated
                                self.estimatedTime = formatter.string(from: remaining) ?? ""
                            } else {
                                self.estimatedTime = ""
                            }
                        }
                    }
                }
                await group.waitForAll()
            }
        }
        await MainActor.run {
            if let idx = self.sessionStatuses.firstIndex(where: { $0.id == sessionID }) {
                var statuses = self.sessionStatuses
                statuses[idx].progress = 1.0
                self.sessionStatuses = statuses
            }
        }
        // Remove the session from the UI after a brief delay
        try? await Task.sleep(nanoseconds: 700_000_000)
        await MainActor.run {
            self.sessionStatuses.removeAll { $0.id == sessionID }
        }
        // Delete the session folder now that all files are uploaded
        try? FileManager.default.removeItem(at: folder)
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
            MCP.log("remoteFileExists: \(path) -> true")
            return true
        } catch {
            MCP.log("remoteFileExists: \(path) -> false (\(error))")
            return false
        }
    }

    /// Upload a file with retry logic to handle transient network errors.
    private func uploadWithRetry(bucket: StorageFileApi, path: String, data: Data, maxRetries: Int = 3) async -> Bool {
        for attempt in 1...maxRetries {
            do {
                _ = try await bucket.upload(path, data: data)
                MCP.log("Upload succeeded: \(path) on attempt \(attempt)")
                return true
            } catch {
                if let storageError = error as? StorageError, storageError.message.contains("already exists") {
                    MCP.log("File already exists remotely: \(path)")
                    return true
                }
                MCP.log("Upload attempt \(attempt) failed for \(path): \(error)")
                if attempt < maxRetries {
                    let delay = UInt64(attempt) * 1_000_000_000 // seconds in ns
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        MCP.log("All upload attempts failed for \(path)")
        return false
    }

    // Actor for concurrency-safe removedCount
    actor RemovedCount {
        private var value: Int = 0
        func increment() { value += 1 }
        func get() -> Int { value }
    }

    func clearUploadCache() {
        Task {
            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory
            let scanFolders = (try? fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))?.filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("Scan-") } ?? []
            let removedCount = RemovedCount()
            await withTaskGroup(of: Void.self) { group in
                for folder in scanFolders {
                    group.addTask {
                        do {
                            try fileManager.removeItem(at: folder)
                            await removedCount.increment()
                        } catch {
                            MCP.log("Failed to remove folder: \(folder.path) error: \(error)")
                        }
                    }
                }
                await group.waitForAll()
            }
            let count = await removedCount.get()
            await MainActor.run {
                MCP.log("Cleared all Scan-* folders from temp dir: \(tempDir.path), removed \(count) folders.")
                self.statusText = count > 0 ? "Upload cache cleared (\(count) folders removed)" : "No upload cache to clear."
                self.sessionStatuses.removeAll()
                self.progress = 0.0
                self.currentFile = ""
                self.estimatedTime = ""
            }
        }
    }
}
