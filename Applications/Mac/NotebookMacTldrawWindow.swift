import AppKit
import SwiftUI
import NotebookCore

@MainActor
final class NotebookMacTldrawWindow: NSWindowController {
  init(model:NotebookAppModel) {
    let window = NSWindow(contentRect:.init(x:0,y:0,width:620,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    window.title="Вставить из tldraw"
    window.isReleasedWhenClosed=false
    window.minSize = .init(width:440,height:480)
    super.init(window:window)
    let source = NSPasteboard.general.string(forType:.html) ?? NSPasteboard.general.string(forType:.string)
    window.contentViewController=NSHostingController(rootView:
      NotebookTldrawPasteView(destinations:model.tldrawDestinations,initialSource:source,onClose:{ [weak self] in self?.close() }).environment(model))
    window.center()
  }
  required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
  func present() {
    showWindow(nil)
    NSApplication.shared.activate()
    window?.makeKeyAndOrderFront(nil)
  }
}
