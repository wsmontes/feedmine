import Foundation
import os

#if canImport(Darwin)
import Darwin
#endif

/// Removable performance instrumentation for the legacy backend and the
/// FeedEngine migration.
enum FeedMetrics {
    #if DEBUG || INSTRUMENTATION
    private static let signposter = OSSignposter(
        subsystem: "com.feedmine.app",
        category: "FeedEngine"
    )

    static func beginInterval(_ name: StaticString) -> () -> Void {
        let state = signposter.beginInterval(name)
        return { signposter.endInterval(name, state) }
    }

    static func event(_ name: StaticString) {
        signposter.emitEvent(name, id: signposter.makeSignpostID())
    }

    static func event(_ name: StaticString, _ message: String) {
        signposter.emitEvent(name, id: signposter.makeSignpostID(), "\(message)")
    }

    static func memory(_ milestone: StaticString) {
        guard let megabytes = physicalFootprintMegabytes() else { return }
        signposter.emitEvent(
            "Memory.physFootprint",
            id: signposter.makeSignpostID(),
            "milestone=\(String(describing: milestone)) mb=\(megabytes)"
        )
    }
    #else
    static func beginInterval(_ name: StaticString) -> () -> Void { {} }
    static func event(_ name: StaticString) {}
    static func event(_ name: StaticString, _ message: String) {}
    static func memory(_ milestone: StaticString) {}
    #endif

    static func physicalFootprintMegabytes() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint) / (1024 * 1024)
        #else
        return nil
        #endif
    }
}
