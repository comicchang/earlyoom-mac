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
