import Foundation

public protocol ApplicationIdentityResolving: Sendable {
    func resolve(executablePath: String) -> ApplicationIdentity?
}

/// Resolves the containing .app bundle and reads its signed/packaged
/// CFBundleIdentifier.  Process names are deliberately not used as an app
/// identity: helpers from unrelated applications often share names.
public struct BundleIdentityResolver: ApplicationIdentityResolving, Sendable {
    public init() {}

    public func resolve(executablePath: String) -> ApplicationIdentity? {
        let standardized = URL(fileURLWithPath: executablePath).standardizedFileURL.path
        let components = standardized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let appIndex = components.lastIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let rootComponents = Array(components.prefix(appIndex + 1))
        let appPath = "/" + rootComponents.joined(separator: "/")
        guard let bundle = Bundle(path: appPath),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty else { return nil }
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        return ApplicationIdentity(bundleIdentifier: bundleIdentifier, applicationPath: appPath, displayName: displayName)
    }
}
