import Foundation

/// A point-in-time observation of one process.
public struct ProcessSnapshot: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let processGroupID: Int32
    public let sessionID: Int32
    public let userID: UInt32
    public let name: String
    public let executablePath: String?
    public let physicalBytes: UInt64
    public let residentBytes: UInt64
    public let application: ApplicationIdentity?
    /// Darwin start time in seconds, used to re-verify a PID before signalling.
    /// Synthetic test fixtures may leave this at zero.
    public let startTimeSeconds: UInt64

    public init(
        pid: Int32,
        parentPID: Int32,
        processGroupID: Int32,
        sessionID: Int32,
        userID: UInt32,
        name: String,
        executablePath: String? = nil,
        physicalBytes: UInt64,
        residentBytes: UInt64,
        application: ApplicationIdentity? = nil,
        startTimeSeconds: UInt64 = 0
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.processGroupID = processGroupID
        self.sessionID = sessionID
        self.userID = userID
        self.name = name
        self.executablePath = executablePath
        self.physicalBytes = physicalBytes
        self.residentBytes = residentBytes
        self.application = application
        self.startTimeSeconds = startTimeSeconds
    }

    public var isGUIApplicationProcess: Bool { application != nil }
}

/// The identity used to aggregate GUI helpers safely.  Bundle identity is
/// stronger than a process name, which is commonly shared by unrelated tools.
public struct ApplicationIdentity: Equatable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let applicationPath: String
    public let displayName: String?

    public init(bundleIdentifier: String, applicationPath: String, displayName: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
        self.displayName = displayName
    }
}

public struct MemorySnapshot: Equatable, Sendable {
    public let physicalBytes: UInt64
    public let availableBytes: UInt64
    public let freeBytes: UInt64
    public let inactiveBytes: UInt64
    public let purgeableBytes: UInt64
    public let compressorBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64

    public init(
        physicalBytes: UInt64,
        availableBytes: UInt64,
        freeBytes: UInt64 = 0,
        inactiveBytes: UInt64 = 0,
        purgeableBytes: UInt64 = 0,
        compressorBytes: UInt64 = 0,
        swapUsedBytes: UInt64 = 0,
        swapTotalBytes: UInt64 = 0
    ) {
        self.physicalBytes = physicalBytes
        self.availableBytes = availableBytes
        self.freeBytes = freeBytes
        self.inactiveBytes = inactiveBytes
        self.purgeableBytes = purgeableBytes
        self.compressorBytes = compressorBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
    }
}

public enum ActionSafety: String, Codable, Sendable {
    case reportOnly
    case protectedTarget
    case singleProcess
    case gracefulApplication
    case forceApplication
    case processGroup
}

public enum GUIEscalation: String, Codable, Sendable {
    case never
    case gracefulThenForce
    case forceApplication
    case processGroup
}

public struct CandidateGroup: Equatable, Sendable {
    public let key: String
    public let representative: ProcessSnapshot
    public let members: [ProcessSnapshot]
    public let physicalBytes: UInt64
    public let residentBytes: UInt64
    public let application: ApplicationIdentity?
    public let badness: Double
    public let safety: ActionSafety

    public init(
        key: String,
        representative: ProcessSnapshot,
        members: [ProcessSnapshot],
        physicalBytes: UInt64,
        residentBytes: UInt64,
        application: ApplicationIdentity?,
        badness: Double,
        safety: ActionSafety
    ) {
        self.key = key
        self.representative = representative
        self.members = members
        self.physicalBytes = physicalBytes
        self.residentBytes = residentBytes
        self.application = application
        self.badness = badness
        self.safety = safety
    }
}

public struct ActionPlan: Equatable, Sendable {
    public let group: CandidateGroup
    public let safety: ActionSafety
    public let reason: String

    public init(group: CandidateGroup, safety: ActionSafety, reason: String) {
        self.group = group
        self.safety = safety
        self.reason = reason
    }
}

public enum EarlyoomError: Error, CustomStringConvertible, Sendable {
    case invalidConfiguration(String)
    case cannotReadProcessList
    case cannotReadMemory(String)
    case cannotReadProcess(Int32, String)
    case unsupportedPlatform(String)
    case lockAlreadyHeld(String)
    case cannotAcquireLock(String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message): return "invalid configuration: \(message)"
        case .cannotReadProcessList: return "cannot enumerate processes"
        case .cannotReadMemory(let message): return "cannot read memory statistics: \(message)"
        case .cannotReadProcess(let pid, let message): return "cannot read process \(pid): \(message)"
        case .unsupportedPlatform(let message): return "unsupported platform: \(message)"
        case .lockAlreadyHeld(let message): return "enforce lock already held: \(message)"
        case .cannotAcquireLock(let message): return "cannot acquire enforce lock: \(message)"
        }
    }
}
