import AppKit

private nonisolated(unsafe) var _appDelegate: AppDelegate!

@main
struct ImpRecApp {
    static func main() {
        MainActor.assumeIsolated {
            _appDelegate = AppDelegate()
            NSApplication.shared.delegate = _appDelegate
        }
        NSApplication.shared.run()
    }
}
