import AppKit
import SwiftUI

@main
struct TravelMediaManagerApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("旅行素材管家", id: "main") {
            ArchiveView(model: model)
                .frame(minWidth: 860, minHeight: 650)
                .background(WindowCloseGuard(model: model))
                .onAppear {
                    appDelegate.model = model
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 980, height: 740)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy else { return .terminateNow }
        model.confirmCloseWhileBusy()
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { model?.phone.stop() }
}

@MainActor
private struct WindowCloseGuard: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            coordinator.originalDelegate = window.delegate
            window.delegate = coordinator
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { }

    final class Coordinator: NSObject, NSWindowDelegate {
        let model: AppModel
        weak var originalDelegate: NSWindowDelegate?
        init(model: AppModel) { self.model = model }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !model.isBusy else {
                model.confirmCloseWhileBusy()
                return false
            }
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalDelegate?.responds(to: selector) == true { return originalDelegate }
            return super.forwardingTarget(for: selector)
        }
    }
}
