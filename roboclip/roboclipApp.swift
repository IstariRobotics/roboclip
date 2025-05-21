//
//  roboclipApp.swift
//  roboclip
//
//  Created by James Ball on 20/05/2025.
//

import SwiftUI
import SwiftData

@main
struct roboclipApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @StateObject private var authManager = AuthManager()
    @StateObject private var uploader: SupabaseUploader

    init() {
        let authManager = AuthManager()
        _authManager = StateObject(wrappedValue: authManager)
        _uploader = StateObject(wrappedValue: SupabaseUploader(authManager: authManager))
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(uploader)
                .environmentObject(authManager)
        }
        .modelContainer(sharedModelContainer)
    }
}
