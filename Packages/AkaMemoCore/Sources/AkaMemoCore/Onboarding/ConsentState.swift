import Foundation

/// Persists the FR-001 first-run consent. Each platform stores it in its own
/// defaults domain; recording is refused until it is completed.
public enum ConsentState {
    public static let key = "onboarding.consent.v1"

    public static func isCompleted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    public static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    public static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// Debug-only switch that skips the first-run guide without persisting
    /// consent, so permission-denial states can be exercised headlessly.
    public static var skipOnboardingRequested: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains(
                "-AkaMemoSkipOnboarding"
            )
        #else
            false
        #endif
    }
}

/// Debug-only helper that lets headless simulator runs open a specific
/// onboarding page. Always inactive in release builds.
public enum OnboardingPreview {
    public static var isRequested: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains(
                "-AkaMemoOnboardingPreview"
            )
        #else
            false
        #endif
    }

    public static var step: Int? {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-AkaMemoOnboardingStep"),
                arguments.indices.contains(index + 1)
            else {
                return nil
            }
            return Int(arguments[index + 1])
        #else
            return nil
        #endif
    }
}
