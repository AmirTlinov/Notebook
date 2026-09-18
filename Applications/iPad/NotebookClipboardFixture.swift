#if DEBUG
import UIKit

/// Only used by the foreground isolated drawing fixture, not the production launch.
enum NotebookClipboardFixture {
  static var item: [String: Any]? {
    let environment = ProcessInfo.processInfo.environment
    var values: [String: Any] = [:]
    if let html = environment["NOTEBOOK_CLIPBOARD_HTML"] { values["public.html"] = Data(html.utf8) }
    if let text = environment["NOTEBOOK_CLIPBOARD_TEXT"] { values["public.utf8-plain-text"] = text }
    if !values.isEmpty { return values }
    if let url = environment["NOTEBOOK_CLIPBOARD_URL"] { return ["public.url": url] }
    if environment["NOTEBOOK_CLIPBOARD_IMAGE"] == "1" {
      let image = UIGraphicsImageRenderer(size: .init(width: 160, height: 100)).image { context in
        UIColor.systemTeal.setFill(); context.fill(.init(x: 0, y: 0, width: 160, height: 100))
        UIColor.systemYellow.setFill(); context.cgContext.fillEllipse(in: .init(x: 50, y: 20, width: 60, height: 60))
      }
      return ["public.png": image.pngData()!]
    }
    return nil
  }
}
#endif
