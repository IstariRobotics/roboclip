//
//  ThemeModifiers.swift
//  roboclip
//
//  Modern SwiftUI view modifiers for consistent theming

import SwiftUI

// MARK: - Glass Morphism Effect
struct GlassMorphismModifier: ViewModifier {
    let blur: CGFloat
    let opacity: Double
    
    init(blur: CGFloat = 20, opacity: Double = 0.1) {
        self.blur = blur
        self.opacity = opacity
    }
    
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ColorPalette.glassBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(ColorPalette.glassBorder, lineWidth: 1)
                    }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
    }
}

// MARK: - Neon Glow Effect
struct NeonGlowModifier: ViewModifier {
    let color: Color
    let radius: CGFloat
    
    init(color: Color = ColorPalette.neonBlue, radius: CGFloat = 10) {
        self.color = color
        self.radius = radius
    }
    
    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.6), radius: radius, x: 0, y: 0)
            .shadow(color: color.opacity(0.3), radius: radius * 2, x: 0, y: 0)
    }
}

// MARK: - Modern Card Style
struct ModernCardModifier: ViewModifier {
    let isPressed: Bool
    
    init(isPressed: Bool = false) {
        self.isPressed = isPressed
    }
    
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(ColorPalette.glassGradient)
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(ColorPalette.glassBorder, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
            }
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
    }
}

// MARK: - Floating Action Button
struct FloatingActionButtonModifier: ViewModifier {
    let gradient: LinearGradient
    let size: CGFloat
    
    init(gradient: LinearGradient = ColorPalette.neonGradient, size: CGFloat = 60) {
        self.gradient = gradient
        self.size = size
    }
    
    func body(content: Content) -> some View {
        content
            .font(.title2.bold())
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(gradient)
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            }
            .modifier(NeonGlowModifier(radius: 8))
    }
}

// MARK: - Animated Background
struct AnimatedBackgroundModifier: ViewModifier {
    @State private var animateGradient = false
    
    func body(content: Content) -> some View {
        content
            .background {
                LinearGradient(
                    colors: [
                        ColorPalette.spaceBlue,
                        ColorPalette.spaceBlueDark,
                        ColorPalette.neonBlue.opacity(0.3)
                    ],
                    startPoint: animateGradient ? .topLeading : .bottomTrailing,
                    endPoint: animateGradient ? .bottomTrailing : .topLeading
                )
                .ignoresSafeArea()
                .animation(
                    .easeInOut(duration: 3)
                    .repeatForever(autoreverses: true),
                    value: animateGradient
                )
                .onAppear {
                    animateGradient = true
                }
            }
    }
}

// MARK: - View Extensions
extension View {
    func glassMorphism(blur: CGFloat = 20, opacity: Double = 0.1) -> some View {
        self.modifier(GlassMorphismModifier(blur: blur, opacity: opacity))
    }
    
    func neonGlow(color: Color = ColorPalette.neonBlue, radius: CGFloat = 10) -> some View {
        self.modifier(NeonGlowModifier(color: color, radius: radius))
    }
    
    func modernCard(isPressed: Bool = false) -> some View {
        self.modifier(ModernCardModifier(isPressed: isPressed))
    }
    
    func floatingActionButton(gradient: LinearGradient = ColorPalette.neonGradient, size: CGFloat = 60) -> some View {
        self.modifier(FloatingActionButtonModifier(gradient: gradient, size: size))
    }
    
    func animatedBackground() -> some View {
        self.modifier(AnimatedBackgroundModifier())
    }
}
