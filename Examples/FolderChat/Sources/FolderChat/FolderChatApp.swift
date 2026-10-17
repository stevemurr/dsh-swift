import AppKit
import SwiftUI

@main
struct FolderChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var chat = FolderChatModel()

    var body: some Scene {
        Window("Folder Chat", id: "main") {
            FolderChatView(chat: chat)
                .frame(minWidth: 640, minHeight: 480)
                .onDisappear { chat.close() }
        }
        .defaultSize(width: 800, height: 680)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM executables need to opt into a normal, foreground Mac app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
