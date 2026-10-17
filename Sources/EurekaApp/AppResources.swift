import Foundation

/// Resource entry point that supports both the standard .app bundle layout and the `swift run` dev
/// layout.
enum AppResources {
    static let bundle: Bundle = {
        if let resourcesURL = Bundle.main.resourceURL,
           let packaged = Bundle(
               url: resourcesURL.appendingPathComponent("eureka_eureka.bundle", isDirectory: true)
           ) {
            return packaged
        }

        // Under plain SwiftPM runs, use the auto-generated build-directory lookup.
        return Bundle.module
    }()
}
