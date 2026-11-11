import Foundation
import Darwin

final class InstanceLock {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    static func acquire() -> InstanceLock? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let directory = applicationSupport.appendingPathComponent(
            "Overbright",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        let lockPath = directory.appendingPathComponent("instance.lock").path
        let descriptor = Darwin.open(
            lockPath,
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return nil }
        guard setLock(on: descriptor, type: Int16(F_WRLCK)) else {
            Darwin.close(descriptor)
            return nil
        }
        return InstanceLock(fileDescriptor: descriptor)
    }

    deinit {
        _ = Self.setLock(on: fileDescriptor, type: Int16(F_UNLCK))
        Darwin.close(fileDescriptor)
    }

    private static func setLock(on descriptor: Int32, type: Int16) -> Bool {
        var lock = Darwin.flock()
        lock.l_type = type
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        return Darwin.fcntl(descriptor, F_SETLK, &lock) != -1
    }
}
