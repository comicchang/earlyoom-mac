import Foundation
import Darwin

public protocol ProcessSampling: Sendable {
    func sample() throws -> [ProcessSnapshot]
}

/// Native Darwin process sampler.  It obtains physical ownership from
/// proc_pid_rusage(2)'s ri_phys_footprint, never from RSS.  RSS is retained in
/// each observation solely to expose dangerous footprint/RSS divergence.
public struct DarwinProcessSampler: ProcessSampling, Sendable {
    private let resolver: any ApplicationIdentityResolving

    public init(resolver: any ApplicationIdentityResolving = BundleIdentityResolver()) {
        self.resolver = resolver
    }

    public func sample() throws -> [ProcessSnapshot] {
        let requestedBytes = proc_listallpids(nil, 0)
        guard requestedBytes > 0 else { throw EarlyoomError.cannotReadProcessList }
        let capacity = Int((requestedBytes + Int32(MemoryLayout<pid_t>.stride) - 1) / Int32(MemoryLayout<pid_t>.stride))
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { rawBuffer -> Int32 in
            proc_listallpids(rawBuffer.baseAddress, Int32(rawBuffer.count))
        }
        guard count > 0 else { throw EarlyoomError.cannotReadProcessList }
        let actualCount = min(Int(count), pids.count)
        return try pids.prefix(actualCount).compactMap { pid in
            guard pid > 0 else { return nil }
            return try snapshot(pid: pid)
        }
    }

    private func snapshot(pid: pid_t) throws -> ProcessSnapshot? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let infoSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize)
        guard infoSize == bsdSize else { return nil }

        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        let taskResult = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize)
        let residentBytes = taskResult == taskSize ? task.pti_resident_size : 0

        var usage = rusage_info_v4()
        let usageResult: Int32 = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, Int32(RUSAGE_INFO_V4), rebound)
            }
        }
        guard usageResult == 0 else { return nil }

        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLength = pathBuffer.withUnsafeMutableBufferPointer { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        let executablePath: String? = pathLength > 0 ? String(decoding: pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        let name = tupleString(bsd.pbi_comm)
        let sessionID = getsid(pid)
        let identity = executablePath.flatMap(resolver.resolve(executablePath:))
        return ProcessSnapshot(
            pid: Int32(bsd.pbi_pid),
            parentPID: Int32(bsd.pbi_ppid),
            processGroupID: Int32(bsd.pbi_pgid),
            sessionID: sessionID,
            userID: bsd.pbi_uid,
            name: name,
            physicalBytes: usage.ri_phys_footprint,
            residentBytes: residentBytes,
            application: identity,
            startTimeSeconds: UInt64(bsd.pbi_start_tvsec)
        )
    }

    private func tupleString<T>(_ tuple: T) -> String {
        withUnsafePointer(to: tuple) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { chars in
                String(cString: chars)
            }
        }
    }
}

public protocol MemorySampling: Sendable {
    func sample() throws -> MemorySnapshot
}

public struct DarwinMemorySampler: MemorySampling, Sendable {
    public init() {}

    public func sample() throws -> MemorySnapshot {
        var physicalMemory: UInt64 = 0
        var physicalSize = MemoryLayout<UInt64>.size
        let physicalResult = sysctlbyname("hw.memsize", &physicalMemory, &physicalSize, nil, 0)
        guard physicalResult == 0, physicalMemory > 0 else {
            throw EarlyoomError.cannotReadMemory(String(cString: strerror(errno)))
        }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            throw EarlyoomError.cannotReadMemory("host_page_size failed")
        }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { values in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, values, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw EarlyoomError.cannotReadMemory("host_statistics64 failed") }

        let page = UInt64(pageSize)
        let free = UInt64(stats.free_count) * page
        let inactive = UInt64(stats.inactive_count) * page
        let purgeable = UInt64(stats.purgeable_count) * page
        let compressor = UInt64(stats.compressor_page_count) * page
        // This deliberately excludes compressor pages: compressed memory still
        // consumes physical memory and is not a free pool.
        let available = min(physicalMemory, free + inactive + purgeable)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        let swapTotal = swapResult == 0 ? UInt64(swap.xsu_total) : 0
        let swapUsed = swapResult == 0 ? UInt64(swap.xsu_used) : 0
        return MemorySnapshot(
            physicalBytes: physicalMemory,
            availableBytes: available,
            freeBytes: free,
            inactiveBytes: inactive,
            purgeableBytes: purgeable,
            compressorBytes: compressor,
            swapUsedBytes: swapUsed,
            swapTotalBytes: swapTotal
        )
    }
}
