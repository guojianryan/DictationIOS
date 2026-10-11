import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case dark
    case light
    case cool

    static let storageKey = "appAppearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Warm"
        case .dark: "Dark"
        case .cool: "Cool"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light, .cool: .light
        case .dark: .dark
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light, .cool: .light
        case .dark: .dark
        }
    }

    /// Sets the style on every window. Unlike `preferredColorScheme`, this reliably reaches
    /// sheets and switches back from dark to light.
    @MainActor
    func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = interfaceStyle
                // Presented sheets can keep the style they were created with.
                window.rootViewController?.presentedViewController?.overrideUserInterfaceStyle = interfaceStyle
                window.rootViewController?.setNeedsStatusBarAppearanceUpdate()
            }
        }
    }
}

@main
struct DictationIOSApp: App {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .light

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { appearance.apply() }
                .onChange(of: appearance) { _, newValue in newValue.apply() }
        }
    }
}
