import NotebookCore
import UIKit

/// Character and object selection expose the same commands; the caller alone
/// chooses the text range. Presentation still belongs to NotebookContextMenus.
@MainActor enum NotebookTextFormattingMenu {
  static func make(_ format: NativeTextFormat,
    apply: @escaping (@escaping (inout NativeTextFormat) -> Void) -> Void,
    link: @escaping () -> Void) -> UIMenu {
    func action(_ title: String, _ symbol: String, selected: Bool = false,
      change: @escaping (inout NativeTextFormat) -> Void) -> UIAction {
      UIAction(title:title,image:UIImage(systemName:symbol),state:selected ? .on : .off) { _ in apply(change) }
    }
    return UIMenu(children:[
      UIMenu(title:"Шрифт",image:UIImage(systemName:"textformat"),children:NotebookTextTypography.fonts.map { font in
        action(font.title,"textformat",selected:format.fontName == font.name) { $0.fontName = font.name }
      }),
      action("Жирный","bold",selected:format.bold == true) { $0.bold = format.bold != true },
      action("Курсив","italic",selected:format.italic == true) { $0.italic = format.italic != true },
      action("Выделить маркером","highlighter",selected:format.highlight != nil) {
        $0.highlight = format.highlight == nil ? .init(red:1,green:0.9,blue:0.35) : nil
      },
      UIAction(title:"Веб-ссылка",image:UIImage(systemName:"link"),state:format.link != nil ? .on : .off) { _ in link() }
    ])
  }

  static func editLink(_ original: String?, from view: UIView, apply: @escaping (String?) -> Void,
    completion: @escaping () -> Void = {}) {
    guard var controller = view.window?.rootViewController else { return }
    while let presented = controller.presentedViewController { controller = presented }
    let dialog = UIAlertController(title:"Веб-ссылка",message:nil,preferredStyle:.alert)
    let save = UIAlertAction(title:"Применить",style:.default) { [weak dialog] _ in
      if let link = dialog?.textFields?.first?.text, NativeTextFormat.isWebLink(link) { apply(link) }
      completion()
    }
    save.isEnabled = original != nil
    dialog.addTextField { [weak save] field in
      field.text = original; field.placeholder = "https://…"; field.keyboardType = .URL
      field.autocapitalizationType = .none; field.autocorrectionType = .no
      field.accessibilityIdentifier = "native-text-link-url"
      field.addAction(UIAction { [weak field, weak save] _ in save?.isEnabled = NativeTextFormat.isWebLink(field?.text ?? "") },for:.editingChanged)
    }
    dialog.addAction(save)
    if original != nil { dialog.addAction(.init(title:"Убрать ссылку",style:.destructive) { _ in apply(nil); completion() }) }
    dialog.addAction(.init(title:"Отмена",style:.cancel) { _ in completion() })
    controller.present(dialog,animated:true)
  }
}
