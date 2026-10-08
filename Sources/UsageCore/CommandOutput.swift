import Foundation
import Darwin

/// Run only on a worker task. Even a child that closes stdout and hangs has a deadline.
enum CommandOutput {
    struct Result { let data: Data; let exitCode: Int32 }
    static func read(_ process: Process, output: Pipe, timeout: TimeInterval, limit: Int) throws -> Result {
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var ended = false
        while !ended || process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw UsageError.timeout }
            if ended { Thread.sleep(forTimeInterval: 0.02); continue }
            var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; throw UsageError.server }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd.fd, &bytes, bytes.count)
            if count < 0 { if errno == EINTR { continue }; throw UsageError.server }
            if count == 0 { ended = true; continue }
            guard data.count + count <= limit else { throw UsageError.invalidData }
            data.append(contentsOf: bytes.prefix(count))
        }
        return Result(data: data, exitCode: process.terminationStatus)
    }
}
