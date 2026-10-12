import Foundation

public struct EarlyoomConfig: Equatable, Sendable {
    public var enabled: Bool
    public var reportOnly: Bool
    public var intervalSeconds: Double
    public var warnAvailableFraction: Double
    public var terminateAvailableFraction: Double
    public var killAvailableFraction: Double
    public var gracePeriodSeconds: Double
    /// Steady-state heartbeat period in seconds. Configuration parsing requires `> 0`;
    /// programmatic values `<= 0` disable periodic heartbeats in `determineReportCadence`.
    public var heartbeatSeconds: Double
    public var minimumCandidatePhysicalBytes: UInt64
    /// Exact case-insensitive process-name multipliers for badness ranking.
    /// Missing names use 1.0.
    public var criticalityWeights: [String: Double]
    public var guiEscalation: GUIEscalation
    public var allowProcessGroupTermination: Bool
    public var protectedNames: Set<String>
    public var protectedBundleIdentifiers: Set<String>
    public var protectCurrentUser: Bool
    public var protectCurrentSession: Bool
    public var protectAncestors: Bool
    public var protectProcessGroups: Bool
    public var extraProtectedUserIDs: Set<UInt32>

    public init(
        enabled: Bool,
        reportOnly: Bool,
        intervalSeconds: Double,
        warnAvailableFraction: Double,
        terminateAvailableFraction: Double,
        killAvailableFraction: Double,
        gracePeriodSeconds: Double,
        heartbeatSeconds: Double = 300,
        minimumCandidatePhysicalBytes: UInt64,
        criticalityWeights: [String: Double] = [:],
        guiEscalation: GUIEscalation,
        allowProcessGroupTermination: Bool,
        protectedNames: Set<String>,
        protectedBundleIdentifiers: Set<String>,
        protectCurrentUser: Bool,
        protectCurrentSession: Bool,
        protectAncestors: Bool,
        protectProcessGroups: Bool,
        extraProtectedUserIDs: Set<UInt32>
    ) {
        self.enabled = enabled
        self.reportOnly = reportOnly
        self.intervalSeconds = intervalSeconds
        self.warnAvailableFraction = warnAvailableFraction
        self.terminateAvailableFraction = terminateAvailableFraction
        self.killAvailableFraction = killAvailableFraction
        self.gracePeriodSeconds = gracePeriodSeconds
        self.heartbeatSeconds = heartbeatSeconds
        self.minimumCandidatePhysicalBytes = minimumCandidatePhysicalBytes
        self.criticalityWeights = criticalityWeights
        self.guiEscalation = guiEscalation
        self.allowProcessGroupTermination = allowProcessGroupTermination
        self.protectedNames = protectedNames
        self.protectedBundleIdentifiers = protectedBundleIdentifiers
        self.protectCurrentUser = protectCurrentUser
        self.protectCurrentSession = protectCurrentSession
        self.protectAncestors = protectAncestors
        self.protectProcessGroups = protectProcessGroups
        self.extraProtectedUserIDs = extraProtectedUserIDs
    }

    /// Safe defaults are intentionally report-only.  The values live in the
    /// shipped configuration text below as well, so operators can audit them.
    public static let safeReportOnly = EarlyoomConfig(
        enabled: false,
        reportOnly: true,
        intervalSeconds: 5,
        warnAvailableFraction: 0.20,
        terminateAvailableFraction: 0.10,
        killAvailableFraction: 0.05,
        gracePeriodSeconds: 10,
        heartbeatSeconds: 300,
        minimumCandidatePhysicalBytes: 64 * 1024 * 1024,
        guiEscalation: .never,
        allowProcessGroupTermination: false,
        protectedNames: SuppressionPolicy.defaultProtectedNames,
        protectedBundleIdentifiers: [],
        protectCurrentUser: true,
        protectCurrentSession: true,
        protectAncestors: true,
        protectProcessGroups: true,
        extraProtectedUserIDs: []
    )

    public static let defaultConfigurationText = """
    # earlyoom-mac is intentionally report-only until both switches are changed.
    [earlyoom]
    enabled = false
    report_only = true
    interval = 5s
    grace_period = 10s
    heartbeat = 300s

    [check]
    metric = phys_footprint
    warn_available = 20%
    terminate_available = 10%
    kill_available = 5%
    minimum_candidate = 64MiB
    criticality =

    [action]
    gui_escalation = never
    allow_process_group = false

    [suppression]
    protect_current_user = true
    protect_current_session = true
    protect_ancestors = true
    protect_process_groups = true
    names = launchd,kernel_task,WindowServer,loginwindow,mDNSResponder,securityd,syspolicyd,coreaudiod,sshd,sshd-session,Terminal,iTerm2,Alacritty,kitty,WezTerm,Ghostty,tmux,screen,notifyd,opendirectoryd,configd,runningboardd,distnoted
    bundle_ids =
    extra_uids =
    """

    public static func load(from url: URL) throws -> EarlyoomConfig {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text: text)
    }

    public static func parse(text: String) throws -> EarlyoomConfig {
        var config = EarlyoomConfig.safeReportOnly
        var section = ""
        var seen = Set<String>()
        let supported: [String: Set<String>] = [
            "earlyoom": ["enabled", "report_only", "interval", "grace_period", "heartbeat"],
            "check": ["metric", "warn_available", "terminate_available", "kill_available", "minimum_candidate", "criticality"],
            "action": ["gui_escalation", "allow_process_group"],
            "suppression": ["protect_current_user", "protect_current_session", "protect_ancestors", "protect_process_groups", "names", "bundle_ids", "extra_uids"]
        ]

        for (lineNumber, original) in text.components(separatedBy: .newlines).enumerated() {
            let withoutComment = original.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            if withoutComment.isEmpty { continue }
            if withoutComment.hasPrefix("[") && withoutComment.hasSuffix("]") {
                section = String(withoutComment.dropFirst().dropLast()).lowercased()
                guard supported[section] != nil else {
                    throw EarlyoomError.invalidConfiguration("line \(lineNumber + 1): unknown section [\(section)]")
                }
                continue
            }
            let fields = withoutComment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else {
                throw EarlyoomError.invalidConfiguration("line \(lineNumber + 1): expected key = value")
            }
            let key = fields[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = fields[1].trimmingCharacters(in: .whitespaces)
            guard let keys = supported[section], keys.contains(key) else {
                throw EarlyoomError.invalidConfiguration("line \(lineNumber + 1): unknown key \(section).\(key)")
            }
            seen.insert("\(section).\(key)")
            switch "\(section).\(key)" {
            case "earlyoom.enabled": config.enabled = try parseBool(value, lineNumber)
            case "earlyoom.report_only": config.reportOnly = try parseBool(value, lineNumber)
            case "earlyoom.interval": config.intervalSeconds = try parseDuration(value, lineNumber)
            case "earlyoom.grace_period": config.gracePeriodSeconds = try parseDuration(value, lineNumber)
            case "earlyoom.heartbeat": config.heartbeatSeconds = try parseDuration(value, lineNumber)
            case "check.metric":
                guard value.lowercased() == "phys_footprint" else {
                    throw EarlyoomError.invalidConfiguration("line \(lineNumber + 1): metric must be phys_footprint")
                }
            case "check.warn_available": config.warnAvailableFraction = try parseFraction(value, lineNumber)
            case "check.terminate_available": config.terminateAvailableFraction = try parseFraction(value, lineNumber)
            case "check.kill_available": config.killAvailableFraction = try parseFraction(value, lineNumber)
            case "check.minimum_candidate": config.minimumCandidatePhysicalBytes = try parseBytes(value, lineNumber)
            case "check.criticality": config.criticalityWeights = try parseWeights(value, lineNumber)
            case "action.gui_escalation":
                let normalized = value.lowercased().replacingOccurrences(of: "_", with: "")
                switch normalized {
                case "never": config.guiEscalation = .never
                case "gracefulthenforce": config.guiEscalation = .gracefulThenForce
                case "forceapplication": config.guiEscalation = .forceApplication
                case "processgroup": config.guiEscalation = .processGroup
                default:
                    throw EarlyoomError.invalidConfiguration("line \(lineNumber + 1): gui_escalation must be never, graceful_then_force, force_application, or process_group")
                }
            case "action.allow_process_group": config.allowProcessGroupTermination = try parseBool(value, lineNumber)
            case "suppression.protect_current_user": config.protectCurrentUser = try parseBool(value, lineNumber)
            case "suppression.protect_current_session": config.protectCurrentSession = try parseBool(value, lineNumber)
            case "suppression.protect_ancestors": config.protectAncestors = try parseBool(value, lineNumber)
            case "suppression.protect_process_groups": config.protectProcessGroups = try parseBool(value, lineNumber)
            case "suppression.names": config.protectedNames = Set(parseList(value).map { $0.lowercased() })
            case "suppression.bundle_ids": config.protectedBundleIdentifiers = Set(parseList(value))
            case "suppression.extra_uids":
                config.extraProtectedUserIDs = try Set(parseList(value).map { try parseUInt32($0, lineNumber) })
            default:
                throw EarlyoomError.invalidConfiguration("line \(lineNumber + 1): unsupported key")
            }
        }

        guard config.intervalSeconds > 0, config.intervalSeconds.isFinite else { throw EarlyoomError.invalidConfiguration("interval must be greater than zero") }
        guard config.gracePeriodSeconds >= 0, config.gracePeriodSeconds.isFinite else { throw EarlyoomError.invalidConfiguration("grace_period cannot be negative") }
        guard config.heartbeatSeconds > 0, config.heartbeatSeconds.isFinite else { throw EarlyoomError.invalidConfiguration("heartbeat must be greater than zero") }
        guard config.warnAvailableFraction > config.terminateAvailableFraction,
              config.terminateAvailableFraction > config.killAvailableFraction,
              config.killAvailableFraction >= 0,
              config.warnAvailableFraction <= 1 else {
            throw EarlyoomError.invalidConfiguration("availability thresholds must satisfy warn > terminate > kill and be between 0 and 100 percent")
        }
        guard config.minimumCandidatePhysicalBytes > 0 else { throw EarlyoomError.invalidConfiguration("minimum_candidate must be greater than zero") }
        guard config.guiEscalation != .processGroup || config.allowProcessGroupTermination else {
            throw EarlyoomError.invalidConfiguration("gui_escalation = process_group requires allow_process_group = true")
        }
        // `seen` deliberately exists to make it easy to add required keys later;
        // omitted keys retain the audited safe defaults.
        _ = seen
        return config
    }

    private static func parseBool(_ value: String, _ line: Int) throws -> Bool {
        switch value.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: throw EarlyoomError.invalidConfiguration("line \(line + 1): expected boolean")
        }
    }

    private static func parseDuration(_ value: String, _ line: Int) throws -> Double {
        let lower = value.lowercased()
        let multiplier: Double
        let number: Substring
        if lower.hasSuffix("ms") { multiplier = 0.001; number = lower.dropLast(2) }
        else if lower.hasSuffix("s") { multiplier = 1; number = lower.dropLast() }
        else if lower.hasSuffix("m") { multiplier = 60; number = lower.dropLast() }
        else { multiplier = 1; number = lower[lower.startIndex...] }
        guard let parsed = Double(number), parsed.isFinite, parsed >= 0 else {
            throw EarlyoomError.invalidConfiguration("line \(line + 1): invalid duration")
        }
        let duration = parsed * multiplier
        guard duration.isFinite else {
            throw EarlyoomError.invalidConfiguration("line \(line + 1): invalid duration")
        }
        return duration
    }

    private static func parseFraction(_ value: String, _ line: Int) throws -> Double {
        let lower = value.lowercased()
        if lower.hasSuffix("%") {
            guard let percentage = Double(lower.dropLast()), percentage.isFinite else {
                throw EarlyoomError.invalidConfiguration("line \(line + 1): invalid percentage")
            }
            return percentage / 100
        }
        guard let fraction = Double(lower), fraction.isFinite else {
            throw EarlyoomError.invalidConfiguration("line \(line + 1): invalid percentage")
        }
        return fraction
    }

    private static func parseBytes(_ value: String, _ line: Int) throws -> UInt64 {
        let lower = value.lowercased().trimmingCharacters(in: .whitespaces)
        let suffixes: [(String, UInt64)] = [("gib", 1024 * 1024 * 1024), ("gb", 1000 * 1000 * 1000), ("mib", 1024 * 1024), ("mb", 1000 * 1000), ("kib", 1024), ("kb", 1000), ("b", 1)]
        for (suffix, multiplier) in suffixes where lower.hasSuffix(suffix) {
            let number = lower.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let parsed = Double(number), parsed > 0, parsed.isFinite else { break }
            let product = parsed * Double(multiplier)
            guard product.isFinite, product < Double(UInt64.max) else { break }
            return UInt64(product)
        }
        throw EarlyoomError.invalidConfiguration("line \(line + 1): invalid byte size")
    }

    private static func parseUInt32(_ value: String, _ line: Int) throws -> UInt32 {
        guard let number = UInt32(value.trimmingCharacters(in: .whitespaces)) else {
            throw EarlyoomError.invalidConfiguration("line \(line + 1): invalid user id")
        }
        return number
    }

    private static func parseWeights(_ value: String, _ line: Int) throws -> [String: Double] {
        var weights: [String: Double] = [:]
        for item in parseList(value) {
            let fields = item.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let weight = Double(fields[1].trimmingCharacters(in: .whitespaces)),
                  weight > 0,
                  weight.isFinite else {
                throw EarlyoomError.invalidConfiguration("line \(line + 1): criticality entries must be name:positive-number")
            }
            let name = fields[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty else { throw EarlyoomError.invalidConfiguration("line \(line + 1): criticality name cannot be empty") }
            weights[name] = weight
        }
        return weights
    }

    private static func parseList(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
