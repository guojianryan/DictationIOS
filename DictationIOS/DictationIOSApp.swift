import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appAppearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Sets the style on every window. Unlike `preferredColorScheme`, this reliably reaches
    /// sheets and switches back from dark to light (or to the system setting).
    @MainActor
    func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = interfaceStyle
                // Presented sheets can keep the style they were created with.
                window.rootViewController?.setNeedsStatusBarAppearanceUpdate()
            }
        }
    }
}

@main
struct DictationIOSApp: App {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { appearance.apply() }
                .onChange(of: appearance) { _, newValue in newValue.apply() }
        }
    }
}
