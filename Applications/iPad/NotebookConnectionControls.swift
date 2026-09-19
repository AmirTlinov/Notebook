import NotebookCore
import UIKit

/// Small, literal previews: the capsule shows the connection, not navigation arrows.
enum NotebookConnectionGlyph {
  static func image(routing: NotebookGraphicConnection.Routing = .straight,
    start: NotebookGraphicConnection.Arrowhead = .none, end: NotebookGraphicConnection.Arrowhead = .none,
    dash: NotebookGraphic.Style.Dash = .solid, size: CGSize = .init(width:28,height:18)) -> UIImage {
    let connection = NotebookGraphicConnection(start:.init(point:.init(x:5,y:routing == .elbow ? 20 : 12)),
      end:.init(point:.init(x:55,y:routing == .elbow ? 4 : 12)),bend:routing == .curved ? -9 : 0,
      startArrowhead:start,endArrowhead:end,routing:routing)
    let graphic = NotebookGraphic(shape:.connector,style:.init(strokeWidth:1.8,dash:dash),connection:connection)
    let layout = NotebookGraphicGraph([.init(id:"glyph",graphic:graphic,frame:.init(x:0,y:0,width:60,height:24),
      surface:.page(UUID()),shown:true)]).resolve("glyph").layout!
    return UIGraphicsImageRenderer(size:size).image { renderer in
      let context = renderer.cgContext
      let scale = min((size.width-2)/layout.frame.width,(size.height-2)/layout.frame.height)
      context.translateBy(x:(size.width-layout.frame.width*scale)/2,y:(size.height-layout.frame.height*scale)/2)
      context.scaleBy(x:scale,y:scale)
      context.addPath(NotebookGraphicGeometry.paintPath(graphic,layout:layout,
        size:.init(width:layout.frame.width,height:layout.frame.height)))
      context.setFillColor(UIColor.label.cgColor); context.fillPath()
    }.withRenderingMode(.alwaysTemplate)
  }
}

final class NotebookConnectionController: UIViewController, UIPopoverPresentationControllerDelegate {
  enum Mode { case routing, ends }
  let mode: Mode
  private var connection: NotebookGraphicConnection
  private var routes: [UIButton] = []
  private let startButton = ElementMenuButton(type:.system)
  private let endButton = ElementMenuButton(type:.system)
  var setRouting: ((NotebookGraphicConnection.Routing) -> Void)?
  var setHead: ((NotebookGraphicConnection.Arrowhead,NotebookGraphicConnection.Terminal) -> Void)?
  var onDismiss: (() -> Void)?
  init(mode: Mode, connection: NotebookGraphicConnection) {
    self.mode = mode; self.connection = connection
    super.init(nibName:nil,bundle:nil)
    modalPresentationStyle = .popover
    preferredContentSize = .init(width:280,height:100)
    popoverPresentationController?.delegate = self
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func loadView() {
    view = UIView(); view.backgroundColor = UIColor(NotebookChrome.surface)
    view.layer.cornerRadius = NotebookChrome.panelRadius; view.layer.cornerCurve = .continuous
    view.layer.borderColor = UIColor(NotebookChrome.border).cgColor; view.layer.borderWidth = 0.5
    view.clipsToBounds = true
    popoverPresentationController?.backgroundColor = UIColor(NotebookChrome.surface)
    let title = UILabel(); title.text = mode == .routing ? "Стиль соединения" : "Концы линии"
    title.font = .systemFont(ofSize:13,weight:.medium); title.textColor = .secondaryLabel
    let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:14),
      stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-14),
      stack.topAnchor.constraint(equalTo:view.topAnchor,constant:12)])
    stack.addArrangedSubview(title)
    if mode == .routing {
      let row = UIStackView(); row.spacing = 2; row.distribution = .fillEqually
      row.backgroundColor = UIColor(NotebookChrome.insetSurface); row.layer.cornerRadius = 10
      for (i,route) in NotebookGraphicConnection.Routing.allCases.enumerated() {
        let button = UIButton(type:.system); button.tag = i
        var config = UIButton.Configuration.plain()
        config.image = NotebookConnectionGlyph.image(routing:route,size:.init(width:48,height:22))
        config.baseForegroundColor = .label; config.background.cornerRadius = 8
        config.background.backgroundInsets = .init(top:3,leading:3,bottom:3,trailing:3)
        button.configuration = config; button.accessibilityLabel = route.controlTitle
        button.accessibilityIdentifier = "connection-route-" + route.rawValue
        button.addTarget(self,action:#selector(routeChanged(_:)),for:.touchUpInside)
        button.heightAnchor.constraint(equalToConstant:44).isActive = true
        routes.append(button); row.addArrangedSubview(button)
      }
      stack.addArrangedSubview(row)
    } else {
      let row = UIStackView(); row.spacing = 8; row.distribution = .fillEqually
      for (button,title,id) in [(startButton,"Начало линии","graphic-start-menu"),(endButton,"Конец линии","graphic-end-menu")] {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = .label; config.background.backgroundColor = UIColor(NotebookChrome.insetSurface)
        config.background.cornerRadius = 10; config.contentInsets = .init(top:6,leading:12,bottom:6,trailing:12)
        button.configuration = config; button.accessibilityLabel = title; button.accessibilityIdentifier = id
        button.heightAnchor.constraint(equalToConstant:44).isActive = true; row.addArrangedSubview(button)
      }
      stack.addArrangedSubview(row)
    }
    refresh()
  }
  func configure(_ connection: NotebookGraphicConnection) { self.connection = connection; if isViewLoaded { refresh() } }
  private func refresh() {
    for (i,button) in routes.enumerated() {
      let selected = NotebookGraphicConnection.Routing.allCases[i] == connection.resolvedRouting
      var config = button.configuration!
      config.background.backgroundColor = selected ? .systemBlue : .clear
      config.baseForegroundColor = selected ? .white : .label; button.configuration = config
      button.accessibilityTraits = selected ? [.button,.selected] : .button
    }
    for (terminal,button) in [(NotebookGraphicConnection.Terminal.start,startButton),(.end,endButton)] {
      let current = terminal == .start ? connection.startArrowhead : connection.endArrowhead
      var config = button.configuration ?? .plain()
      config.image = NotebookConnectionGlyph.image(start:terminal == .start ? current : .none,
        end:terminal == .end ? current : .none,size:.init(width:68,height:22))
      button.configuration = config; button.accessibilityValue = current.controlTitle
      button.contents = NotebookGraphicConnection.Arrowhead.allCases.map { head in
        UIAction(title:head.controlTitle,image:NotebookConnectionGlyph.image(start:terminal == .start ? head : .none,
          end:terminal == .end ? head : .none,size:.init(width:48,height:20)),state:head == current ? .on : .off) { [weak self] _ in
          self?.setHead?(head,terminal)
        }
      }
    }
  }
  @objc private func routeChanged(_ button: UIButton) { setRouting?(NotebookGraphicConnection.Routing.allCases[button.tag]) }
  func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
  func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) { onDismiss?() }
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onDismiss?() }
  override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); onDismiss?() }
}

extension NotebookGraphicConnection.Routing {
  var controlTitle: String { switch self { case .straight: "Прямая"; case .elbow: "Угловая"; case .curved: "Кривая" } }
}

extension NotebookGraphic.Style.Dash {
  var controlTitle: String {
    switch self { case .solid: "Сплошная"; case .dashed: "Пунктир"; case .dotted: "Точки"; case .dashDot: "Штрихпунктир" }
  }
}
