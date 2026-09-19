import NotebookCore
import UIKit

/// Native anchored palette. The model owns edits; this controller owns only
/// which part of the style the person is choosing and the system colour picker.
final class NotebookElementStyleController: UIViewController, UIPopoverPresentationControllerDelegate, UIColorPickerViewControllerDelegate {
  var updateStyle: ((inout NotebookGraphic.Style) -> Void) -> Void = { _ in }
  var onDismiss: (() -> Void)?
  private var style: NotebookGraphic.Style
  private let permitsFill: Bool
  private let channel = UISegmentedControl(items: ["Линия", "Заливка"])
  private var swatches: [UIButton] = []
  private let weight = UISlider()
  private let weightLabel = UILabel()
  private var patterns: [UIButton] = []
  private let clearFill = UIButton(type: .system)
  private static let colors: [(String, SpatialInkColor)] = [
    ("Чёрный", .black), ("Серый", .init(red:0.45,green:0.46,blue:0.48)), ("Белый", .init(red:1,green:1,blue:1)),
    ("Бирюзовый", .init(red:0.18,green:0.66,blue:0.61)), ("Розовый", .init(red:0.76,green:0.22,blue:0.49)),
    ("Фиолетовый", .init(red:0.52,green:0.27,blue:0.88)), ("Красный", .init(red:0.84,green:0.25,blue:0.21)),
    ("Оранжевый", .init(red:0.94,green:0.61,blue:0.14)), ("Жёлтый", .init(red:0.76,green:0.64,blue:0.12)),
    ("Зелёный", .init(red:0.3,green:0.66,blue:0.35)), ("Голубой", .init(red:0.23,green:0.62,blue:0.77)),
    ("Синий", .init(red:0.22,green:0.40,blue:0.89))
  ]
  init(graphic: NotebookGraphic) {
    style = graphic.style; permitsFill = graphic.shape != .connector && graphic.shape != .plus
    super.init(nibName:nil,bundle:nil)
    modalPresentationStyle = .popover
    preferredContentSize = .init(width: 304, height: permitsFill ? 326 : 286)
    popoverPresentationController?.delegate = self
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func loadView() {
    view = UIView(); view.backgroundColor = UIColor(NotebookChrome.surface)
    popoverPresentationController?.backgroundColor = UIColor(NotebookChrome.surface)
    let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:14),
      stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-14),
      stack.topAnchor.constraint(equalTo:view.topAnchor,constant:14)])
    if permitsFill {
      channel.selectedSegmentIndex = 0; channel.addTarget(self,action:#selector(channelChanged),for:.valueChanged)
      channel.accessibilityIdentifier = "element-style-channel"; stack.addArrangedSubview(channel)
    }
    for row in 0..<2 {
      let line = UIStackView(); line.distribution = .fillEqually; line.spacing = 2
      for index in row*6..<row*6+6 {
        let (name, color) = Self.colors[index], button = UIButton(type:.system)
        button.tag = index; button.accessibilityLabel = name; button.accessibilityIdentifier = "element-color-\(index)"
        button.addTarget(self,action:#selector(chooseColor(_:)),for:.touchUpInside)
        button.tintColor = Self.color(color); button.heightAnchor.constraint(equalToConstant:42).isActive = true
        swatches.append(button); line.addArrangedSubview(button)
      }
      stack.addArrangedSubview(line)
    }
    let extras = UIStackView(); extras.spacing = 8; extras.distribution = .fillEqually
    clearFill.setTitle("Без заливки",for:.normal); clearFill.titleLabel?.font = .systemFont(ofSize:14)
    clearFill.accessibilityIdentifier = "element-clear-fill"; clearFill.addTarget(self,action:#selector(removeFill),for:.touchUpInside)
    clearFill.heightAnchor.constraint(equalToConstant:36).isActive = true; extras.addArrangedSubview(clearFill)
    let custom = UIButton(type:.system); custom.setTitle("Другие цвета",for:.normal); custom.titleLabel?.font = .systemFont(ofSize:14)
    custom.accessibilityIdentifier = "element-custom-color"; custom.addTarget(self,action:#selector(customColor),for:.touchUpInside)
    extras.addArrangedSubview(custom); stack.addArrangedSubview(extras)
    let separator = UIView(); separator.backgroundColor = .separator; separator.heightAnchor.constraint(equalToConstant:0.5).isActive = true
    stack.addArrangedSubview(separator)
    weight.minimumValue = -2; weight.maximumValue = 10; weight.isContinuous = false
    weight.accessibilityLabel = "Толщина обводки"; weight.accessibilityIdentifier = "element-width"
    weight.addTarget(self,action:#selector(chooseWidth(_:)),for:.valueChanged)
    let widths = UIStackView(arrangedSubviews:[weight,weightLabel]); widths.spacing = 10
    widths.heightAnchor.constraint(equalToConstant:42).isActive = true
    weightLabel.font = .monospacedDigitSystemFont(ofSize:13,weight:.regular)
    stack.addArrangedSubview(widths)
    let dashes = UIStackView(); dashes.distribution = .fillEqually; dashes.spacing = 6
    for (index, title) in ["Сплошная","Пунктир","Точки"].enumerated() {
      let button = UIButton(type:.system); button.tag = index; button.setImage(Self.line(width:2,dash:index),for:.normal)
      button.accessibilityLabel = title; button.accessibilityIdentifier = "element-dash-\(index)"
      button.addTarget(self,action:#selector(chooseDash(_:)),for:.touchUpInside)
      button.heightAnchor.constraint(equalToConstant:42).isActive = true
      patterns.append(button); dashes.addArrangedSubview(button)
    }
    stack.addArrangedSubview(dashes); refresh()
  }
  func configure(style: NotebookGraphic.Style) { self.style = style; if isViewLoaded { refresh() } }
  private func refresh() {
    let selected = channel.selectedSegmentIndex == 1 ? style.fill : style.stroke
    for (index, button) in swatches.enumerated() {
      let color = Self.colors[index].1, active = selected == color
      let renderer = UIGraphicsImageRenderer(size:.init(width:36,height:36))
      button.setImage(renderer.image { context in
        Self.color(color).setFill(); UIBezierPath(ovalIn:.init(x:4,y:4,width:28,height:28)).fill()
        UIColor.label.withAlphaComponent(0.18).setStroke()
        let rim = UIBezierPath(ovalIn:.init(x:4,y:4,width:28,height:28)); rim.lineWidth = 0.5; rim.stroke()
        if active { UIColor.label.setStroke(); let ring = UIBezierPath(ovalIn:.init(x:0.75,y:0.75,width:34.5,height:34.5)); ring.lineWidth = 1.5; ring.stroke() }
      }.withRenderingMode(.alwaysOriginal),for:.normal)
      button.accessibilityTraits = active ? [.button,.selected] : .button
    }
    clearFill.isHidden = channel.selectedSegmentIndex != 1
    weight.value = Float(log2(style.strokeWidth))
    weightLabel.text = String(format:"%.1f",style.strokeWidth)
    for (index, button) in patterns.enumerated() { decorate(button, selected: (style.dash ?? .solid) == Self.dashes[index]) }
  }
  private func decorate(_ button: UIButton, selected: Bool) {
    button.backgroundColor = selected ? UIColor(NotebookChrome.selectionSurface) : .clear; button.layer.cornerRadius = 10
    button.tintColor = .label; button.accessibilityTraits = selected ? [.button,.selected] : .button
  }
  private static let dashes: [NotebookGraphic.Style.Dash] = [.solid,.dashed,.dotted]
  @objc private func channelChanged() { refresh() }
  @objc private func chooseColor(_ sender: UIButton) { applyColor(Self.colors[sender.tag].1) }
  private func applyColor(_ color: SpatialInkColor) {
    let fill = channel.selectedSegmentIndex == 1
    updateStyle { if fill { $0.fill = color } else { $0.stroke = color } }
  }
  @objc private func removeFill() { updateStyle { $0.fill = nil } }
  @objc private func chooseWidth(_ sender: UISlider) { let width = pow(2,Double(sender.value)); updateStyle { $0.strokeWidth = width } }
  @objc private func chooseDash(_ sender: UIButton) { updateStyle { $0.dash = Self.dashes[sender.tag] } }
  @objc private func customColor() {
    let picker = UIColorPickerViewController(); picker.delegate = self; picker.supportsAlpha = false
    picker.selectedColor = Self.color(channel.selectedSegmentIndex == 1 ? (style.fill ?? style.stroke) : style.stroke)
    present(picker,animated:true)
  }
  func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    if viewController.selectedColor.getRed(&r,green:&g,blue:&b,alpha:&a) { applyColor(.init(red:r,green:g,blue:b)) }
  }
  func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) { onDismiss?() }
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onDismiss?() }
  func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
  private static func color(_ value: SpatialInkColor) -> UIColor { .init(red:value.red,green:value.green,blue:value.blue,alpha:1) }
  private static func line(width: Double, dash: Int = 0) -> UIImage {
    UIGraphicsImageRenderer(size:.init(width:42,height:24)).image { _ in
      UIColor.label.setStroke(); let line = UIBezierPath(); line.move(to:.init(x:5,y:12)); line.addLine(to:.init(x:37,y:12))
      line.lineWidth = width; line.lineCapStyle = .round
      if dash == 1 { line.setLineDash([6,5],count:2,phase:0) }
      if dash == 2 { line.setLineDash([0,5],count:2,phase:0) }
      line.stroke()
    }.withRenderingMode(.alwaysTemplate)
  }
}
