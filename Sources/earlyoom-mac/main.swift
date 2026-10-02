import Foundation
import EarlyoomMac

private func usage() {
    print("""
    Usage: earlyoom-mac [--config PATH] [--once] [--print-default-config]

    The daemon is report-only unless the config explicitly sets both
    earlyoom.enabled = true and earlyoom.report_only = false.
    """)
}

var configURL: URL?
var once = false
var index = 1
while index < CommandLine.arguments.count {
    switch CommandLine.arguments[index] {
    case "--config":
        index += 1
        guard index < CommandLine.arguments.count else {
            fputs("--config requires a path\n", stderr)
            exit(2)
        }
        configURL = URL(fileURLWithPath: CommandLine.arguments[index])
    case "--once":
        once = true
    case "--print-default-config":
        print(EarlyoomConfig.defaultConfigurationText)
        exit(0)
    case "--help", "-h":
        usage()
        exit(0)
    default:
        fputs("unknown argument: \(CommandLine.arguments[index])\n", stderr)
        usage()
        exit(2)
    }
    index += 1
}

do {
    let config: EarlyoomConfig
    if let configURL {
        config = try EarlyoomConfig.load(from: configURL)
    } else {
        config = .safeReportOnly
        fputs("earlyoom-mac: no config supplied; using safe report-only defaults\n", stderr)
    }
    let executor: any ProcessActionExecutor = config.enabled && !config.reportOnly
        ? DarwinActionExecutor()
        : DryRunActionExecutor()
    let daemon = EarlyoomDaemon(config: config, actionExecutor: executor)
    try daemon.run(repeatCount: once ? 1 : nil)
} catch {
    fputs("earlyoom-mac: \(error)\n", stderr)
    exit(1)
}
