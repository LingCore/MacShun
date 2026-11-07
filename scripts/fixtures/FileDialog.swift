// SPDX-License-Identifier: MIT
// 外部宿主进程，验证的是系统面板实际所在的位置及原始文件名。
import AppKit

let application = NSApplication.shared
let mode = CommandLine.arguments[1]
let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let origin = root.appendingPathComponent("起点", isDirectory: true)
let destination = root.appendingPathComponent("项目 资料", isDirectory: true)
let window = NSWindow(contentRect: NSRect(x: 160, y: 150, width: 460, height: 260),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
let panel: NSSavePanel = mode.hasPrefix("open") ? NSOpenPanel() : NSSavePanel()
let name = "新报价 2026.txt"
panel.directoryURL = origin
if !(panel is NSOpenPanel) { panel.nameFieldStringValue = name }

application.setActivationPolicy(.regular)
window.title = "MacShun file dialog test"
window.makeKeyAndOrderFront(nil)
application.activate()
DispatchQueue.main.async {
    let completed: (NSApplication.ModalResponse) -> Void = { response in
        if response != .cancel { print("Unexpected submission"); fflush(stdout) }
        application.terminate(nil)
    }
    if mode.hasSuffix("sheet") { panel.beginSheetModal(for: window, completionHandler: completed) }
    else { panel.begin(completionHandler: completed) }
}
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path) {
        panel.cancel(nil)
        return
    }
    let arrived = panel.directoryURL?.resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path
    if panel.isVisible && arrived && (panel is NSOpenPanel || panel.nameFieldStringValue == name) {
        FileManager.default.createFile(atPath: root.appendingPathComponent("arrived").path, contents: nil)
    }
}
application.run()
