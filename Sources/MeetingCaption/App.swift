import AppKit
import Combine
import SwiftUI
import CaptionCore

@main
struct MeetingCaptionApp: App {
    @StateObject private var model = MeetingModel()
    @StateObject private var ai = MeetingAI()
    @StateObject private var ui = MeetingViewState()
    @StateObject private var captions = MeetingCaptionPanelController()
    @AppStorage("captionFontSize") private var captionFontSize = 15.0
    @NSApplicationDelegateAdaptor(MeetingAppDelegate.self) private var delegate

    var body: some Scene {
        Window("MeetingCaption", id: "meeting") {
            MeetingRootView(model: model, captions: captions, ai: ai, ui: ui, delegate: delegate)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands { meetingCommands }
        Settings {
            MeetingSettingsView(model: model, ai: ai, ui: ui)
        }
        // Attached here, after the Settings scene's own "Settings…" item exists; replacing the
        // group from the main window's commands left both items in the app menu.
        .commands { CommandGroup(replacing: .appSettings) { OpenSettingsCommand() } }
    }

    @CommandsBuilder
    private var meetingCommands: some Commands {
        CommandGroup(after: .appInfo) { CheckForUpdatesCommand(updater: AppUpdater.shared) }
        CommandGroup(replacing: .newItem) {
            Button("저장하고 새 기록 시작") { model.saveAndStartNewSession() }
                .keyboardShortcut("n")
                .disabled(model.isStarting || model.isStopping || model.isSwitchingSession)
            Button("파일 받아쓰기…") { model.chooseFileToImport() }
                .keyboardShortcut("o")
                .disabled(model.isLocked)
        }
        CommandMenu("회의") {
            Button("크게 보기") { captionFontSize = min(36, captionFontSize + 1) }
                .keyboardShortcut("+", modifiers: [.command])
            Button("작게 보기") { captionFontSize = max(12, captionFontSize - 1) }
                .keyboardShortcut("-", modifiers: [.command])
            Button("기본 크기") { captionFontSize = 15 }
                .keyboardShortcut("0", modifiers: [.command])
            Divider()
            Button(model.isLocked ? "기록 중지" : "기록 시작") {
                if model.isLocked { model.stop() } else { model.start() }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(model.isStopping || model.isStarting || model.isSwitchingSession)
            Divider()
            Button(model.transcript.captions.last?.isBookmarked == true ? "최신 자막 중요 표시 해제" : "최신 자막 중요 표시") {
                model.toggleMarkOnNewest()
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(model.transcript.captions.isEmpty)
            Button(model.showsMarkedOnly ? "전체 자막 보기" : "중요 표시만 보기") { model.showsMarkedOnly.toggle() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("원문+번역 복사") { model.copyBilingual() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.transcript.captions.isEmpty)
            Button("TXT로 내보내기…") { model.exportTXT() }
                .disabled(model.transcript.captions.isEmpty)
            Button("중요 표시만 TXT로 내보내기…") { model.exportMarkedTXT() }
                .disabled(model.markedCount == 0)
            Button("SRT로 내보내기…") { model.exportSRT() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.transcript.captions.isEmpty)
            Divider()
            Button(captions.isVisible ? "떠 있는 자막 창 닫기" : "떠 있는 자막 창") { captions.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("보관 폴더 열기") { NSWorkspace.shared.open(model.library) }
        }
    }
}

private struct MeetingRootView: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var captions: MeetingCaptionPanelController
    @ObservedObject var ai: MeetingAI
    @ObservedObject var ui: MeetingViewState
    let delegate: MeetingAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MeetingView(model: model, captions: captions, ai: ai, ui: ui)
            .onAppear {
                captions.model = model
                delegate.shutdown = {
                    ai.cancel()
                    return await model.shutdown()
                }
                delegate.hasUnfinishedRecording = { model.isLocked }
                delegate.reopenMeeting = { openWindow(id: "meeting") }
            }
            .onChange(of: model.transcript.created) { ai.resetForSession() }
            .onDisappear {
                ai.cancel()
                captions.dismiss()
            }
    }
}

@MainActor
final class MeetingAppDelegate: NSObject, NSApplicationDelegate {
    var shutdown: (@MainActor () async -> Bool)?
    var hasUnfinishedRecording: (@MainActor () -> Bool)?
    var reopenMeeting: (@MainActor () -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Let `MeetingModel.shutdown()` settle before the process exits, so the last
    /// confirmed sentence is flushed instead of being lost to an abrupt exit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if hasUnfinishedRecording?() == true {
            let alert = NSAlert()
            alert.messageText = "회의 기록을 마치고 종료할까요?"
            alert.informativeText = "확정된 문장은 보관 폴더에 저장됩니다. 아직 인식 중인 문장은 저장되지 않을 수 있습니다."
            alert.addButton(withTitle: "기록 마치고 종료")
            alert.addButton(withTitle: "계속 사용")
            guard alert.runModal() == .alertFirstButtonReturn else {
                reopenMeeting?()
                return .terminateCancel
            }
        }
        guard let shutdown else { return .terminateNow }
        Task { @MainActor in
            let saved = await shutdown()
            NSApp.reply(toApplicationShouldTerminate: saved)
            if !saved { reopenMeeting?() }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Hosts the optional caption window. It is a normal floating window: visible to
/// screen sharing, hidden from nobody, and closed when the meeting window closes.
@MainActor
final class MeetingCaptionPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false
    var model: MeetingModel?

    private var window: NSWindow?

    init(window: NSWindow? = nil) {
        self.window = window
        super.init()
        window?.delegate = self
    }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    func show() {
        guard let model else { return }
        let window = window ?? makeWindow(model: model)
        self.window = window
        window.deminiaturize(nil)
        window.orderFrontRegardless()
        isVisible = true
    }

    func close() {
        guard let window else { return }
        window.orderOut(nil)
        isVisible = false
    }

    /// Called when the meeting window goes away so no orphan caption window outlives it.
    func dismiss() {
        close()
        window?.delegate = nil
        window = nil
    }

    private func makeWindow(model: MeetingModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 168),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "회의 자막"
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 120)
        window.delegate = self
        let host = NSHostingView(rootView: MeetingFloatingCaption(model: model))
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.setContentSize(NSSize(width: 560, height: 168))
        // Restore the last position the user chose; otherwise park it low and centered
        // where it does not cover the meeting window's own content.
        let autosave = "MeetingCaptionFloating"
        let restored = window.setFrameUsingName(autosave)
        window.setFrameAutosaveName(autosave)
        if !restored {
            let screen = NSScreen.main?.visibleFrame
            if let screen {
                window.setFrameOrigin(NSPoint(x: screen.midX - window.frame.width / 2,
                                              y: screen.minY + 80))
            } else {
                window.center()
            }
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }

    func windowDidMiniaturize(_ notification: Notification) { isVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { isVisible = true }
}
