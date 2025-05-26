// ColorPalette.swift
// roboclip
//
// Centralized color definitions for Istari Robotics branding with dark mode support

import SwiftUI
import UIKit

struct ColorPalette {
    // Modern accessible colors with dark mode support
    static let primaryBlue = Color("PrimaryBlue")
    static let primaryText = Color("PrimaryText") 
    static let secondaryText = Color("SecondaryText")
    static let background = Color("Background")
    static let cardBackground = Color("CardBackground")
    static let accent = Color("AccentColor")
    static let recordRed = Color("RecordRed")
    
    // Fallback colors for when asset catalog is not available
    static let fallbackPrimaryBlue = Color(red: 0.2, green: 0.4, blue: 0.8) // Brighter, more accessible blue
    static let fallbackPrimaryText = Color.primary
    static let fallbackSecondaryText = Color.secondary
    static let fallbackBackground = Color(UIColor.systemBackground)
    static let fallbackCardBackground = Color(UIColor.secondarySystemBackground)
    static let fallbackAccent = Color.accentColor
    static let fallbackRecordRed = Color(red: 0.9, green: 0.2, blue: 0.2)
    
    // Safe color access with fallbacks
    static func safePrimaryBlue() -> Color {
        return fallbackPrimaryBlue
    }
    
    static func safePrimaryText() -> Color {
        return fallbackPrimaryText
    }
    
    static func safeSecondaryText() -> Color {
        return fallbackSecondaryText
    }
    
    static func safeBackground() -> Color {
        return fallbackBackground
    }
    
    static func safeCardBackground() -> Color {
        return fallbackCardBackground
    }
    
    static func safeAccent() -> Color {
        return fallbackAccent
    }
    
    static func safeRecordRed() -> Color {
        return fallbackRecordRed
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0) // Default to black if hex is invalid
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
