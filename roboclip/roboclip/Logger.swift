//
//  Logger.swift
//  roboclip
//
//  Simple logging utility for debug output
//

import Foundation

// MARK: - MCP Logging
final class MCP {
    static func log(_ message: String) {
        print("[DEBUG] " + message)
    }
}

// MARK: - AppLogger for backward compatibility
// AppLogger is now defined in AppLogger.swift with more comprehensive logging features
