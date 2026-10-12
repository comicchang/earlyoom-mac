import Foundation
import Testing
@testable import EarlyoomMac

private let gib: UInt64 = 1024 * 1024 * 1024
private let mib: UInt64 = 1024 * 1024

private func process(
    pid: Int32,
    name: String = "worker",
    uid: UInt32 = 999,
    session: Int32 = 90,
    pgid: Int32? = nil,
    footprint: UInt64,
    rss: UInt64,
    application: ApplicationIdentity? = nil,
    parent: Int32 = 1
) -> ProcessSnapshot {
    ProcessSnapshot(
        pid: pid,
        parentPID: parent,
        processGroupID: pgid ?? pid,
        sessionID: session,
        userID: uid,
        name: name,
        executablePath: application.map { "\($0.applicationPath)/Contents/MacOS/App" },
        physicalBytes: footprint,
        residentBytes: rss,
        application: application
    )
}

private func permissiveEnforcementConfig() -> EarlyoomConfig {
    var config = EarlyoomConfig.safeReportOnly
    config.enabled = true
    config.reportOnly = false
    config.protectCurrentUser = false
    config.protectCurrentSession = false
    config.protectAncestors = false
    config.protectProcessGroups = false
    config.minimumCandidatePhysicalBytes = 1
    config.warnAvailableFraction = 0.50
    config.terminateAvailableFraction = 0.20
    config.killAvailableFraction = 0.05
    return config
}

@Test("default configuration is explicitly report-only")
func defaultConfigurationIsSafe() throws {
    let config = try EarlyoomConfig.parse(text: EarlyoomConfig.defaultConfigurationText)
    #expect(config.enabled == false)
    #expect(config.reportOnly == true)
    #expect(config.guiEscalation == .never)
    #expect(config.allowProcessGroupTermination == false)
    #expect(config.protectedNames.contains("sshd"))
    #expect(config.protectedNames.contains("tmux"))
}

@Test("configuration parser rejects an unknown key and invalid metric")
func configurationRejectsUnsafeTypos() {
    #expect(throws: EarlyoomError.self) {
        try EarlyoomConfig.parse(text: "[earlyoom]\nenabeld = true\n")
    }
    #expect(throws: EarlyoomError.self) {
        try EarlyoomConfig.parse(text: "[check]\nmetric = rss\n")
    }
    #expect(throws: EarlyoomError.self) {
        try EarlyoomConfig.parse(text: "[earlyoom]\ninterval = infs\n")
    }
    #expect(throws: EarlyoomError.self) {
        try EarlyoomConfig.parse(text: "[earlyoom]\ngrace_period = nan\n")
    }
    #expect(throws: EarlyoomError.self) {
        try EarlyoomConfig.parse(text: "[check]\nwarn_available = inf%\n")
    }
    #expect(throws: EarlyoomError.self) {
        try EarlyoomConfig.parse(text: "[check]\nterminate_available = nan\n")
    }
}

@Test("physical footprint wins over a 2500x RSS divergence")
func footprintVsRSSRegression() {
    var config = permissiveEnforcementConfig()
    config.guiEscalation = .never
    let policy = SuppressionPolicy(config: config, currentUID: 501, currentSessionID: nil, daemonPID: 7)
    let pathological = process(pid: 4242, footprint: UInt64(19.84 * Double(gib)), rss: UInt64(7.8 * Double(mib)))
    let ordinary = process(pid: 4243, footprint: 2 * gib, rss: 1500 * mib)
    let memory = MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 256 * mib)
    let result = CandidatePlanner(config: config, policy: policy).plan(memory: memory, processes: [ordinary, pathological])

    #expect(result.pressure == .kill)
    #expect(result.groups.first?.representative.pid == 4242)
    #expect(result.groups.first?.physicalBytes == pathological.physicalBytes)
    #expect(result.groups.first?.residentBytes == pathological.residentBytes)
    #expect((result.groups.first?.badness ?? 0) > (result.groups.last?.badness ?? 1))
    #expect(result.plans.first?.safety == .singleProcess)
    #expect(result.plans.last?.safety == .reportOnly)
}

@Test("planner and daemon cap actions to a single highest-badness group per round")
func singleGroupPerRoundCap() throws {
    var config = permissiveEnforcementConfig()
    config.guiEscalation = .never
    let policy = SuppressionPolicy(config: config, currentUID: 501, currentSessionID: nil, daemonPID: 7)
    let protectedTop = process(pid: 100, name: "WindowServer", uid: 0, footprint: 10 * gib, rss: gib)
    let firstEligible = process(pid: 200, name: "worker-1", footprint: 6 * gib, rss: gib)
    let secondEligible = process(pid: 201, name: "worker-2", footprint: 4 * gib, rss: gib)
    let thirdEligible = process(pid: 202, name: "worker-3", footprint: 2 * gib, rss: gib)
    let memory = MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 256 * mib)

    let result = CandidatePlanner(config: config, policy: policy).plan(
        memory: memory,
        processes: [thirdEligible, protectedTop, secondEligible, firstEligible]
    )
    #expect(result.plans.count == 4)
    #expect(result.plans[0].group.representative.pid == 100)
    #expect(result.plans[0].safety == .protectedTarget)
    #expect(result.plans[1].group.representative.pid == 200)
    #expect(result.plans[1].safety == .singleProcess)
    #expect(result.plans[2].group.representative.pid == 201)
    #expect(result.plans[2].safety == .reportOnly)
    #expect(result.plans[2].reason.contains("deferred to higher-badness candidate"))
    #expect(result.plans[3].group.representative.pid == 202)
    #expect(result.plans[3].safety == .reportOnly)

    let executor = MockActionExecutor(outcome: ActionExecutionOutcome(state: .executed, reason: "delivered"))
    let daemon = EarlyoomDaemon(
        config: config,
        processSampler: FixedProcessSampler(values: [thirdEligible, protectedTop, secondEligible, firstEligible]),
        memorySampler: FixedMemorySampler(value: memory),
        actionExecutor: executor,
        currentUID: 501,
        currentSessionID: nil,
        daemonPID: 7,
        lockURL: FileManager.default.temporaryDirectory.appendingPathComponent("cap-lock-\(UUID().uuidString)"),
        output: { _ in }
    )
    try daemon.run(repeatCount: 1)
    #expect(executor.executedPlans.count == 1)
    #expect(executor.executedPlans.first?.group.representative.pid == 200)
}

@Test("criticality weight multiplies physical-footprint badness")
func criticalityWeightChangesOrdering() {
    var config = permissiveEnforcementConfig()
    config.criticalityWeights = ["worker-a": 2.0, "worker-b": 0.5]
    let policy = SuppressionPolicy(config: config, currentUID: 501, currentSessionID: nil, daemonPID: 7)
    let lowerFootprintHigherWeight = process(pid: 500, name: "worker-a", footprint: 4 * gib, rss: gib)
    let higherFootprintLowerWeight = process(pid: 501, name: "worker-b", footprint: 6 * gib, rss: 2 * gib)
    let memory = MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 128 * mib)
    let result = CandidatePlanner(config: config, policy: policy).plan(memory: memory, processes: [higherFootprintLowerWeight, lowerFootprintHigherWeight])
    #expect(result.groups.first?.representative.pid == 500)
    #expect(result.groups.first?.badness == 0.5)
}

@Test("required macOS infrastructure and work-session names are suppressed")
func macOSSafetyNamesAreProtected() {
    let config = EarlyoomConfig.safeReportOnly
    let policy = SuppressionPolicy(config: config, currentUID: 501, currentSessionID: nil, daemonPID: 9999)
    let names = ["launchd", "kernel_task", "WindowServer", "loginwindow", "mDNSResponder", "securityd", "syspolicyd", "coreaudiod", "sshd", "sshd-session", "tmux", "Ghostty"]
    for (offset, name) in names.enumerated() {
        let candidate = process(pid: Int32(100 + offset), name: name, uid: 0, footprint: 2 * gib, rss: gib)
        #expect(policy.reason(for: candidate, allProcesses: [candidate]) != nil, "\(name) must be protected")
    }
}

@Test("mandatory suppression names cannot be removed by an empty local list")
func mandatorySuppressionCannotBeCleared() {
    var config = EarlyoomConfig.safeReportOnly
    config.protectedNames = []
    let policy = SuppressionPolicy(config: config, currentUID: 501, currentSessionID: nil, daemonPID: 9999)
    let windowServer = process(pid: 77, name: "WindowServer", uid: 0, footprint: gib, rss: mib)
    #expect(policy.reason(for: windowServer, allProcesses: [windowServer]) != nil)
}

@Test("current user and current login session are protected by default")
func currentSessionProtection() {
    let config = EarlyoomConfig.safeReportOnly
    let policy = SuppressionPolicy(config: config, currentUID: 501, currentSessionID: 44, daemonPID: 9999)
    let currentUser = process(pid: 12, uid: 501, session: 99, footprint: gib, rss: mib)
    let currentSession = process(pid: 13, uid: 0, session: 44, footprint: gib, rss: mib)
    #expect(policy.reason(for: currentUser, allProcesses: [currentUser]) == "current user")
    #expect(policy.reason(for: currentSession, allProcesses: [currentSession]) == "current login session")
}

@Test("process-group protection includes daemon ancestors and descendants")
func processGroupProtectsDaemonRelatives() {
    var config = EarlyoomConfig.safeReportOnly
    config.protectCurrentUser = false
    config.protectCurrentSession = false
    config.protectAncestors = true
    config.protectProcessGroups = true
    let policy = SuppressionPolicy(config: config, currentUID: 501, currentSessionID: nil, daemonPID: 700)

    let parentShell = process(pid: 600, name: "custom-launcher", uid: 501, pgid: 600, footprint: 10 * mib, rss: 5 * mib, parent: 1)
    let daemonProc = process(pid: 700, name: "earlyoom-mac", uid: 501, pgid: 700, footprint: 10 * mib, rss: 5 * mib, parent: 600)
    let daemonChild = process(pid: 701, name: "probe-helper", uid: 501, pgid: 701, footprint: 10 * mib, rss: 5 * mib, parent: 700)
    let siblingWorker = process(pid: 601, name: "worker", uid: 501, pgid: 600, footprint: 4 * gib, rss: gib, parent: 600)
    let all = [parentShell, daemonProc, daemonChild, siblingWorker]

    #expect(policy.reason(for: parentShell, allProcesses: all) == "earlyoom-mac ancestor or descendant")
    #expect(policy.reason(for: daemonChild, allProcesses: all) == "earlyoom-mac ancestor or descendant")
    #expect(policy.reason(for: siblingWorker, allProcesses: all) == "process group contains a protected session process")
}

@Test("root daemon refuses to guess a user's console session")
func rootDaemonProtectsNonRootUsers() {
    var config = EarlyoomConfig.safeReportOnly
    config.protectCurrentUser = false
    config.protectCurrentSession = false
    let policy = SuppressionPolicy(config: config, currentUID: 0, currentSessionID: 0, daemonPID: 9999)
    let userProcess = process(pid: 22, uid: 501, session: 44, footprint: gib, rss: mib)
    #expect(policy.reason(for: userProcess, allProcesses: [userProcess]) == "user session identity unavailable to root daemon")
}

@Test("bundle identity is resolved from an app's Info.plist, not its process name")
func bundleIdentityResolution() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyoomFixture-\(UUID().uuidString).app")
    let executable = root.appendingPathComponent("Contents/MacOS/SharedHelper")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": "org.example.Editor", "CFBundleName": "Editor"]
    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try plistData.write(to: root.appendingPathComponent("Contents/Info.plist"))
    defer { try? FileManager.default.removeItem(at: root) }

    let identity = BundleIdentityResolver().resolve(executablePath: executable.path)
    #expect(identity?.bundleIdentifier == "org.example.Editor")
    #expect(identity?.applicationPath == root.path)

    let nestedHelper = root.appendingPathComponent("Contents/Frameworks/Editor Helper (Renderer).app/Contents/MacOS/Editor Helper (Renderer)")
    let nestedIdentity = BundleIdentityResolver().resolve(executablePath: nestedHelper.path)
    #expect(nestedIdentity?.bundleIdentifier == "org.example.Editor")
    #expect(nestedIdentity?.applicationPath == root.path)
}

@Test("GUI policy maps to graceful, force, or process-group stages")
func guiDecisionTable() {
    let identity = ApplicationIdentity(bundleIdentifier: "org.example.Editor", applicationPath: "/Applications/Editor.app")
    let gui = process(pid: 300, footprint: 5 * gib, rss: 2 * gib, application: identity)
    let memory = MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 128 * mib)
    for (policyValue, expected) in [
        (GUIEscalation.never, ActionSafety.reportOnly),
        (.gracefulThenForce, .gracefulApplication),
        (.forceApplication, .forceApplication)
    ] as [(GUIEscalation, ActionSafety)] {
        var config = permissiveEnforcementConfig()
        config.guiEscalation = policyValue
        let suppression = SuppressionPolicy(config: config, currentUID: 501, currentSessionID: nil, daemonPID: 7)
        let result = CandidatePlanner(config: config, policy: suppression).plan(memory: memory, processes: [gui])
        #expect(result.plans.first?.safety == expected)
    }

    var processGroupConfig = permissiveEnforcementConfig()
    processGroupConfig.guiEscalation = .processGroup
    processGroupConfig.allowProcessGroupTermination = true
    let processGroupPolicy = SuppressionPolicy(config: processGroupConfig, currentUID: 501, currentSessionID: nil, daemonPID: 7)
    let processGroupResult = CandidatePlanner(config: processGroupConfig, policy: processGroupPolicy).plan(memory: memory, processes: [gui])
    #expect(processGroupResult.plans.first?.safety == .processGroup)
}

private struct FixedProcessSampler: ProcessSampling {
    let values: [ProcessSnapshot]
    func sample() throws -> [ProcessSnapshot] { values }
}

private struct FixedMemorySampler: MemorySampling {
    let value: MemorySnapshot
    func sample() throws -> MemorySnapshot { value }
}

private final class RecordingExecutor: ProcessActionExecutor {
    var calls = 0
    func execute(_ plan: ActionPlan, gracePeriodSeconds: Double) throws { calls += 1 }
}

@Test("daemon default mode reports but never calls an action executor")
func daemonDefaultDoesNotAct() throws {
    let config = EarlyoomConfig.safeReportOnly
    let recorder = RecordingExecutor()
    let daemon = EarlyoomDaemon(
        config: config,
        processSampler: FixedProcessSampler(values: [process(pid: 88, footprint: 8 * gib, rss: mib)]),
        memorySampler: FixedMemorySampler(value: MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 32 * mib)),
        actionExecutor: recorder,
        currentUID: 501,
        currentSessionID: nil,
        daemonPID: 7,
        output: { _ in }
    )
    let result = try daemon.runOnce()
    #expect(result.pressure == .kill)
    #expect(recorder.calls == 0)
}

private final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) {
        self.value = value
    }

    func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    var current: T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
private struct SignalRecord: Equatable, Sendable {
    let pid: Int32
    let sig: Int32
}

private final class MutableMemorySampler: MemorySampling, @unchecked Sendable {
    private var snapshots: [MemorySnapshot]
    private let lock = NSLock()

    init(snapshots: [MemorySnapshot]) {
        self.snapshots = snapshots
    }

    func sample() throws -> MemorySnapshot {
        lock.lock()
        defer { lock.unlock() }
        if snapshots.count > 1 {
            return snapshots.removeFirst()
        }
        return snapshots.first!
    }
}

private final class FailingSampler: MemorySampling, @unchecked Sendable {
    var callCount = 0
    let lock = NSLock()
    let errorOnFirstCall: Bool

    init(errorOnFirstCall: Bool = true) {
        self.errorOnFirstCall = errorOnFirstCall
    }

    func sample() throws -> MemorySnapshot {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        if errorOnFirstCall && callCount == 1 {
            throw EarlyoomError.cannotReadMemory("simulated sampling error")
        }
        return MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 8 * gib)
    }
}

private final class MockActionExecutor: ProcessActionExecutor, @unchecked Sendable {
    let outcome: ActionExecutionOutcome
    var executedPlans: [ActionPlan] = []
    let lock = NSLock()

    init(outcome: ActionExecutionOutcome) {
        self.outcome = outcome
    }

    func execute(_ plan: ActionPlan, gracePeriodSeconds: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        executedPlans.append(plan)
    }

    func executeWithOutcome(_ plan: ActionPlan, gracePeriodSeconds: Double) throws -> ActionExecutionOutcome {
        lock.lock()
        defer { lock.unlock() }
        executedPlans.append(plan)
        return outcome
    }
}

@Test("configuration parses and validates heartbeat duration")
func heartbeatConfiguration() throws {
    let defaultConfig = try EarlyoomConfig.parse(text: EarlyoomConfig.defaultConfigurationText)
    #expect(defaultConfig.heartbeatSeconds == 300)

    let customText = """
    [earlyoom]
    enabled = false
    report_only = true
    interval = 5s
    grace_period = 10s
    heartbeat = 45s

    [check]
    metric = phys_footprint
    warn_available = 20%
    terminate_available = 10%
    kill_available = 5%
    minimum_candidate = 64MiB
    """
    let customConfig = try EarlyoomConfig.parse(text: customText)
    #expect(customConfig.heartbeatSeconds == 45)

    #expect(throws: EarlyoomError.self) {
        try EarlyoomConfig.parse(text: "[earlyoom]\nheartbeat = -5s\n")
    }
    #expect(throws: EarlyoomError.self) {
        try EarlyoomConfig.parse(text: "[earlyoom]\nheartbeat = 0s\n")
    }
}

@Test("report cadence decision table covers full, heartbeat, and silent modes across all four pressure levels")
func reportCadenceDecisionTable() {
    // First run is always full
    #expect(EarlyoomDaemon.determineReportCadence(
        isFirstRun: true,
        previousPressure: nil,
        currentPressure: .normal,
        hasActionOutcomes: false,
        elapsedSinceLastOutput: 0,
        heartbeatSeconds: 300
    ) == .full)

    // Steady state without change is silent
    #expect(EarlyoomDaemon.determineReportCadence(
        isFirstRun: false,
        previousPressure: .normal,
        currentPressure: .normal,
        hasActionOutcomes: false,
        elapsedSinceLastOutput: 50,
        heartbeatSeconds: 300
    ) == .silent)

    // Pressure level changes trigger full report (including terminate <-> kill)
    #expect(EarlyoomDaemon.determineReportCadence(
        isFirstRun: false,
        previousPressure: .normal,
        currentPressure: .warn,
        hasActionOutcomes: false,
        elapsedSinceLastOutput: 50,
        heartbeatSeconds: 300
    ) == .full)
    #expect(EarlyoomDaemon.determineReportCadence(
        isFirstRun: false,
        previousPressure: .warn,
        currentPressure: .terminate,
        hasActionOutcomes: false,
        elapsedSinceLastOutput: 10,
        heartbeatSeconds: 300
    ) == .full)
    #expect(EarlyoomDaemon.determineReportCadence(
        isFirstRun: false,
        previousPressure: .terminate,
        currentPressure: .kill,
        hasActionOutcomes: false,
        elapsedSinceLastOutput: 10,
        heartbeatSeconds: 300
    ) == .full)
    #expect(EarlyoomDaemon.determineReportCadence(
        isFirstRun: false,
        previousPressure: .kill,
        currentPressure: .terminate,
        hasActionOutcomes: false,
        elapsedSinceLastOutput: 10,
        heartbeatSeconds: 300
    ) == .full)

    // Action outcomes (executed, attempted, or rejected) trigger full report
    #expect(EarlyoomDaemon.determineReportCadence(
        isFirstRun: false,
        previousPressure: .terminate,
        currentPressure: .terminate,
        hasActionOutcomes: true,
        elapsedSinceLastOutput: 2,
        heartbeatSeconds: 300
    ) == .full)

    // Heartbeat elapsed triggers heartbeat line
    #expect(EarlyoomDaemon.determineReportCadence(
        isFirstRun: false,
        previousPressure: .normal,
        currentPressure: .normal,
        hasActionOutcomes: false,
        elapsedSinceLastOutput: 300,
        heartbeatSeconds: 300
    ) == .heartbeat)
    #expect(EarlyoomDaemon.determineReportCadence(
        isFirstRun: false,
        previousPressure: .normal,
        currentPressure: .normal,
        hasActionOutcomes: false,
        elapsedSinceLastOutput: 350,
        heartbeatSeconds: 300
    ) == .heartbeat)

    // Non-positive heartbeatSeconds disables periodic heartbeat programmatically
    #expect(EarlyoomDaemon.determineReportCadence(
        isFirstRun: false,
        previousPressure: .normal,
        currentPressure: .normal,
        hasActionOutcomes: false,
        elapsedSinceLastOutput: 500,
        heartbeatSeconds: 0
    ) == .silent)

    // --once mode is always full
    #expect(EarlyoomDaemon.determineReportCadence(
        isFirstRun: false,
        previousPressure: .normal,
        currentPressure: .normal,
        hasActionOutcomes: false,
        elapsedSinceLastOutput: 10,
        heartbeatSeconds: 300,
        isOnce: true
    ) == .full)
}

@Test("daemon cadence outputs full report on first run, suppresses steady state, and emits heartbeat summary")
func daemonCadenceInSteadyState() throws {
    let timeBox = LockedBox(Date(timeIntervalSince1970: 1000))
    let nowProvider: @Sendable () -> Date = {
        timeBox.current
    }

    let outputBox = LockedBox<[String]>([])
    let outputCollector: @Sendable (String) -> Void = { line in
        outputBox.withValue { $0.append(line) }
    }

    var config = EarlyoomConfig.safeReportOnly
    config.heartbeatSeconds = 300
    config.intervalSeconds = 5

    let daemon = EarlyoomDaemon(
        config: config,
        processSampler: FixedProcessSampler(values: [process(pid: 88, footprint: 8 * gib, rss: mib)]),
        memorySampler: FixedMemorySampler(value: MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 12 * gib)),
        actionExecutor: RecordingExecutor(),
        output: outputCollector,
        sleeper: { _ in },
        clock: nowProvider
    )

    // Iteration 1: first run -> outputs full report
    try daemon.run(repeatCount: 1)
    #expect(outputBox.current.count == 1)
    #expect(outputBox.current[0].hasPrefix("mode=report-only pressure=normal"))

    // Run 3 iterations continuously in one call to test steady state & heartbeat transition
    let continuousOutputBox = LockedBox<[String]>([])
    let continuousDaemon = EarlyoomDaemon(
        config: config,
        processSampler: FixedProcessSampler(values: [process(pid: 88, footprint: 8 * gib, rss: mib)]),
        memorySampler: FixedMemorySampler(value: MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 12 * gib)),
        actionExecutor: RecordingExecutor(),
        output: { line in
            continuousOutputBox.withValue { $0.append(line) }
        },
        sleeper: { _ in
            timeBox.withValue { $0 = $0.addingTimeInterval(150) }
        },
        clock: nowProvider
    )

    try continuousDaemon.run(repeatCount: 3)
    let logs = continuousOutputBox.current
    #expect(logs.count == 2)
    #expect(logs[0].hasPrefix("mode=report-only"))
    #expect(logs[1].hasPrefix("[earlyoom] heartbeat mode=report-only"))
    #expect(logs[1].contains("pressure=normal"))
    #expect(logs[1].contains("available="))
    #expect(logs[1].contains("top="))
    #expect(logs[1].contains("actions="))

    // Empty candidate groups in heartbeat emits top=none badness=0.000
    let emptyHeartbeat = EarlyoomDaemon.formatHeartbeat(
        memory: MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 12 * gib),
        result: PlanningResult(pressure: .normal, availableFraction: 0.75, groups: [], plans: []),
        enabled: false,
        reportOnly: true,
        cumulativeActions: 0
    )
    #expect(emptyHeartbeat.contains("top=none badness=0.000 actions=0"))
}

@Test("daemon loop skips round on sampling failure and logs error to stderr")
func daemonSamplingFailureSkipsRound() throws {
    let failingSampler = FailingSampler(errorOnFirstCall: true)
    let errorBox = LockedBox<[String]>([])

    let daemon = EarlyoomDaemon(
        config: EarlyoomConfig.safeReportOnly,
        processSampler: FixedProcessSampler(values: [process(pid: 88, footprint: 8 * gib, rss: mib)]),
        memorySampler: failingSampler,
        actionExecutor: RecordingExecutor(),
        output: { _ in },
        errorOutput: { err in
            errorBox.withValue { $0.append(err) }
        },
        sleeper: { _ in }
    )

    try daemon.run(repeatCount: 2, stopOnSamplingError: false)
    let errors = errorBox.current
    #expect(errors.count == 1)
    #expect(errors[0].contains("[error] sampling failed:"))
    #expect(failingSampler.callCount == 2)

    let failingOnceSampler = FailingSampler(errorOnFirstCall: true)
    let onceDaemon = EarlyoomDaemon(
        config: EarlyoomConfig.safeReportOnly,
        processSampler: FixedProcessSampler(values: []),
        memorySampler: failingOnceSampler,
        actionExecutor: RecordingExecutor(),
        output: { _ in }
    )
    #expect(throws: EarlyoomError.self) {
        try onceDaemon.run(repeatCount: 1)
    }
    // Action execution error (e.g. EPERM) is logged in daemon mode without crashing, but thrown in --once mode
    final class ThrowingExecutor: ProcessActionExecutor, @unchecked Sendable {
        var calls = 0
        func execute(_ plan: ActionPlan, gracePeriodSeconds: Double) throws {
            calls += 1
            throw EarlyoomError.cannotReadProcess(plan.group.representative.pid, "Operation not permitted")
        }
        func executeWithOutcome(_ plan: ActionPlan, gracePeriodSeconds: Double) throws -> ActionExecutionOutcome {
            calls += 1
            throw EarlyoomError.cannotReadProcess(plan.group.representative.pid, "Operation not permitted")
        }
    }

    var enforceConfig = permissiveEnforcementConfig()
    enforceConfig.intervalSeconds = 1
    let actionErrorBox = LockedBox<[String]>([])
    let throwingExecutor = ThrowingExecutor()
    let resilientDaemon = EarlyoomDaemon(
        config: enforceConfig,
        processSampler: FixedProcessSampler(values: [process(pid: 88, footprint: 8 * gib, rss: mib)]),
        memorySampler: FixedMemorySampler(value: MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 256 * mib)),
        actionExecutor: throwingExecutor,
        currentUID: 501,
        currentSessionID: nil,
        daemonPID: 7,
        lockURL: FileManager.default.temporaryDirectory.appendingPathComponent("err-lock-\(UUID().uuidString)"),
        output: { _ in },
        errorOutput: { err in actionErrorBox.withValue { $0.append(err) } },
        sleeper: { _ in }
    )
    try resilientDaemon.run(repeatCount: 2)
    #expect(throwingExecutor.calls == 2)
    #expect(actionErrorBox.current.count == 2)
    #expect(actionErrorBox.current[0].contains("[error] action execution failed:"))

    let onceThrowingDaemon = EarlyoomDaemon(
        config: enforceConfig,
        processSampler: FixedProcessSampler(values: [process(pid: 88, footprint: 8 * gib, rss: mib)]),
        memorySampler: FixedMemorySampler(value: MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 256 * mib)),
        actionExecutor: ThrowingExecutor(),
        currentUID: 501,
        currentSessionID: nil,
        daemonPID: 7,
        lockURL: FileManager.default.temporaryDirectory.appendingPathComponent("once-err-lock-\(UUID().uuidString)"),
        output: { _ in },
        errorOutput: { _ in },
        sleeper: { _ in }
    )
    #expect(throws: EarlyoomError.self) {
        try onceThrowingDaemon.run(repeatCount: 1)
    }
}

@Test("enforce mode single-instance lock prevents concurrent execution at lock and daemon levels")
func enforceLockSingleInstanceMutex() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("earlyoom-lock-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let lockURL = tempDir.appendingPathComponent("enforce.lock")

    let reportOnlyDaemon = EarlyoomDaemon(
        config: EarlyoomConfig.safeReportOnly,
        lockURL: lockURL,
        output: { _ in }
    )
    #expect(reportOnlyDaemon.enforceLock == nil)

    let lock1 = EnforceLock(url: lockURL)
    try lock1.acquire()
    #expect(lock1.isHeld == true)

    let lock2 = EnforceLock(url: lockURL)
    do {
        try lock2.acquire()
        Issue.record("expected EnforceLock.acquire() to throw .lockAlreadyHeld")
    } catch EarlyoomError.lockAlreadyHeld {
        // expected
    }

    // Daemon-level enforce lock contention must also throw .lockAlreadyHeld
    let contendingDaemon = EarlyoomDaemon(
        config: permissiveEnforcementConfig(),
        processSampler: FixedProcessSampler(values: []),
        memorySampler: FixedMemorySampler(value: MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 12 * gib)),
        actionExecutor: RecordingExecutor(),
        lockURL: lockURL,
        output: { _ in }
    )
    do {
        try contendingDaemon.runOnce()
        Issue.record("expected contending EarlyoomDaemon.runOnce() to throw .lockAlreadyHeld")
    } catch EarlyoomError.lockAlreadyHeld {
        // expected
    }

    lock1.release()
    #expect(lock1.isHeld == false)
    let postReleaseResult = try contendingDaemon.runOnce()
    #expect(postReleaseResult.pressure == .normal)
    #expect(contendingDaemon.enforceLock?.isHeld == false)
}

@Test("DarwinActionExecutor performs early SIGKILL when memory pressure drops below kill threshold during grace period")
func gracePeriodEarlyKillOnPressureDrop() throws {
    let mem1 = MemorySnapshot(physicalBytes: 16 * gib, availableBytes: UInt64(1.6 * Double(gib)))
    let mem2 = MemorySnapshot(physicalBytes: 16 * gib, availableBytes: UInt64(0.64 * Double(gib)))
    let dynamicMemorySampler = MutableMemorySampler(snapshots: [mem1, mem1, mem2])

    let signalBox = LockedBox<[SignalRecord]>([])
    let mockSender: @Sendable (Int32, Int32) -> Int32 = { pid, sig in
        signalBox.withValue { $0.append(SignalRecord(pid: pid, sig: sig)) }
        return 0
    }

    let sleepBox = LockedBox<[Double]>([])
    let mockSleeper: @Sendable (Double) -> Void = { duration in
        sleepBox.withValue { $0.append(duration) }
    }

    let executor = DarwinActionExecutor(
        memorySampler: dynamicMemorySampler,
        killAvailableFraction: 0.05,
        gracePollSeconds: 1.0,
        sleeper: mockSleeper,
        pidVerifier: { pid, startTime in true },
        signalSender: mockSender
    )

    let targetProcess = ProcessSnapshot(
        pid: 7777,
        parentPID: 1,
        processGroupID: 7777,
        sessionID: 10,
        userID: 501,
        name: "runaway-worker",
        physicalBytes: 4 * gib,
        residentBytes: 2 * gib,
        startTimeSeconds: 12345
    )
    let group = CandidateGroup(
        key: "process:7777",
        representative: targetProcess,
        members: [targetProcess],
        physicalBytes: 4 * gib,
        residentBytes: 2 * gib,
        application: nil,
        badness: 0.25,
        safety: .singleProcess
    )
    let plan = ActionPlan(group: group, safety: .singleProcess, reason: "exceeded memory threshold")

    let outcome = try executor.executeWithOutcome(plan, gracePeriodSeconds: 10.0)
    #expect(outcome.state == .executed)

    let deliveredSignals = signalBox.current.filter { $0.sig != 0 }
    #expect(deliveredSignals == [SignalRecord(pid: 7777, sig: SIGTERM), SignalRecord(pid: 7777, sig: SIGKILL)])
    let sleepDurations = sleepBox.current
    #expect(sleepDurations.count == 2)
    #expect(sleepDurations.reduce(0, +) == 2.0)

    // Already at .kill pressure at grace entry: must not sleep 1s before escalating to SIGKILL
    let immediateSleepBox = LockedBox<[Double]>([])
    let immediateExecutor = DarwinActionExecutor(
        memorySampler: FixedMemorySampler(value: mem2),
        killAvailableFraction: 0.05,
        gracePollSeconds: 1.0,
        sleeper: { duration in immediateSleepBox.withValue { $0.append(duration) } },
        pidVerifier: { _, _ in true },
        signalSender: { _, _ in 0 }
    )
    _ = try immediateExecutor.executeWithOutcome(plan, gracePeriodSeconds: 10.0)
    #expect(immediateSleepBox.current.isEmpty)

    // gracePeriodSeconds == 0: immediate SIGTERM -> SIGKILL without sleeping
    let zeroGraceSleepBox = LockedBox<[Double]>([])
    let zeroGraceSignals = LockedBox<[SignalRecord]>([])
    let zeroGraceExecutor = DarwinActionExecutor(
        memorySampler: FixedMemorySampler(value: mem1),
        killAvailableFraction: 0.05,
        gracePollSeconds: 1.0,
        sleeper: { duration in zeroGraceSleepBox.withValue { $0.append(duration) } },
        pidVerifier: { _, _ in true },
        signalSender: { pid, sig in
            zeroGraceSignals.withValue { $0.append(SignalRecord(pid: pid, sig: sig)) }
            return 0
        }
    )
    let zeroOutcome = try zeroGraceExecutor.executeWithOutcome(plan, gracePeriodSeconds: 0.0)
    #expect(zeroOutcome.state == .executed)
    #expect(zeroGraceSleepBox.current.isEmpty)
    #expect(zeroGraceSignals.current.filter { $0.sig != 0 } == [
        SignalRecord(pid: 7777, sig: SIGTERM),
        SignalRecord(pid: 7777, sig: SIGKILL)
    ])

    // Grace-period memory sampling failure falls back to waiting full gracePeriodSeconds
    struct AlwaysFailingMemorySampler: MemorySampling {
        func sample() throws -> MemorySnapshot {
            throw EarlyoomError.cannotReadMemory("transient mach failure")
        }
    }
    let fallbackSleepBox = LockedBox<[Double]>([])
    let fallbackExecutor = DarwinActionExecutor(
        memorySampler: AlwaysFailingMemorySampler(),
        killAvailableFraction: 0.05,
        gracePollSeconds: 1.0,
        sleeper: { duration in fallbackSleepBox.withValue { $0.append(duration) } },
        pidVerifier: { _, _ in true },
        signalSender: { _, _ in 0 }
    )
    let fallbackOutcome = try fallbackExecutor.executeWithOutcome(plan, gracePeriodSeconds: 3.0)
    #expect(fallbackOutcome.state == .executed)
    #expect(fallbackSleepBox.current == [1.0, 1.0, 1.0])
}

@Test("DarwinActionExecutor respects PID reuse guard before delivering SIGKILL")
func gracePeriodPIDReuseGuard() throws {
    let mem = MemorySnapshot(physicalBytes: 16 * gib, availableBytes: UInt64(0.5 * Double(gib)))

    // Case 1: First check (before SIGTERM) passes, second check (before SIGKILL) fails.
    // Proves that SIGKILL-stage identity re-verification actively prevents sending SIGKILL
    // to a reused PID.
    let callCountBox = LockedBox<Int>(0)
    let reusedSignalBox = LockedBox<[SignalRecord]>([])

    let reuseGuardedExecutor = DarwinActionExecutor(
        memorySampler: FixedMemorySampler(value: mem),
        killAvailableFraction: 0.05,
        gracePollSeconds: 1.0,
        sleeper: { _ in },
        pidVerifier: { pid, startTime in
            callCountBox.withValue { count in
                count += 1
                return count == 1 // 1st call (pre-TERM) succeeds, 2nd call (pre-KILL) fails
            }
        },
        signalSender: { pid, sig in
            reusedSignalBox.withValue { $0.append(SignalRecord(pid: pid, sig: sig)) }
            return 0
        }
    )

    let targetProcess = ProcessSnapshot(
        pid: 8888,
        parentPID: 1,
        processGroupID: 8888,
        sessionID: 10,
        userID: 501,
        name: "worker",
        physicalBytes: 4 * gib,
        residentBytes: 2 * gib,
        startTimeSeconds: 99999
    )
    let group = CandidateGroup(
        key: "process:8888",
        representative: targetProcess,
        members: [targetProcess],
        physicalBytes: 4 * gib,
        residentBytes: 2 * gib,
        application: nil,
        badness: 0.25,
        safety: .singleProcess
    )
    let plan = ActionPlan(group: group, safety: .singleProcess, reason: "memory limit")

    let outcomeReused = try reuseGuardedExecutor.executeWithOutcome(plan, gracePeriodSeconds: 5.0)
    #expect(outcomeReused.state == .executed)
    let nonZeroReused = reusedSignalBox.current.filter { $0.sig != 0 }
    #expect(nonZeroReused == [SignalRecord(pid: 8888, sig: SIGTERM)])
    #expect(callCountBox.current >= 2)

    // Case 2: Both checks pass -> SIGKILL is reachable and delivered.
    let reachableSignalBox = LockedBox<[SignalRecord]>([])
    let verifiedExecutor = DarwinActionExecutor(
        memorySampler: FixedMemorySampler(value: mem),
        killAvailableFraction: 0.05,
        gracePollSeconds: 1.0,
        sleeper: { _ in },
        pidVerifier: { pid, startTime in true },
        signalSender: { pid, sig in
            reachableSignalBox.withValue { $0.append(SignalRecord(pid: pid, sig: sig)) }
            return 0
        }
    )

    let outcomeVerified = try verifiedExecutor.executeWithOutcome(plan, gracePeriodSeconds: 5.0)
    #expect(outcomeVerified.state == .executed)
    let nonZeroVerified = reachableSignalBox.current.filter { $0.sig != 0 }
    #expect(nonZeroVerified == [SignalRecord(pid: 8888, sig: SIGTERM), SignalRecord(pid: 8888, sig: SIGKILL)])
}

@Test("DarwinActionExecutor processGroup escalates surviving culprit after partial exit and guards against PID reuse")
func processGroupPartialExitAndPIDReuseGuard() throws {
    let mem = MemorySnapshot(physicalBytes: 16 * gib, availableBytes: UInt64(1.6 * Double(gib)))
    let helper = ProcessSnapshot(
        pid: 5000,
        parentPID: 1,
        processGroupID: 5000,
        sessionID: 10,
        userID: 501,
        name: "helper",
        physicalBytes: 2 * gib,
        residentBytes: gib,
        startTimeSeconds: 1000
    )
    let culprit = ProcessSnapshot(
        pid: 5001,
        parentPID: 5000,
        processGroupID: 5000,
        sessionID: 10,
        userID: 501,
        name: "culprit",
        physicalBytes: 8 * gib,
        residentBytes: 4 * gib,
        startTimeSeconds: 1001
    )
    let group = CandidateGroup(
        key: "process-group:5000",
        representative: culprit,
        members: [culprit, helper],
        physicalBytes: 10 * gib,
        residentBytes: 5 * gib,
        application: nil,
        badness: 0.625,
        safety: .processGroup
    )
    let plan = ActionPlan(group: group, safety: .processGroup, reason: "terminate process group")

    // Case 1: Helper (5000) exits after SIGTERM; culprit (5001) survives and must still receive SIGKILL.
    let termSentBox = LockedBox(false)
    let case1Signals = LockedBox<[SignalRecord]>([])
    let case1Executor = DarwinActionExecutor(
        memorySampler: FixedMemorySampler(value: mem),
        killAvailableFraction: 0.05,
        gracePollSeconds: 1.0,
        sleeper: { _ in },
        pidVerifier: { pid, _ in
            if pid == 5000 && termSentBox.current {
                return false // helper exited during grace period, so proc_pidinfo fails
            }
            return true
        },
        signalSender: { pid, sig in
            case1Signals.withValue { $0.append(SignalRecord(pid: pid, sig: sig)) }
            if pid == -5000 && sig == SIGTERM {
                termSentBox.withValue { $0 = true }
                return 0
            }
            if pid == 5000 && sig == 0 && termSentBox.current {
                errno = ESRCH
                return -1
            }
            return 0
        }
    )
    let case1Outcome = try case1Executor.executeWithOutcome(plan, gracePeriodSeconds: 2.0)
    #expect(case1Outcome.state == .executed)
    #expect(case1Signals.current.filter { $0.sig != 0 } == [
        SignalRecord(pid: -5000, sig: SIGTERM),
        SignalRecord(pid: -5000, sig: SIGKILL)
    ])

    // Case 2: Helper (5000) exits and its PID is reused by a new live process; culprit (5001) survives.
    // Group SIGKILL (-5000) and reused PID (5000) must be refused; verified survivor (5001) receives per-PID SIGKILL.
    let case2TermSent = LockedBox(false)
    let case2Signals = LockedBox<[SignalRecord]>([])
    let case2Executor = DarwinActionExecutor(
        memorySampler: FixedMemorySampler(value: mem),
        killAvailableFraction: 0.05,
        gracePollSeconds: 1.0,
        sleeper: { _ in },
        pidVerifier: { pid, _ in
            if pid == 5000 && case2TermSent.current {
                return false // PID 5000 is alive but belongs to a new process with a different start time
            }
            return true
        },
        signalSender: { pid, sig in
            case2Signals.withValue { $0.append(SignalRecord(pid: pid, sig: sig)) }
            if pid == -5000 && sig == SIGTERM {
                case2TermSent.withValue { $0 = true }
            }
            return 0
        }
    )
    let case2Outcome = try case2Executor.executeWithOutcome(plan, gracePeriodSeconds: 2.0)
    #expect(case2Outcome.state == .executed)
    #expect(case2Signals.current.filter { $0.sig != 0 } == [
        SignalRecord(pid: -5000, sig: SIGTERM),
        SignalRecord(pid: 5001, sig: SIGKILL)
    ])

    // Case 3: All alive members have reused PIDs before SIGKILL -> no SIGKILL is sent at all.
    let case3TermSent = LockedBox(false)
    let case3Signals = LockedBox<[SignalRecord]>([])
    let case3Executor = DarwinActionExecutor(
        memorySampler: FixedMemorySampler(value: mem),
        killAvailableFraction: 0.05,
        gracePollSeconds: 1.0,
        sleeper: { _ in },
        pidVerifier: { _, _ in
            !case3TermSent.current
        },
        signalSender: { pid, sig in
            case3Signals.withValue { $0.append(SignalRecord(pid: pid, sig: sig)) }
            if pid == -5000 && sig == SIGTERM {
                case3TermSent.withValue { $0 = true }
            }
            return 0
        }
    )
    let case3Outcome = try case3Executor.executeWithOutcome(plan, gracePeriodSeconds: 2.0)
    #expect(case3Outcome.state == .executed)
    #expect(case3Signals.current.filter { $0.sig != 0 } == [
        SignalRecord(pid: -5000, sig: SIGTERM)
    ])
}

@Test("daemon fast resamples within 1s after executing an action")
func daemonFastResampleAfterAction() throws {
    let sleepBox = LockedBox<[Double]>([])
    let mockSleeper: @Sendable (Double) -> Void = { duration in
        sleepBox.withValue { $0.append(duration) }
    }

    var config = permissiveEnforcementConfig()
    config.enabled = true
    config.reportOnly = false
    config.intervalSeconds = 5.0

    let actingExecutor = MockActionExecutor(outcome: ActionExecutionOutcome(state: .executed, reason: "action executed"))

    let actingDaemon = EarlyoomDaemon(
        config: config,
        processSampler: FixedProcessSampler(values: [process(pid: 44, footprint: 8 * gib, rss: mib)]),
        memorySampler: FixedMemorySampler(value: MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 128 * mib)),
        actionExecutor: actingExecutor,
        currentUID: 501,
        currentSessionID: nil,
        daemonPID: 7,
        lockURL: FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)"),
        output: { _ in },
        sleeper: mockSleeper
    )

    try actingDaemon.run(repeatCount: 2)
    let actingSleeps = sleepBox.current
    #expect(actingSleeps.count == 1)
    #expect(actingSleeps[0] <= 1.0)

    sleepBox.withValue { $0.removeAll() }
    let idleExecutor = MockActionExecutor(outcome: ActionExecutionOutcome(state: .rejected, reason: "no action"))
    let idleDaemon = EarlyoomDaemon(
        config: config,
        processSampler: FixedProcessSampler(values: [process(pid: 44, footprint: 8 * gib, rss: mib)]),
        memorySampler: FixedMemorySampler(value: MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 128 * mib)),
        actionExecutor: idleExecutor,
        currentUID: 501,
        currentSessionID: nil,
        daemonPID: 7,
        lockURL: FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)"),
        output: { _ in },
        sleeper: mockSleeper
    )

    try idleDaemon.run(repeatCount: 2)
    let idleSleeps = sleepBox.current
    #expect(idleSleeps.count == 1)
    #expect(idleSleeps[0] == 5.0)

    // .attempted does not trigger fast resample
    sleepBox.withValue { $0.removeAll() }
    let attemptedExecutor = MockActionExecutor(outcome: ActionExecutionOutcome(state: .attempted, reason: "target exited before signal"))
    let attemptedDaemon = EarlyoomDaemon(
        config: config,
        processSampler: FixedProcessSampler(values: [process(pid: 44, footprint: 8 * gib, rss: mib)]),
        memorySampler: FixedMemorySampler(value: MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 128 * mib)),
        actionExecutor: attemptedExecutor,
        currentUID: 501,
        currentSessionID: nil,
        daemonPID: 7,
        lockURL: FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)"),
        output: { _ in },
        sleeper: mockSleeper
    )
    try attemptedDaemon.run(repeatCount: 2)
    #expect(sleepBox.current == [5.0])

    // Sub-second intervalSeconds (< 1.0) preserves configured interval after action
    sleepBox.withValue { $0.removeAll() }
    var subSecondConfig = config
    subSecondConfig.intervalSeconds = 0.2
    let subSecondDaemon = EarlyoomDaemon(
        config: subSecondConfig,
        processSampler: FixedProcessSampler(values: [process(pid: 44, footprint: 8 * gib, rss: mib)]),
        memorySampler: FixedMemorySampler(value: MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 128 * mib)),
        actionExecutor: actingExecutor,
        currentUID: 501,
        currentSessionID: nil,
        daemonPID: 7,
        lockURL: FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)"),
        output: { _ in },
        sleeper: mockSleeper
    )
    try subSecondDaemon.run(repeatCount: 2)
    #expect(sleepBox.current == [0.2])
}
