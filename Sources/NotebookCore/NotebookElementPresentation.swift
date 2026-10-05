import CoreGraphics
import Foundation

/// The existing placement applied to a specialized body. Text remains TextKit,
/// a program keeps its native host, and pixels remain replaceable output.
public struct NotebookElementPresentation: Equatable, Sendable {
  public let placement: NotebookElementPlacement
  public let localBounds: CGRect
  public var bodySize: CGSize { .init(width:placement.localSize.x,height:max(placement.localSize.y,localBounds.maxY)) }
  private var transformedLocalBounds: CGRect {
    let t = placement.transform
    return localBounds.applying(.init(a: t.a, b: t.b, c: t.c, d: t.d, tx: 0, ty: 0))
  }
  public var bounds: CGRect {
    transformedLocalBounds.offsetBy(dx: placement.transform.tx, dy: placement.transform.ty)
  }
  public var frame: PageRect { .init(x:bounds.minX,y:bounds.minY,width:bounds.width,height:bounds.height) }
  public var requiresRasterTransform: Bool {
    let t=placement.transform
    return t.b != 0 || t.c != 0 || t.a < 0 || t.d < 0
  }
  public var maximumScale: Double {
    Self.maximumScale(placement.transform)
  }
  public static func maximumScale(_ t:CGAffineTransform) -> Double {
    let a=t.a*t.a+t.b*t.b,b=t.c*t.c+t.d*t.d,c=t.a*t.c+t.b*t.d
    return sqrt((a+b+hypot(a-b,2*c))/2)
  }
  public var transform: CGAffineTransform {
    let t = placement.transform, local = transformedLocalBounds
    // Derive the local pixel basis before translation. Subtracting two world
    // coordinates loses precision and changes otherwise identical moved pixels.
    return .init(a: t.a, b: t.b, c: t.c, d: t.d, tx: -local.minX, ty: -local.minY)
  }

  public init(placement: NotebookElementPlacement, text: String? = nil, style: NativeTextStyle = .standard) {
    self.placement=placement
    let body=PageRect(x:0,y:0,width:placement.localSize.x,height:placement.localSize.y)
    let local=text.map { NotebookTextTypography.fittingFrame($0,style:style,in:body) } ?? body
    localBounds = .init(x:local.x,y:local.y,width:local.width,height:local.height)
  }

  public init(_ element:SpatialElement,placement:NotebookElementPlacement) {
    self.init(placement:placement,text:element.kind == .nativeText ? element.source : nil,style:element.textStyle)
  }
  public init(_ element:AgentElement,placement:NotebookElementPlacement) {
    self.init(placement:placement,text:element.kind == .nativeText ? element.source : nil,style:element.textStyle ?? .standard)
  }
}

