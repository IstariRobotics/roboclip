// AppLogger.swift
// roboclip
//
// Centralized logging utility for the roboclip application

import Foundation

enum LogLevel: String {
    case debug = "debug"
    case info = "info"
    case warning = "warning"
    case error = "error"
}

struct AppLogger {
    static func log(_ message: String, level: LogLevel = .info, file: String = #file, function: String = #function, line: Int = #line) {
        let timestamp = DateFormatter.logTimestamp.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(timestamp)] [\(level.rawValue.uppercased())] \(fileName):\(function):\(line) - \(message)"
        print(logMessage)
    }
}

extension DateFormatter {
    static let logTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
