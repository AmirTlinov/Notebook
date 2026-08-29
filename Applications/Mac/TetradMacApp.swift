import SwiftUI

@main
struct TetradMacApp: App {
  @State private var model = TetradAppModel()

  var body: some Scene {
    WindowGroup {
      MacRootView()
        .environment(model)
        .frame(minWidth: 480, minHeight: 640)
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 700, height: 900)
    .commands {
      CommandMenu("Тетрадь") {
        Button("Предыдущая страница") { model.turnPage(-1) }
          .keyboardShortcut(.leftArrow, modifiers: [])
        Button("Следующая страница") { model.turnPage(1) }
          .keyboardShortcut(.rightArrow, modifiers: [])
        Divider()
        Button("Предыдущая тетрадь") { model.changeNotebook(-1) }
          .keyboardShortcut(.upArrow, modifiers: [.command])
        Button("Следующая тетрадь") { model.changeNotebook(1) }
          .keyboardShortcut(.downArrow, modifiers: [.command])
      }
    }
  }
}
