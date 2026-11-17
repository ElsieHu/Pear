import Foundation

/// In-process AppleScript runner.
///
/// Fixed scripts are compiled once and their `NSAppleScript` instances are
/// reused for the lifetime of the app. The only script that needs an argument
/// (seeking) is compiled once as a handler and receives its value through an
/// AppleEvent parameter, so its text never changes. Every execution is
/// serialised behind a lock because `NSAppleScript` is not thread-safe.
///
/// No command-line interpreter, no child process, no external tool: scripts
/// are compiled and executed inside Pear's own process.
final class MusicScriptEngine: @unchecked Sendable {

    private let lock = NSLock()
    private var compiled: [String: NSAppleScript] = [:]
    private let seekScript: NSAppleScript?
    private var lastDiagnostic = ""

    /// The handler name is an AppleEvent parameter, not embedded text.
    private static let seekHandlerSource = """
    on seekTo(value)
        tell application "Music" to set player position to (value as real)
    end seekTo
    """

    init() {
        let script = NSAppleScript(source: Self.seekHandlerSource)
        var error: NSDictionary?
        if let script { _ = script.compileAndReturnError(&error) }
        seekScript = error == nil ? script : nil
    }

    /// Execute a fixed script, compiling it on first use and reusing it after.
    func execute(_ source: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else {
                reportLocked("脚本创建失败")
                return nil
            }
            var error: NSDictionary?
            guard fresh.compileAndReturnError(&error) else {
                reportLocked("脚本预编译失败: \(Self.message(error))")
                return nil
            }
            compiled[source] = fresh
            script = fresh
        }
        return performLocked(script)
    }

    /// Seek by invoking the precompiled handler with a numeric argument.
    /// No script text is rebuilt, so the compiled instance is reused for
    /// every seek.
    func seek(to seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        guard let seekScript else {
            reportLocked("拖动脚本未编译")
            return
        }
        // 'ascr' / 'psbr' = AppleScript suite, subroutine event.
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(0x61736372),
            eventID: AEEventID(0x70736272),
            targetDescriptor: NSAppleEventDescriptor.null(),
            returnID: AEReturnID(-1),
            transactionID: AETransactionID(0))
        event.setParam(NSAppleEventDescriptor(string: "seekTo"),
                       forKeyword: AEKeyword(0x736e616d))   // 'snam'
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(
            NSAppleEventDescriptor(string: String(format: "%.3f", max(0, seconds))),
            at: 1)
        event.setParam(arguments, forKeyword: AEKeyword(0x2d2d2d2d))  // '----'

        var error: NSDictionary?
        _ = seekScript.executeAppleEvent(event, error: &error)
        if let error {
            reportLocked("AppleScript 执行失败: \(Self.message(error))")
        }
    }

    /// Diagnostics arriving from outside `execute` (e.g. a failed probe).
    func report(_ message: String) {
        lock.lock()
        reportLocked(message)
        lock.unlock()
    }

    // MARK: - Locked internals

    private func performLocked(_ script: NSAppleScript) -> String? {
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            reportLocked("AppleScript 执行失败: \(Self.message(error))")
            return nil
        }
        return result.stringValue
    }

    /// Collapse repeated identical failures into a single log line.
    private func reportLocked(_ message: String) {
        guard message != lastDiagnostic else { return }
        lastDiagnostic = message
        MusicScript.diagnosticHandler?(message)
    }

    private static func message(_ error: NSDictionary?) -> String {
        guard let error else { return "未知错误" }
        if let text = error["NSAppleScriptErrorMessage"] as? String, !text.isEmpty {
            return text
        }
        if let brief = error["NSAppleScriptErrorBriefMessage"] as? String, !brief.isEmpty {
            return brief
        }
        if let number = error["NSAppleScriptErrorNumber"] as? NSNumber {
            return "错误码 \(number)"
        }
        return "\(error)"
    }
}
