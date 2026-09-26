import CoreGraphics
import Foundation
import Metal
import NotebookCore

extension InkMaterialRenderer {
  /// Local geometry retained by one entry of the installed/prepared ink plan.
  /// This is not another physical view or renderer: Canvas owns its single
  /// drawable and InkRasterRenderer owns the only ordered composition algorithm.
  @MainActor final class OrderedBody {
    let source:NotebookOrderedInkPlan.Body
    private let body:InkMaterialRenderer
    private let cuts:InkMaterialRenderer
    private struct Clip {
      let mask:NotebookGraphicMask?
      let size:CGSize
      let projection:NotebookGraphicLayout.Projection?
      let buffer:any MTLBuffer
      let count:Int
      let reservation:RasterReservation
    }
    private var clip:Clip?
    init(_ source:NotebookOrderedInkPlan.Body,reusing old:OrderedBody? = nil) {
      self.source=source
      let b=NotebookInkMaterialView.Content(freehand:source.graphic.freehand,erasures:[],
        transform:source.graphic.transform,layout:source.layout,mask:source.graphic.mask)
      let c=NotebookInkMaterialView.Content(freehand:nil,erasures:source.erasures,
        transform:source.graphic.transform,layout:source.layout,mask:source.graphic.mask)
      body=(old?.body ?? InkMaterialRenderer()).staging(b)
      cuts=(old?.cuts ?? InkMaterialRenderer()).staging(c)
      let size=CGSize(width:source.layout.frame.width,height:source.layout.frame.height)
      if let previous=old?.clip,previous.mask == source.graphic.mask,
        previous.size == size,previous.projection == source.layout.projection {clip=previous}
    }
    // CGPath is immutable after preparation. The buffer is written only by
    // the preparation worker and cannot be encoded until that worker returns.
    private struct ClipPolygon: @unchecked Sendable {
      let path:CGPath
      let count:Int
    }
    private struct ClipUpload: @unchecked Sendable {
      let polygon:ClipPolygon
      let buffer:any MTLBuffer
    }
    nonisolated private static func visitClipTriangles(_ path:CGPath,
      _ emit:(CGPoint,CGPoint,CGPoint)->Void) throws {
      var first:CGPoint?,previous:CGPoint?,invalid=false
      path.applyWithBlock { value in
        switch value.pointee.type {
        case .moveToPoint:
          first=value.pointee.points[0];previous=nil
        case .addLineToPoint:
          let point=value.pointee.points[0]
          if let first,let previous {emit(first,previous,point)}
          previous=point
        case .closeSubpath:first=nil;previous=nil
        default:invalid=true
        }
      }
      try Task.checkCancellation()
      // Exact even-odd stencil operands; never flatten unexpected curves or
      // substitute their bounds for the user's region.
      guard !invalid else {throw SceneRenderError.snapshotPending("ink_region_mask")}
    }
    func prepareClip(device:any MTLDevice,resources:SceneRenderResources,owner:ScenePhysicalOwnerLease?) async throws {
      guard clip == nil else { return }
      let mask=source.graphic.mask,projection=source.layout.projection
      let size=CGSize(width:source.layout.frame.width,height:source.layout.frame.height)
      let worker=Task.detached(priority:.userInitiated) { () throws -> ClipPolygon in
        try Task.checkCancellation()
        let path=mask?.projectedRegionPath(in:CGRect(origin:.zero,size:size),projection:projection)
          ?? CGPath(rect:CGRect(origin:.zero,size:size),transform:nil)
        var count=0,overflow=false
        try Self.visitClipTriangles(path) { _,_,_ in
          let next=count.addingReportingOverflow(3)
          count=next.partialValue;overflow = overflow || next.overflow
        }
        guard !overflow else {throw SceneRenderError.resourceLimit}
        return .init(path:path,count:count)
      }
      let polygon=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
      try Task.checkCancellation()
      let length=max(1,polygon.count).multipliedReportingOverflow(by:MemoryLayout<InkRenderGeometry.Node>.stride)
      guard !length.overflow,
        let reservation=resources.reserveDerivedBytes(length.partialValue,priority:owner?.allocationPriority ?? .input,owner:owner),
        let buffer=device.makeBuffer(length:length.partialValue,options:.storageModeShared) else {throw SceneRenderError.resourceLimit}
      let upload=ClipUpload(polygon:polygon,buffer:buffer)
      let fill=Task.detached(priority:.userInitiated) {
        try Task.checkCancellation()
        let nodes=upload.buffer.contents().bindMemory(to:InkRenderGeometry.Node.self,capacity:max(1,upload.polygon.count))
        var offset=0
        func append(_ point:CGPoint) {
          nodes.advanced(by:offset).initialize(to:.init(position:.init(Float(point.x),Float(point.y)),edge:.zero,radius:0,alpha:1))
          offset += 1
        }
        try Self.visitClipTriangles(upload.polygon.path) {a,b,c in append(a);append(b);append(c)}
        precondition(offset == upload.polygon.count)
      }
      try await withTaskCancellationHandler {try await fill.value} onCancel:{fill.cancel()}
      try Task.checkCancellation()
      clip = .init(mask:mask,size:size,projection:projection,buffer:buffer,count:polygon.count,reservation:reservation)
    }
    func prepare(camera:SpatialCamera?,viewport:SpatialPoint,region:CGRect,pixels:CGSize,device:any MTLDevice,resources:SceneRenderResources,
      owner:ScenePhysicalOwnerLease?,extraCuts:[InkElementErasure] = []) throws -> (event:InkRasterRenderer.OrderedEvent,reservations:[RasterReservation]) {
      guard let clip else {throw SceneRenderError.snapshotPending("ink_region_mask")}
      let size=CGSize(width:source.layout.frame.width,height:source.layout.frame.height)
      let position=camera.map { $0.worldToScreen(source.layout.origin.offsetBy(x:source.layout.frame.x,y:source.layout.frame.y),viewport:viewport) }
        ?? .init(x:source.layout.frame.x,y:source.layout.frame.y)
      let scale=camera?.scale ?? 1
      let local=CGRect(x:(region.minX-position.x)/scale,y:(region.minY-position.y)/scale,width:region.width/scale,height:region.height/scale)
      let b=try body.prepareDraws(region:local,sourceSize:size,pixels:pixels,device:device,resources:resources,owner:owner)
      cuts.update(.init(freehand:nil,erasures:source.erasures+extraCuts.filter{!source.erasures.contains($0)},
        transform:source.graphic.transform,layout:source.layout,mask:source.graphic.mask))
      let c=try cuts.prepareDraws(region:local,sourceSize:size,pixels:pixels,device:device,resources:resources,owner:owner)
      func project(_ draw:InkRasterRenderer.Draw)->InkRasterRenderer.Draw {
        .init(buffer:draw.buffer,offset:draw.offset,count:draw.count,flags:draw.flags,color:draw.color,
          affine:.init(x:draw.affine.x*Float(scale),y:draw.affine.y*Float(scale)),
          viewport:.init(Float(region.width),Float(region.height)),tool:draw.tool)
      }
      let mask=InkRasterRenderer.Draw(buffer:clip.buffer,offset:0,count:clip.count,flags:8,
        color:.init(repeating:1),affine:.init(x:.init(Float(scale),0,-Float(local.minX*scale),0),y:.init(0,Float(scale),-Float(local.minY*scale),0)),
        viewport:.init(Float(region.width),Float(region.height)),tool:.pen)
      return (.body(draws:(b.draws+c.draws).map(project),clip:mask),b.reservations+c.reservations+[clip.reservation])
    }
  }
}
