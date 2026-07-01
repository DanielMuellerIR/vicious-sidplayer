import SwiftUI

public enum PlayerTheme: String, CaseIterable, Identifiable {
    case light = "macOS Hell (Apple Classic)"
    case dark = "macOS Dunkel (Sleek Obsidian)"

    public var id: String { self.rawValue }
}

public extension Color {
    // macOS Light Mode Colors
    static let macLightSidebar = Color(red: 245/255, green: 245/255, blue: 247/255)
    static let macLightSurface = Color.white
    static let macLightBorder = Color(red: 211/255, green: 211/255, blue: 211/255)
    static let macLightText = Color(red: 29/255, green: 29/255, blue: 31/255)
    static let macLightSecondary = Color(red: 104/255, green: 104/255, blue: 109/255)
    static let macLightAccent = Color(red: 0/255, green: 122/255, blue: 255/255) // Apple Blue

    // macOS Dark Mode Colors
    static let macDarkBg = Color(red: 30/255, green: 30/255, blue: 30/255)
    static let macDarkSidebar = Color(red: 45/255, green: 45/255, blue: 47/255)
    static let macDarkSurface = Color(red: 20/255, green: 20/255, blue: 22/255)
    static let macDarkBorder = Color(red: 60/255, green: 60/255, blue: 62/255)
    static let macDarkText = Color.white
    static let macDarkSecondary = Color(red: 165/255, green: 165/255, blue: 165/255)
    static let macDarkAccent = Color(red: 10/255, green: 132/255, blue: 255/255) // Apple Dark Blue
}

// Sleek modern App Icon visualizer overlay (drawing a clean stylized floppy disk and waveform)
public struct ViciousAppIconOverlay: View {
    public init() {}
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [Color.macDarkSidebar, Color.macDarkBg],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.macLightAccent.opacity(0.3), lineWidth: 1.5)
                )
            
            VStack(spacing: 8) {
                // Waveform path representation
                HStack(spacing: 2) {
                    ForEach(0..<8) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.macLightAccent)
                            .frame(width: 4, height: CGFloat([12, 28, 16, 32, 24, 18, 22, 10][i]))
                    }
                }
                
                Text("SID")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.macLightAccent.opacity(0.8))
                    .cornerRadius(4)
            }
        }
        .frame(width: 60, height: 60)
        .shadow(radius: 4)
    }
}
