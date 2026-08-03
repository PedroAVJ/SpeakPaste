import Darwin
import Foundation

/// A process-lifetime, kernel-released lease for SpeakPaste's shared local data.
///
/// The open file descriptor is the lease. `flock` releases it even if the app
/// crashes or is force-quit, unlike a marker file that can become stale. The
/// zero-byte file intentionally remains in the user's stable temporary folder:
/// unlinking a locked file can create two independently locked inodes during a
/// handoff between processes.
final class MacSingleInstanceLease {
    enum Acquisition {
        case acquired(MacSingleInstanceLease)
        case alreadyHeld
        case unavailable
    }

    private let fileDescriptor: Int32

    /// All signed, ad-hoc, development, and renamed builds read the same
    /// `Application Support/SpeakPaste` stores. The lease therefore must not
    /// follow the bundle identifier: two bundle identities still represent one
    /// data owner and must exclude each other.
    private static let productLockIdentifier = "com.speakpaste.shared-user-data"

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        close(fileDescriptor)
    }

    /// Attempts to acquire the lease without waiting.
    ///
    /// `lockDirectory` exists for focused tests. Production callers omit it so
    /// the path comes from Darwin rather than `TMPDIR`; an environment override
    /// must not let a second copy evade the per-user lease.
    static func acquire(lockDirectory: URL? = nil) -> Acquisition {
        acquire(
            lockIdentifier: productLockIdentifier,
            lockDirectory: lockDirectory
        )
    }

    /// A separately compiled UI-test app needs its own lease while its entire
    /// home directory is redirected. This is internal and is never selected by
    /// a production runtime; the `SPEAKPASTE_UI_TEST_INSTANCE` compile flag is
    /// required at the call site.
    static func acquireForIsolatedTesting(
        lockIdentifier: String,
        lockDirectory: URL? = nil
    ) -> Acquisition {
        acquire(lockIdentifier: lockIdentifier, lockDirectory: lockDirectory)
    }

    private static func acquire(
        lockIdentifier: String,
        lockDirectory: URL?
    ) -> Acquisition {
        guard isValidLockIdentifier(lockIdentifier),
              let directory = lockDirectory ?? stableUserTemporaryDirectory()
        else {
            return .unavailable
        }

        let fileName = ".\(lockIdentifier).single-instance.lock"
        let lockURL = directory.appendingPathComponent(fileName, isDirectory: false)
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return .unavailable }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFREG
        else {
            close(descriptor)
            return .unavailable
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return .alreadyHeld
            }
            return .unavailable
        }

        return .acquired(MacSingleInstanceLease(fileDescriptor: descriptor))
    }

    private static func isValidLockIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 200 else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                true
            default:
                false
            }
        }
    }

    private static func stableUserTemporaryDirectory() -> URL? {
        let requiredSize = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard requiredSize > 1 else { return nil }

        var buffer = [CChar](repeating: 0, count: requiredSize)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, requiredSize) > 0 else {
            return nil
        }
        return URL(fileURLWithFileSystemRepresentation: buffer, isDirectory: true, relativeTo: nil)
    }
}
