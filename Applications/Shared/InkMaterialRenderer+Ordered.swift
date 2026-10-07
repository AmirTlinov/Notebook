import CoreGraphics
import Darwin
import Foundation
import Metal
import NotebookCore

extension InkMaterialRenderer {
  /// Local geometry retained by one entry of the installed/prepared ink plan.
  /// This is not another physical view or renderer: Canvas owns its single
  /// drawable and InkRasterRenderer owns the only ordered composition algorithm.
  @MainActor final class OrderedBody {
    let source:NotebookOrderedInkPlan.Body
    private var materials:(body:InkMaterialRenderer,cuts:InkMaterialRenderer)?
    private var needsMaterialStaging=true
    private struct PolygonClip {
      let mask:NotebookGraphicMask
      let size:CGSize
      let projection:NotebookGraphicLayout.Projection?
      let buffer:any MTLBuffer
      let count:Int
      let reservation:RasterReservation
    }
    private enum Clip {
      case rectangle(size:CGSize,projection:NotebookGraphicLayout.Projection?)
      case polygon(PolygonClip)
      func matches(mask:NotebookGraphicMask?,size:CGSize,projection:NotebookGraphicLayout.Projection?)->Bool {
        switch self {
        case .rectangle(let previousSize,let previousProjection):
          return mask == nil && previousSize == size && previousProjection == projection
        case .polygon(let previous):
          return mask == previous.mask && previous.size == size && previous.projection == projection
        }
      }
    }
    private var clip:Clip?
    init(_ source:NotebookOrderedInkPlan.Body,reusing old:OrderedBody? = nil) {
      self.source=source
      // Borrow renderers directly, never the previous OrderedBody. A visible
      // candidate stages its own mutable material before it prepares draws.
      materials=old?.materials
      let size=CGSize(width:source.layout.frame.width,height:source.layout.frame.height)
      if let previous=old?.clip,previous.matches(mask:source.graphic.mask,size:size,projection:source.layout.projection) {clip=previous}
    }
    private func stageMaterials()->(body:InkMaterialRenderer,cuts:InkMaterialRenderer) {
      if !needsMaterialStaging,let materials {return materials}
      func stage(_ previous:InkMaterialRenderer?,_ content:NotebookInkMaterialView.Content)->InkMaterialRenderer {
        if let previous {return previous.staging(content)}
        let next=InkMaterialRenderer();next.update(content);return next
      }
      let body=stage(materials?.body,.init(freehand:source.graphic.freehand,erasures:[],
        transform:source.graphic.transform,layout:source.layout,mask:source.graphic.mask))
      let cuts=stage(materials?.cuts,.init(freehand:nil,erasures:source.erasures,
        transform:source.graphic.transform,layout:source.layout,mask:source.graphic.mask))
      materials=(body,cuts);needsMaterialStaging=false
      return (body,cuts)
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
      try Task.checkCancellation()
      let projection=source.layout.projection
      let size=CGSize(width:source.layout.frame.width,height:source.layout.frame.height)
      guard let mask=source.graphic.mask else {
        clip = .rectangle(size:size,projection:projection)
        return
      }
      let worker=Task.detached(priority:.userInitiated) { () throws -> ClipPolygon in
        try Task.checkCancellation()
        let path=mask.projectedRegionPath(in:CGRect(origin:.zero,size:size),projection:projection)
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
      guard !length.overflow else {throw SceneRenderError.resourceLimit}
      let allocation=device.heapBufferSizeAndAlign(length:length.partialValue,options:.storageModeShared)
      // Standalone shared backing can occupy a VM page beyond heap placement.
      // Admit the aligned estimate first, then verify the actual resource size.
      let alignment=max(Int(getpagesize()),allocation.align)
      let base=max(length.partialValue,allocation.size)
      let bytes=base.addingReportingOverflow((alignment-base%alignment)%alignment)
      guard !bytes.overflow,
        let reservation=resources.reserveDerivedBytes(bytes.partialValue,priority:owner?.allocationPriority ?? .input,owner:owner),
        let buffer=device.makeBuffer(length:length.partialValue,options:.storageModeShared),
        buffer.allocatedSize <= reservation.byteCount else {throw SceneRenderError.resourceLimit}
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
      clip = .polygon(.init(mask:mask,size:size,projection:projection,buffer:buffer,count:polygon.count,reservation:reservation))
    }
    func prepare(camera:SpatialCamera?,viewport:SpatialPoint,region:CGRect,pixels:CGSize,device:any MTLDevice,resources:SceneRenderResources,
      owner:ScenePhysicalOwnerLease?,extraCuts:[InkElementErasure] = [],damage:CGRect? = nil) throws -> (event:InkRasterRenderer.OrderedEvent,reservations:[RasterReservation]) {
      guard let clip else {throw SceneRenderError.snapshotPending("ink_region_mask")}
      let size=CGSize(width:source.layout.frame.width,height:source.layout.frame.height)
      let position=camera.map { $0.worldToScreen(source.layout.origin.offsetBy(x:source.layout.frame.x,y:source.layout.frame.y),viewport:viewport) }
        ?? .init(x:source.layout.frame.x,y:source.layout.frame.y)
      let scale=camera?.scale ?? 1
      let local=CGRect(x:(region.minX-position.x)/scale,y:(region.minY-position.y)/scale,width:region.width/scale,height:region.height/scale)
      let localDamage=damage.map{CGRect(x:($0.minX-position.x)/scale,y:($0.minY-position.y)/scale,width:$0.width/scale,height:$0.height/scale)}
      let (body,cuts)=stageMaterials()
      let b=try body.prepareDraws(region:local,sourceSize:size,pixels:pixels,device:device,resources:resources,owner:owner,damage:localDamage)
      cuts.update(.init(freehand:nil,erasures:source.erasures+extraCuts.filter{!source.erasures.contains($0)},
        transform:source.graphic.transform,layout:source.layout,mask:source.graphic.mask))
      let c=try cuts.prepareDraws(region:local,sourceSize:size,pixels:pixels,device:device,resources:resources,owner:owner,damage:localDamage)
      func project(_ draw:InkRasterRenderer.Draw)->InkRasterRenderer.Draw {
        .init(buffer:draw.buffer,offset:draw.offset,count:draw.count,flags:draw.flags,color:draw.color,
          affine:.init(x:draw.affine.x*Float(scale),y:draw.affine.y*Float(scale)),
          viewport:.init(Float(region.width),Float(region.height)),tool:draw.tool)
      }
      let affine=InkAffine(x:.init(Float(scale),0,-Float(local.minX*scale),0),y:.init(0,Float(scale),-Float(local.minY*scale),0))
      let viewport=SIMD2<Float>(Float(region.width),Float(region.height))
      let mask:InkRasterRenderer.OrderedClip
      var held=b.reservations+c.reservations
      switch clip {
      case .rectangle(let size,_):mask = .rectangle(size:size,affine:affine,viewport:viewport)
      case .polygon(let clip):
        mask = .polygon(.init(buffer:clip.buffer,offset:0,count:clip.count,flags:8,
          color:.init(repeating:1),affine:affine,viewport:viewport,tool:.pen))
        held.append(clip.reservation)
      }
      return (.body(draws:(b.draws+c.draws).map(project),clip:mask),held)
    }
  }
}
