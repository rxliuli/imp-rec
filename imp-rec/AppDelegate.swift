import AppKit
import ScreenCaptureKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = ScreenRecorder()
    private var editorWindow: NSWindow?
    private var editorWindowDelegate: WindowCloseDelegate?
    private var editorState: EditorState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupContentPicker()

        presentPicker()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if recorder.isRecording {
            Task { _ = await recorder.stopRecording() }
        }
        SCContentSharingPicker.shared.remove(self)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let icon = NSImage(
                systemSymbolName: "record.circle", accessibilityDescription: "imp-rec")
            icon?.isTemplate = true
            button.image = icon
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupContentPicker() {
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleDisplay]
        picker.defaultConfiguration = config
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            toggleRecording()
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            Task { @MainActor in
                updateIcon(recording: false)
                let url = await recorder.stopRecording()
                SCContentSharingPicker.shared.isActive = false
                if let url {
                    showEditor(with: url)
                }
            }
        } else {
            presentPicker()
        }
    }

    private func presentPicker() {
        let picker = SCContentSharingPicker.shared
        picker.isActive = true
        picker.present()
    }

    private func updateIcon(recording: Bool) {
        let symbolName = recording ? "stop.circle.fill" : "record.circle"
        let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: "imp-rec")
        icon?.isTemplate = !recording
        statusItem.button?.image = icon
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: "Quit imp-rec", action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func showEditor(with videoURL: URL) {
        let state = EditorState(videoURL: videoURL)
        editorState = state

        let closeDelegate = WindowCloseDelegate { [weak self] in
            self?.closeEditor()
        }
        editorWindowDelegate = closeDelegate

        let editorView = EditorView(state: state) { [weak self] in
            self?.closeEditor()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "imp-rec"
        window.contentView = NSHostingView(rootView: editorView)
        window.delegate = closeDelegate
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        editorWindow = window
    }

    private func closeEditor() {
        editorState?.cleanup()
        editorWindow?.orderOut(nil)
        let window = editorWindow
        editorWindow = nil
        editorWindowDelegate = nil
        editorState = nil
        DispatchQueue.main.async {
            window?.contentView = nil
        }
    }
}

extension AppDelegate: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in
            SCContentSharingPicker.shared.isActive = false
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        print("Content sharing picker failed: \(error)")
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor in
            await recorder.startRecording(with: filter)
            if recorder.isRecording {
                updateIcon(recording: true)
            }
        }
    }
}

class WindowCloseDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose()
        return false
    }
}
