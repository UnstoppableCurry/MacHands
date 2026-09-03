import Foundation
import AppKit
import Network

/// Is "System Settings → General → Sharing → Remote Login" on?
///
/// The honest test is the one the server will make: can something connect to
/// port 22 on this Mac. `systemsetup -getremotelogin` needs admin rights and
/// `launchctl print system/…` needs root, so neither is usable from a plain
/// menu-bar app — and a check that silently fails would be worse than none.
enum RemoteLoginCheck {

    /// URL of the Sharing pane. macOS 13+ uses the Settings extension id.
    static let sharingSettingsURL = URL(string:
        "x-apple.systempreferences:com.apple.Sharing-Settings.extension")

    /// Async probe of 127.0.0.1:22.
    ///
    /// `completionQueue` is explicit on purpose: the supervisor's pre-flight
    /// runs off the main thread and must not depend on the main queue being
    /// free, while the setup window does want its answer on the main queue.
    static func check(timeout: TimeInterval = 2.0,
                      completionQueue: DispatchQueue = .main,
                      completion: @escaping (Bool) -> Void) {

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"),
                                           port: NWEndpoint.Port(integerLiteral: 22))
        // Plain TCP, no interface restrictions: loopback reports itself as
        // interface type `.other`, so filtering here would block the very
        // connection we are trying to make.
        let connection = NWConnection(to: endpoint, using: NWParameters.tcp)

        // `settled` makes the completion fire exactly once, whichever of
        // ready / failed / timeout wins the race.
        let lock = NSLock()
        var settled = false
        func settle(_ value: Bool) {
            lock.lock()
            let alreadyDone = settled
            settled = true
            lock.unlock()
            if alreadyDone { return }
            connection.cancel()
            completionQueue.async { completion(value) }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                settle(true)
            case .failed, .cancelled:
                settle(false)
            case .waiting:
                // "Connection refused" arrives as .waiting on loopback; nothing
                // is listening, so do not sit here until the timeout.
                settle(false)
            default:
                break
            }
        }

        connection.start(queue: DispatchQueue.global(qos: .utility))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            settle(false)
        }
    }

    /// Blocking wrapper for background callers (the supervisor's pre-flight).
    /// Must not be called on the main thread.
    static func checkSynchronously(timeout: TimeInterval = 2.0) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        // Answer on a background queue: waiting here must not depend on the
        // main thread being idle.
        check(timeout: timeout,
              completionQueue: DispatchQueue.global(qos: .utility)) { value in
            result = value
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout + 2)
        return result
    }

    /// Open the Sharing pane. Returns false if macOS refused the URL, in which
    /// case the caller should fall back to telling the user the path in words.
    @discardableResult
    static func openSharingSettings() -> Bool {
        guard let url = sharingSettingsURL else { return false }
        return NSWorkspace.shared.open(url)
    }
}
