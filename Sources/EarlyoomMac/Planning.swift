import Foundation
import Darwin
#if canImport(AppKit)
import AppKit
#endif

public enum PressureLevel: String, Sendable, Equatable {
    case normal
    case warn
    case terminate
    case kill

    fileprivate init(availableFraction: Double, config: EarlyoomConfig) {
        if availableFraction <= config.killAvailableFraction { self = .kill }
        else if availableFraction <= config.terminateAvailableFraction { self = .terminate }
        else if availableFraction <= config.warnAvailableFraction { self = .warn }
        else { self = .normal }
    }
}

public struct PlanningResult: Equatable, Sendable {
    public let pressure: PressureLevel
    public let availableFraction: Double
    public let groups: [CandidateGroup]
    public let plans: [ActionPlan]

    public init(pressure: PressureLevel, availableFraction: Double, groups: [CandidateGroup], plans: [ActionPlan]) {
        self.pressure = pressure
        self.availableFraction = availableFraction
        self.groups = groups
        self.plans = plans
    }
}

public struct CandidatePlanner: Sendable {
    private let config: EarlyoomConfig
    private let policy: SuppressionPolicy

    public init(config: EarlyoomConfig, policy: SuppressionPolicy) {
        self.config = config
        self.policy = policy
    }

    public func plan(memory: MemorySnapshot, processes: [ProcessSnapshot]) -> PlanningResult {
        let availableFraction = memory.physicalBytes == 0 ? 0 : Double(memory.availableBytes) / Double(memory.physicalBytes)
        let pressure = PressureLevel(availableFraction: availableFraction, config: config)
        let grouped = Dictionary(grouping: processes.filter { $0.physicalBytes >= config.minimumCandidatePhysicalBytes }) { process in
            groupKey(for: process)
        }
        let groups = grouped.compactMap { key, members -> CandidateGroup? in
            let representative = members.max { lhs, rhs in lhs.physicalBytes < rhs.physicalBytes } ?? members[0]
            let bytes = members.reduce(UInt64(0)) { partial, member in partial.addingReportingOverflow(member.physicalBytes).overflow ? UInt64.max : partial + member.physicalBytes }
            let resident = members.reduce(UInt64(0)) { partial, member in partial.addingReportingOverflow(member.residentBytes).overflow ? UInt64.max : partial + member.residentBytes }
            let suppressionReason = members.compactMap { policy.reason(for: $0, allProcesses: processes) }.first
            let safety: ActionSafety = suppressionReason == nil ? actionSafety(for: representative, members: members, pressure: pressure) : .protectedTarget
            // Darwin has no Linux oom_score; an explicit operator weight is
            // the optional criticality term. Missing names use neutral 1.0.
            let criticality = config.criticalityWeights[representative.name.lowercased()] ?? 1.0
            let badness = memory.physicalBytes == 0 ? 0 : min(1, Double(bytes) / Double(memory.physicalBytes) * criticality)
            return CandidateGroup(
                key: key,
                representative: representative,
                members: members.sorted { $0.physicalBytes > $1.physicalBytes },
                physicalBytes: bytes,
                residentBytes: resident,
                application: representative.application,
                badness: badness,
                safety: safety
            )
        }.sorted {
            if $0.badness != $1.badness { return $0.badness > $1.badness }
            return $0.representative.pid < $1.representative.pid
        }
        var hasSelectedActionableGroup = false
        let plans = groups.map { group in
            if let reason = group.members.compactMap({ policy.reason(for: $0, allProcesses: processes) }).first {
                return ActionPlan(group: group, safety: .protectedTarget, reason: reason)
            }
            switch pressure {
            case .normal, .warn:
                return ActionPlan(group: group, safety: .reportOnly, reason: "pressure is below termination threshold")
            case .terminate, .kill:
                guard group.safety != .reportOnly, group.safety != .protectedTarget else {
                    return ActionPlan(group: group, safety: group.safety, reason: actionReason(group: group, pressure: pressure))
                }
                guard !hasSelectedActionableGroup else {
                    return ActionPlan(
                        group: group,
                        safety: .reportOnly,
                        reason: "\(pressure.rawValue) pressure; deferred to higher-badness candidate for this sample"
                    )
                }
                hasSelectedActionableGroup = true
                return ActionPlan(group: group, safety: group.safety, reason: actionReason(group: group, pressure: pressure))
            }
        }
        return PlanningResult(pressure: pressure, availableFraction: availableFraction, groups: groups, plans: plans)
    }

    private func groupKey(for process: ProcessSnapshot) -> String {
        if let application = process.application {
            return "application:\(application.bundleIdentifier):\(application.applicationPath)"
        }
        // Grouping by process group preserves the unit that shells and worker
        // launchers use, while the policy refuses groups containing protected
        // session processes.
        if process.processGroupID > 0 { return "process-group:\(process.processGroupID)" }
        return "process:\(process.pid)"
    }

    private func actionSafety(for representative: ProcessSnapshot, members: [ProcessSnapshot], pressure: PressureLevel) -> ActionSafety {
        guard config.enabled, !config.reportOnly else { return .reportOnly }
        guard pressure == .terminate || pressure == .kill else { return .reportOnly }
        if representative.application != nil {
            switch config.guiEscalation {
            case .never: return .reportOnly
            case .gracefulThenForce: return .gracefulApplication
            case .forceApplication: return .forceApplication
            case .processGroup:
                // Configuration parsing rejects this combination. Keep the
                // runtime guard fail-closed for programmatically built values.
                return config.allowProcessGroupTermination ? .processGroup : .reportOnly
            }
        }
        if members.count > 1 {
            // A process-group candidate represents one workload unit. Killing
            // only its largest member would falsely claim that the workload
            // was handled while leaving its helpers alive.
            return config.allowProcessGroupTermination ? .processGroup : .reportOnly
        }
        return .singleProcess
    }

    private func actionReason(group: CandidateGroup, pressure: PressureLevel) -> String {
        let metric = ByteFormatter.format(group.physicalBytes)
        switch group.safety {
        case .reportOnly:
            if group.application == nil && group.members.count > 1 && !config.allowProcessGroupTermination && config.enabled && !config.reportOnly && (pressure == .terminate || pressure == .kill) {
                return "\(pressure.rawValue) pressure; \(metric) phys_footprint, multi-process group has \(group.members.count) members; allow_process_group=false, singleProcess would leave the workload running"
            }
            return "\(pressure.rawValue) pressure; \(metric) phys_footprint, configured report-only or no applicable action"
        case .protectedTarget: return "suppressed by safety policy"
        case .singleProcess: return "\(pressure.rawValue) pressure; non-GUI process with \(metric) phys_footprint"
        case .gracefulApplication: return "\(pressure.rawValue) pressure; request graceful quit for bundle \(group.application?.bundleIdentifier ?? "unknown")"
        case .forceApplication: return "\(pressure.rawValue) pressure; force terminate bundle after graceful opportunity"
        case .processGroup: return "\(pressure.rawValue) pressure; terminate process group only after all safety checks"
        }
    }
}

public enum ActionExecutionState: String, Equatable, Sendable {
    case attempted
    case executed
    case rejected
}

public struct ActionExecutionOutcome: Equatable, Sendable {
    public let state: ActionExecutionState
    public let reason: String

    public init(state: ActionExecutionState, reason: String) {
        self.state = state
        self.reason = reason
    }
}

public protocol ProcessActionExecutor {
    func execute(_ plan: ActionPlan, gracePeriodSeconds: Double) throws
    func executeWithOutcome(_ plan: ActionPlan, gracePeriodSeconds: Double) throws -> ActionExecutionOutcome
}

public extension ProcessActionExecutor {
    func executeWithOutcome(_ plan: ActionPlan, gracePeriodSeconds: Double) throws -> ActionExecutionOutcome {
        try execute(plan, gracePeriodSeconds: gracePeriodSeconds)
        return ActionExecutionOutcome(state: .executed, reason: "executor completed")
    }
}

public struct DryRunActionExecutor: ProcessActionExecutor, Sendable {
    public init() {}
    public func execute(_ plan: ActionPlan, gracePeriodSeconds: Double) throws {
        // Explicitly no signal is sent in dry-run mode.
        _ = plan
        _ = gracePeriodSeconds
    }
    public func executeWithOutcome(_ plan: ActionPlan, gracePeriodSeconds: Double) throws -> ActionExecutionOutcome {
        _ = plan
        _ = gracePeriodSeconds
        return ActionExecutionOutcome(state: .rejected, reason: "dry-run executor refuses actions")
    }
}

#if canImport(AppKit)
public struct DarwinActionExecutor: ProcessActionExecutor, Sendable {
    public let memorySampler: any MemorySampling
    public let killAvailableFraction: Double
    public let gracePollSeconds: Double
    private let sleeper: @Sendable (Double) -> Void
    private let pidVerifier: @Sendable (Int32, UInt64) -> Bool
    private let signalSender: @Sendable (Int32, Int32) -> Int32

    public init(
        memorySampler: any MemorySampling = DarwinMemorySampler(),
        killAvailableFraction: Double = 0.05,
        gracePollSeconds: Double = 1.0,
        sleeper: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
        pidVerifier: (@Sendable (Int32, UInt64) -> Bool)? = nil,
        signalSender: (@Sendable (Int32, Int32) -> Int32)? = nil
    ) {
        self.memorySampler = memorySampler
        self.killAvailableFraction = killAvailableFraction
        self.gracePollSeconds = gracePollSeconds
        self.sleeper = sleeper
        self.pidVerifier = pidVerifier ?? { pid, expectedStartTime in
            Self.checkProcessIdentity(pid: pid, expectedStartTime: expectedStartTime)
        }
        self.signalSender = signalSender ?? { pid, sig in
            kill(pid, sig)
        }
    }

    public init(
        config: EarlyoomConfig,
        memorySampler: any MemorySampling = DarwinMemorySampler(),
        gracePollSeconds: Double = 1.0,
        sleeper: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
        pidVerifier: (@Sendable (Int32, UInt64) -> Bool)? = nil,
        signalSender: (@Sendable (Int32, Int32) -> Int32)? = nil
    ) {
        self.init(
            memorySampler: memorySampler,
            killAvailableFraction: config.killAvailableFraction,
            gracePollSeconds: gracePollSeconds,
            sleeper: sleeper,
            pidVerifier: pidVerifier,
            signalSender: signalSender
        )
    }

    public func execute(_ plan: ActionPlan, gracePeriodSeconds: Double) throws {
        _ = try executeWithOutcome(plan, gracePeriodSeconds: gracePeriodSeconds)
    }

    public func executeWithOutcome(_ plan: ActionPlan, gracePeriodSeconds: Double) throws -> ActionExecutionOutcome {
        guard plan.safety != .protectedTarget, plan.safety != .reportOnly else {
            return ActionExecutionOutcome(state: .rejected, reason: "plan is protected or report-only")
        }
        switch plan.safety {
        case .singleProcess:
            let member = plan.group.representative
            guard isSameProcess(member) else {
                return ActionExecutionOutcome(state: .rejected, reason: "sampled process identity changed")
            }
            let termDelivered = try signal(pid: member.pid, signal: SIGTERM)
            let killDelivered = try waitAndKillIfAlive(members: [member], gracePeriodSeconds: gracePeriodSeconds)
            return executionOutcome(
                delivered: termDelivered || killDelivered > 0,
                reason: "single-process target exited before a signal was delivered"
            )
        case .gracefulApplication:
            guard let identity = plan.group.application else {
                return ActionExecutionOutcome(state: .rejected, reason: "GUI bundle identity is missing")
            }
            // If even one sampled member has disappeared/reused its PID, skip
            // the whole app rather than risking an action on a new instance.
            guard plan.group.members.allSatisfy(isSameProcess) else {
                return ActionExecutionOutcome(state: .rejected, reason: "sampled application identity changed")
            }
            let startTimes = Dictionary(uniqueKeysWithValues: plan.group.members.map { ($0.pid, $0.startTimeSeconds) })
            let pids = Set(startTimes.keys)
            let applications = matchingRunningApplications(for: identity, memberPIDs: pids)
            guard !applications.isEmpty else {
                return ActionExecutionOutcome(state: .rejected, reason: "sampled application is no longer running")
            }
            var delivered = false
            for application in applications { delivered = application.terminate() || delivered }
            _ = waitGracePeriod(pids: Array(pids), gracePeriodSeconds: gracePeriodSeconds)
            let aliveSampledMembers = plan.group.members.filter { isPIDAlive($0.pid) }
            let sampledIdentityIntact = !aliveSampledMembers.isEmpty && aliveSampledMembers.allSatisfy(isSameProcess)
            for application in applications where !application.isTerminated {
                if let startTime = startTimes[application.processIdentifier] {
                    guard isSameProcess(pid: application.processIdentifier, expectedStartTime: startTime) else { continue }
                } else {
                    guard sampledIdentityIntact else { continue }
                }
                delivered = application.forceTerminate() || delivered
            }
            return executionOutcome(delivered: delivered, reason: "application quit request was not accepted")
        case .forceApplication:
            guard let identity = plan.group.application, plan.group.members.allSatisfy(isSameProcess) else {
                return ActionExecutionOutcome(state: .rejected, reason: "sampled application identity changed or is missing")
            }
            let startTimes = Dictionary(uniqueKeysWithValues: plan.group.members.map { ($0.pid, $0.startTimeSeconds) })
            let pids = Set(startTimes.keys)
            let applications = matchingRunningApplications(for: identity, memberPIDs: pids)
            var delivered = false
            if applications.isEmpty {
                // A bundle-less/headless helper still gets only its sampled
                // members, never an unrelated same-name process.
                delivered = try signalAll(members: plan.group.members, signal: SIGTERM) > 0
            } else {
                for application in applications { delivered = application.forceTerminate() || delivered }
            }
            let killDelivered = try waitAndKillIfAlive(members: plan.group.members, gracePeriodSeconds: gracePeriodSeconds) > 0
            return executionOutcome(
                delivered: delivered || killDelivered,
                reason: "force-termination request was not accepted"
            )
        case .processGroup:
            let groupID = plan.group.representative.processGroupID
            guard groupID > 1, plan.group.members.allSatisfy(isSameProcess) else {
                return ActionExecutionOutcome(state: .rejected, reason: "sampled process-group identity changed")
            }
            guard signalSender(-groupID, 0) == 0 || errno == EPERM else {
                return ActionExecutionOutcome(state: .rejected, reason: "process group is no longer present")
            }
            var delivered = false
            if signalSender(-groupID, SIGTERM) == 0 {
                delivered = true
            } else if errno != ESRCH {
                throw EarlyoomError.cannotReadProcess(groupID, "SIGTERM failed: \(String(cString: strerror(errno)))")
            }
            _ = waitGracePeriod(pids: plan.group.members.map(\.pid), gracePeriodSeconds: gracePeriodSeconds)
            let aliveMembers = plan.group.members.filter { isPIDAlive($0.pid) }
            if !aliveMembers.isEmpty && (signalSender(-groupID, 0) == 0 || errno == EPERM) {
                if aliveMembers.allSatisfy(isSameProcess) {
                    if signalSender(-groupID, SIGKILL) == 0 {
                        delivered = true
                    } else if errno != ESRCH {
                        throw EarlyoomError.cannotReadProcess(groupID, "SIGKILL failed: \(String(cString: strerror(errno)))")
                    }
                } else {
                    let verifiedAliveMembers = aliveMembers.filter(isSameProcess)
                    guard !verifiedAliveMembers.isEmpty else {
                        return executionOutcome(delivered: delivered, reason: "sampled process-group identity changed before SIGKILL")
                    }
                    if try signalAll(members: verifiedAliveMembers, signal: SIGKILL) > 0 {
                        delivered = true
                    }
                }
            }
            return executionOutcome(delivered: delivered, reason: "process group disappeared before a signal was delivered")
        case .protectedTarget, .reportOnly:
            return ActionExecutionOutcome(state: .rejected, reason: "plan is protected or report-only")
        }
    }

    private func executionOutcome(delivered: Bool, reason: String) -> ActionExecutionOutcome {
        ActionExecutionOutcome(state: delivered ? .executed : .attempted, reason: delivered ? "signal or application action was delivered" : reason)
    }

    private func matchingRunningApplications(for identity: ApplicationIdentity, memberPIDs: Set<Int32>) -> [NSRunningApplication] {
        let expectedPath = URL(fileURLWithPath: identity.applicationPath).standardizedFileURL.path
        return NSRunningApplication.runningApplications(withBundleIdentifier: identity.bundleIdentifier).filter { app in
            if memberPIDs.contains(app.processIdentifier) {
                return true
            }
            guard let bundlePath = app.bundleURL?.standardizedFileURL.path else {
                return false
            }
            return bundlePath == expectedPath
        }
    }

    private func signalAll(members: [ProcessSnapshot], signal: Int32) throws -> Int {
        var delivered = 0
        for member in members where try self.signal(pid: member.pid, signal: signal) { delivered += 1 }
        return delivered
    }

    private func isPIDAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        let res = signalSender(pid, 0)
        return res == 0 || errno == EPERM
    }

    private func signal(pid: Int32, signal: Int32) throws -> Bool {
        guard pid > 1 else { return false }
        if signalSender(pid, signal) != 0 {
            if errno == ESRCH { return false }
            throw EarlyoomError.cannotReadProcess(pid, "signal failed: \(String(cString: strerror(errno)))")
        }
        return true
    }

    @discardableResult
    private func waitGracePeriod(
        pids: [Int32],
        gracePeriodSeconds: Double
    ) -> Bool {
        var remaining = max(0, gracePeriodSeconds)
        while remaining > 0 {
            if !pids.isEmpty && pids.allSatisfy({ !isPIDAlive($0) }) {
                return false
            }
            if let memory = try? memorySampler.sample() {
                let available = memory.physicalBytes == 0 ? 0 : Double(memory.availableBytes) / Double(memory.physicalBytes)
                if available <= killAvailableFraction {
                    return true
                }
            }
            let chunk = min(gracePollSeconds, remaining)
            sleeper(chunk)
            remaining -= chunk
        }
        return false
    }

    private func waitAndKillIfAlive(members: [ProcessSnapshot], gracePeriodSeconds: Double) throws -> Int {
        _ = waitGracePeriod(pids: members.map(\.pid), gracePeriodSeconds: gracePeriodSeconds)
        var delivered = 0
        for member in members where member.pid > 1 {
            guard isSameProcess(member) else { continue }
            if isPIDAlive(member.pid) {
                if try signal(pid: member.pid, signal: SIGKILL) { delivered += 1 }
            }
        }
        return delivered
    }

    private func isSameProcess(_ snapshot: ProcessSnapshot) -> Bool {
        isSameProcess(pid: snapshot.pid, expectedStartTime: snapshot.startTimeSeconds)
    }

    private func isSameProcess(pid: Int32, expectedStartTime: UInt64) -> Bool {
        guard pid > 1, expectedStartTime > 0 else { return false }
        return pidVerifier(pid, expectedStartTime)
    }

    public static func checkProcessIdentity(pid: Int32, expectedStartTime: UInt64) -> Bool {
        guard pid > 1, expectedStartTime > 0 else { return false }
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return false }
        return UInt64(bsd.pbi_start_tvsec) == expectedStartTime
    }
}
#endif

public enum ByteFormatter {
    public static func format(_ bytes: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 { value /= 1024; index += 1 }
        return String(format: "%.2f %@", value, units[index])
    }
}
