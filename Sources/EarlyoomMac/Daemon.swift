import Foundation
import Darwin

public enum PressureBand: String, Sendable, Equatable {
    case ok
    case warn
    case action

    public init(pressure: PressureLevel) {
        switch pressure {
        case .normal: self = .ok
        case .warn: self = .warn
        case .terminate, .kill: self = .action
        }
    }
}

public enum ReportCadence: String, Sendable, Equatable {
    case full
    case heartbeat
    case silent
}
public struct EarlyoomDaemon {
    public let config: EarlyoomConfig
    private let processSampler: any ProcessSampling
    private let memorySampler: any MemorySampling
    private let actionExecutor: any ProcessActionExecutor
    private let policy: SuppressionPolicy
    private let output: @Sendable (String) -> Void
    private let errorOutput: @Sendable (String) -> Void
    private let sleeper: @Sendable (Double) -> Void
    private let clock: @Sendable () -> Date
    public let enforceLock: EnforceLock?

    public init(
        config: EarlyoomConfig,
        processSampler: any ProcessSampling = DarwinProcessSampler(),
        memorySampler: any MemorySampling = DarwinMemorySampler(),
        actionExecutor: any ProcessActionExecutor = DryRunActionExecutor(),
        currentUID: UInt32 = getuid(),
        currentSessionID: Int32? = getsid(getpid()),
        daemonPID: Int32 = getpid(),
        lockURL: URL? = nil,
        output: @escaping @Sendable (String) -> Void = { print($0) },
        errorOutput: @escaping @Sendable (String) -> Void = { fputs("\($0)\n", stderr) },
        sleeper: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.processSampler = processSampler
        self.memorySampler = memorySampler
        self.actionExecutor = actionExecutor
        self.policy = SuppressionPolicy(config: config, currentUID: currentUID, currentSessionID: currentSessionID, daemonPID: daemonPID)
        self.output = output
        self.errorOutput = errorOutput
        self.sleeper = sleeper
        self.clock = clock
        if config.enabled && !config.reportOnly {
            self.enforceLock = EnforceLock(url: lockURL ?? EnforceLock.defaultLockURL)
        } else {
            self.enforceLock = nil
        }
    }

    private struct IterationResult {
        let memory: MemorySnapshot
        let planningResult: PlanningResult
        let actionOutcomes: [(ActionPlan, ActionExecutionOutcome)]
        let actionError: Error?
    }

    private func executeIteration() throws -> IterationResult {
        let memory = try memorySampler.sample()
        let processes = try processSampler.sample()
        let planner = CandidatePlanner(config: config, policy: policy)
        let result = planner.plan(memory: memory, processes: processes)
        let actionablePlans = result.plans.filter { $0.safety != .protectedTarget && $0.safety != .reportOnly }
        var actionOutcomes: [(ActionPlan, ActionExecutionOutcome)] = []
        var actionError: Error?
        for plan in actionablePlans {
            do {
                actionOutcomes.append((plan, try actionExecutor.executeWithOutcome(plan, gracePeriodSeconds: config.gracePeriodSeconds)))
            } catch {
                actionOutcomes.append((plan, ActionExecutionOutcome(state: .rejected, reason: "executor error: \(error)")))
                actionError = error
                break
            }
        }
        if actionError != nil {
            for plan in actionablePlans.dropFirst(actionOutcomes.count) {
                actionOutcomes.append((plan, ActionExecutionOutcome(state: .rejected, reason: "not attempted after an executor error")))
            }
        }
        return IterationResult(
            memory: memory,
            planningResult: result,
            actionOutcomes: actionOutcomes,
            actionError: actionError
        )
    }

    @discardableResult
    public func runOnce() throws -> PlanningResult {
        try enforceLock?.acquire()
        defer { enforceLock?.release() }
        let iteration = try executeIteration()
        output(Self.formatReport(
            memory: iteration.memory,
            result: iteration.planningResult,
            enabled: config.enabled,
            reportOnly: config.reportOnly,
            actionOutcomes: iteration.actionOutcomes
        ))
        if let actionError = iteration.actionError { throw actionError }
        return iteration.planningResult
    }

    public func run(repeatCount: Int? = nil, stopOnSamplingError: Bool? = nil) throws {
        try enforceLock?.acquire()
        defer { enforceLock?.release() }

        var iterations = 0
        let isOnce = (repeatCount == 1)
        let shouldStopOnError = stopOnSamplingError ?? isOnce
        var lastOutputTime: Date? = nil
        var lastPressureBand: PressureBand? = nil
        var cumulativeActions = 0

        while repeatCount == nil || iterations < repeatCount! {
            let iteration: IterationResult
            do {
                iteration = try executeIteration()
            } catch {
                if shouldStopOnError {
                    throw error
                }
                errorOutput("[error] sampling failed: \(error)")
                iterations += 1
                if repeatCount == nil || iterations < repeatCount! {
                    sleeper(config.intervalSeconds)
                }
                continue
            }

            let acted = iteration.actionOutcomes.contains { $0.1.state == .executed }
            let deliveredCount = iteration.actionOutcomes.filter { $0.1.state == .executed }.count
            cumulativeActions += deliveredCount
            let hasActionOutcomes = !iteration.actionOutcomes.isEmpty

            let currentBand = PressureBand(pressure: iteration.planningResult.pressure)
            let isFirstRun = (lastOutputTime == nil)
            let now = clock()
            let elapsed = lastOutputTime.map { now.timeIntervalSince($0) } ?? 0

            let cadence = Self.determineReportCadence(
                isFirstRun: isFirstRun,
                previousBand: lastPressureBand,
                currentBand: currentBand,
                hasActionOutcomes: hasActionOutcomes,
                elapsedSinceLastOutput: elapsed,
                heartbeatSeconds: config.heartbeatSeconds,
                isOnce: isOnce
            )

            switch cadence {
            case .full:
                output(Self.formatReport(
                    memory: iteration.memory,
                    result: iteration.planningResult,
                    enabled: config.enabled,
                    reportOnly: config.reportOnly,
                    actionOutcomes: iteration.actionOutcomes
                ))
                lastOutputTime = now
            case .heartbeat:
                output(Self.formatHeartbeat(
                    memory: iteration.memory,
                    result: iteration.planningResult,
                    enabled: config.enabled,
                    reportOnly: config.reportOnly,
                    cumulativeActions: cumulativeActions
                ))
                lastOutputTime = now
            case .silent:
                break
            }

            lastPressureBand = currentBand
            iterations += 1

            if let actionError = iteration.actionError {
                throw actionError
            }

            if repeatCount == nil || iterations < repeatCount! {
                let sleepDuration = acted ? min(1.0, config.intervalSeconds) : config.intervalSeconds
                sleeper(sleepDuration)
            }
        }
    }

    public static func determineReportCadence(
        isFirstRun: Bool,
        previousBand: PressureBand?,
        currentBand: PressureBand,
        hasActionOutcomes: Bool,
        elapsedSinceLastOutput: Double,
        heartbeatSeconds: Double,
        isOnce: Bool = false
    ) -> ReportCadence {
        if isOnce || isFirstRun || previousBand != currentBand || hasActionOutcomes {
            return .full
        }
        if heartbeatSeconds > 0 && elapsedSinceLastOutput >= heartbeatSeconds {
            return .heartbeat
        }
        return .silent
    }

    public static func formatReport(
        memory: MemorySnapshot,
        result: PlanningResult,
        enabled: Bool,
        reportOnly: Bool,
        actionOutcomes: [(ActionPlan, ActionExecutionOutcome)] = []
    ) -> String {
        let mode = !enabled || reportOnly ? "report-only" : "enforce"
        let available = memory.physicalBytes == 0 ? 0 : (Double(memory.availableBytes) / Double(memory.physicalBytes)) * 100
        let availableText = String(format: "%.1f", available)
        var lines = [
            "mode=\(mode) pressure=\(result.pressure.rawValue) available=\(availableText)% phys=\(ByteFormatter.format(memory.physicalBytes)) swap_used=\(ByteFormatter.format(memory.swapUsedBytes))",
            "metric=phys_footprint groups=\(result.groups.count)"
        ]
        for plan in result.plans.prefix(20) {
            let group = plan.group
            let app = group.application?.bundleIdentifier ?? group.representative.name
            let ratio = group.residentBytes == 0 ? "n/a" : String(format: "%.1fx", Double(group.physicalBytes) / Double(group.residentBytes))
            let badnessText = String(format: "%.3f", group.badness)
            lines.append("pid=\(group.representative.pid) target=\(app) footprint=\(ByteFormatter.format(group.physicalBytes)) rss=\(ByteFormatter.format(group.residentBytes)) footprint/rss=\(ratio) badness=\(badnessText) action=\(plan.safety.rawValue) reason=\(plan.reason)")
        }
        for (plan, outcome) in actionOutcomes {
            lines.append("result pid=\(plan.group.representative.pid) target=\(plan.group.application?.bundleIdentifier ?? plan.group.representative.name) state=\(outcome.state.rawValue) reason=\(outcome.reason)")
        }
        return lines.joined(separator: "\n")
    }

    public static func formatHeartbeat(
        memory: MemorySnapshot,
        result: PlanningResult,
        enabled: Bool,
        reportOnly: Bool,
        cumulativeActions: Int
    ) -> String {
        let mode = !enabled || reportOnly ? "report-only" : "enforce"
        let available = memory.physicalBytes == 0 ? 0 : (Double(memory.availableBytes) / Double(memory.physicalBytes)) * 100
        let availableText = String(format: "%.1f", available)
        let topTarget: String
        let topBadness: String
        if let topGroup = result.groups.first {
            topTarget = topGroup.application?.bundleIdentifier ?? topGroup.representative.name
            topBadness = String(format: "%.3f", topGroup.badness)
        } else {
            topTarget = "none"
            topBadness = "0.000"
        }
        return "[earlyoom] heartbeat mode=\(mode) pressure=\(result.pressure.rawValue) available=\(availableText)% top=\(topTarget) badness=\(topBadness) actions=\(cumulativeActions)"
    }
}
