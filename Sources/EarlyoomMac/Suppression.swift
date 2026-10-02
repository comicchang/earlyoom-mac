import Foundation

/// Centralized suppression logic.  Planning and signal delivery both call this
/// policy; a later layer must never be able to bypass it accidentally.
public struct SuppressionPolicy: Sendable {
    public static let defaultProtectedNames: Set<String> = [
        "launchd", "kernel_task", "windowserver", "loginwindow", "mdnsresponder",
        "securityd", "syspolicyd", "coreaudiod", "sshd", "sshd-session",
        "terminal", "iterm2", "alacritty", "kitty", "wezterm", "ghostty", "tmux", "screen",
        // Additional session/system infrastructure whose termination can make
        // the desktop or the current login unusable.
        "notifyd", "opendirectoryd", "configd", "runningboardd", "distnoted"
    ]

    private let protectedNames: Set<String>
    private let protectedBundleIdentifiers: Set<String>
    private let currentUID: UInt32
    private let currentSessionID: Int32?
    private let daemonPID: Int32
    private let protectCurrentUser: Bool
    private let protectCurrentSession: Bool
    private let protectAncestors: Bool
    private let protectProcessGroups: Bool
    private let extraProtectedUserIDs: Set<UInt32>

    public init(config: EarlyoomConfig, currentUID: UInt32, currentSessionID: Int32?, daemonPID: Int32) {
        self.protectedNames = SuppressionPolicy.defaultProtectedNames.union(config.protectedNames.map { $0.lowercased() })
        self.protectedBundleIdentifiers = config.protectedBundleIdentifiers
        self.currentUID = currentUID
        self.currentSessionID = currentSessionID
        self.daemonPID = daemonPID
        self.protectCurrentUser = config.protectCurrentUser
        self.protectCurrentSession = config.protectCurrentSession
        self.protectAncestors = config.protectAncestors
        self.protectProcessGroups = config.protectProcessGroups
        self.extraProtectedUserIDs = config.extraProtectedUserIDs
    }

    public func reason(for process: ProcessSnapshot, allProcesses: [ProcessSnapshot]) -> String? {
        if process.pid <= 1 { return "system bootstrap process" }
        if process.pid == daemonPID { return "earlyoom-mac itself" }
        if protectedNames.contains(process.name.lowercased()) { return "protected process name \(process.name)" }
        if let identity = process.application, protectedBundleIdentifiers.contains(identity.bundleIdentifier) {
            return "protected application bundle \(identity.bundleIdentifier)"
        }
        if extraProtectedUserIDs.contains(process.userID) { return "protected user id \(process.userID)" }
        if currentUID == 0, process.userID != 0 { return "user session identity unavailable to root daemon" }
        if protectCurrentUser && process.userID == currentUID { return "current user" }
        if protectCurrentSession, let currentSessionID, process.sessionID == currentSessionID {
            return "current login session"
        }
        if protectAncestors && isAncestorOrDescendantOfDaemon(process, allProcesses: allProcesses) {
            return "earlyoom-mac ancestor or descendant"
        }
        if protectProcessGroups && process.processGroupID > 0 {
            let protectedMemberExists = allProcesses.contains { member in
                member.processGroupID == process.processGroupID && member.pid != process.pid && isIntrinsicallyProtected(member)
            }
            if protectedMemberExists { return "process group contains a protected session process" }
        }
        return nil
    }

    public func isIntrinsicallyProtected(_ process: ProcessSnapshot) -> Bool {
        if process.pid <= 1 || process.pid == daemonPID { return true }
        if protectedNames.contains(process.name.lowercased()) { return true }
        if let identity = process.application, protectedBundleIdentifiers.contains(identity.bundleIdentifier) { return true }
        if extraProtectedUserIDs.contains(process.userID) { return true }
        if currentUID == 0, process.userID != 0 { return true }
        if protectCurrentUser && process.userID == currentUID { return true }
        if protectCurrentSession, let currentSessionID, process.sessionID == currentSessionID { return true }
        return false
    }


    private func isAncestorOrDescendantOfDaemon(_ process: ProcessSnapshot, allProcesses: [ProcessSnapshot]) -> Bool {
        if process.pid == daemonPID { return true }
        let parentByPID = Dictionary(uniqueKeysWithValues: allProcesses.map { ($0.pid, $0.parentPID) })
        var cursor = process.pid
        var visited = Set<Int32>()
        while cursor > 0, visited.insert(cursor).inserted {
            guard let parent = parentByPID[cursor] else { break }
            if parent == daemonPID { return true }
            cursor = parent
        }
        // Also protect children of the daemon.  A process may not be able to
        // reach the daemon through its current parent after re-parenting.
        var child = process.parentPID
        var childVisited = Set<Int32>()
        while child > 0, childVisited.insert(child).inserted {
            if child == daemonPID { return true }
            guard let parent = parentByPID[child] else { break }
            child = parent
        }
        return false
    }
}
