import Foundation
import Darwin

public struct EarlyoomDaemon {
    public let config: EarlyoomConfig
    private let processSampler: any ProcessSampling
    private let memorySampler: any MemorySampling
    private let actionExecutor: any ProcessActionExecutor
    private let policy: SuppressionPolicy
    private let output: @Sendable (String) -> Void

    public init(
        config: EarlyoomConfig,
        processSampler: any ProcessSampling = DarwinProcessSampler(),
        memorySampler: any MemorySampling = DarwinMemorySampler(),
        actionExecutor: any ProcessActionExecutor = DryRunActionExecutor(),
        currentUID: UInt32 = getuid(),
        currentSessionID: Int32? = getsid(getpid()),
        daemonPID: Int32 = getpid(),
        output: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.config = config
        self.processSampler = processSampler
        self.memorySampler = memorySampler
        self.actionExecutor = actionExecutor
        self.policy = SuppressionPolicy(config: config, currentUID: currentUID, currentSessionID: currentSessionID, daemonPID: daemonPID)
        self.output = output
    }

    @discardableResult
    public func runOnce() throws -> PlanningResult {
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
        output(Self.formatReport(memory: memory, result: result, enabled: config.enabled, reportOnly: config.reportOnly, actionOutcomes: actionOutcomes))
        if let actionError { throw actionError }
        return result
    }
    public func run(repeatCount: Int? = nil) throws {
        var iterations = 0
        while repeatCount == nil || iterations < repeatCount! {
            _ = try runOnce()
            iterations += 1
            if repeatCount == nil || iterations < repeatCount! {
                Thread.sleep(forTimeInterval: config.intervalSeconds)
            }
        }
    }

    public static func formatReport(memory: MemorySnapshot, result: PlanningResult, enabled: Bool, reportOnly: Bool, actionOutcomes: [(ActionPlan, ActionExecutionOutcome)] = []) -> String {
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
}
