import CoreGraphics
import Foundation
import Metal
import MetalKit
import ImageIO
import NotebookCore

extension InkRasterRenderer {
  /// Created completely on the decode worker, then only read by the encoder.
  private struct ExportTexture:@unchecked Sendable {let texture:any MTLTexture}
  /// Explicit export readback, using exactly the native outer composition. The
  /// caller owns the bounded output reservation and reuses one source mesh for
  /// all tiles. Transient GPU buffers remain charged until command completion.
  @MainActor func orderedImage(mesh:SpatialInkMesh,plan:NotebookOrderedInkPlan,camera:SpatialCamera?,
    viewport:SpatialPoint,region:CGRect,scale:Double,resources:SceneRenderResources, preparedGeometry:InkOrderedGeometry,baselinePNG:Data? = nil) async throws -> CGImage {
    try Task.checkCancellation()
    guard let device,let queue,let command=queue.makeCommandBuffer(),ordered != nil,
      region.width>0,region.height>0,scale.isFinite,scale>0,
      region.width*scale<=8192,region.height*scale<=8192 else {throw SceneRenderError.resourceLimit}
    let width=Int(ceil(region.width*scale)),height=Int(ceil(region.height*scale))
    let pixels=CGSize(width:width,height:height),samples=device.supportsTextureSampleCount(4) ? 4:1
    precondition(preparedGeometry.plan == plan)
    let geometry=preparedGeometry
    struct Selected:Sendable {
      let key:NotebookInkPaintKey
      let nodes:[InkRenderGeometry.Node]
      let flags:UInt32
      let color:SIMD4<Float>
      let affine:InkAffine
      let tool:SpatialInkTool
    }
    let grid=sampleGrid(viewport:region.size,pixels:pixels)
    let worker=Task.detached(priority:.utility) { () throws -> [Selected] in
      var selected:[Selected]=[]
      for batch in mesh.batches {
        try Task.checkCancellation()
        var transform=batch.projection.transform(camera:camera,viewport:viewport)
        transform.z -= Float(region.minX);transform.w -= Float(region.minY)
        let affine=InkAffine(transform),area=CGRect(origin:.zero,size:region.size)
        for range in batch.query(viewport:area,affine:affine,
          detail:.init(pixelsPerUnit:affine.maximumStretch*Float(scale),minimumPixelsPerUnit:affine.minimumStretch*Float(scale)),
          admitting:grid.map { grid in {grid.mayCover($0,affine:affine)} }).chunks {
          guard let key=batch.paintKey(for:range) else {throw SceneRenderError.snapshotPending("ordered_ink_painter")}
          let prepared=batch.prepareChunk(range).chunk,c=prepared.descriptor
          let level=InkRenderGeometry.level(c.levels,pixelsPerUnit:affine.maximumStretch*Float(scale),minimumPixelsPerUnit:affine.minimumStretch*Float(scale))
          let nodes=prepared.selected(level:level)
          if !nodes.isEmpty {selected.append(.init(key:key,nodes:Array(nodes),flags:c.flags,color:c.color,affine:affine,tool:batch.tool))}
        }
      }
      try Task.checkCancellation();return selected
    }
    let selected=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
    try Task.checkCancellation()
    var raw:[(NotebookInkPaintKey,Draw)]=[],held:[RasterReservation]=[]
    for item in selected {
      let bytes=item.nodes.count*MemoryLayout<InkRenderGeometry.Node>.stride
      guard let reservation=resources.reserveDerivedBytes(bytes,priority:.passive,owner:nil),
        let buffer=item.nodes.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}) else {throw SceneRenderError.resourceLimit}
      held.append(reservation)
      raw.append((item.key,.init(buffer:buffer,offset:0,count:item.nodes.count,flags:item.flags,color:item.color,affine:item.affine,
        viewport:.init(Float(region.width),Float(region.height)),tool:item.tool)))
    }
    let prepared=try geometry.events(raw:raw,camera:camera,viewport:viewport,region:region,pixels:pixels,
      device:device,resources:resources,owner:nil)
    held += prepared.reservations
    let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
    d.storageMode = .shared;d.usage = .renderTarget
    guard let output=device.makeTexture(descriptor:d) else {throw SceneRenderError.resourceLimit}
    let color=MTLRenderPassColorAttachmentDescriptor()
    if samples>1 {
      d.textureType = .type2DMultisample;d.sampleCount=samples;d.storageMode = .memoryless
      guard let msaa=device.makeTexture(descriptor:d) else {throw SceneRenderError.resourceLimit}
      color.texture=msaa;color.resolveTexture=output;color.storeAction = .multisampleResolve
    } else {color.texture=output;color.storeAction = .store}
    let scratch=try OrderedAttachments(device:device,width:width,height:height,samples:samples)
    let baselineTexture:(any MTLTexture)?
    if let baselinePNG {
      let decode=Task.detached(priority:.utility) { () throws -> ExportTexture in
        try Task.checkCancellation()
        guard let source=CGImageSourceCreateWithData(baselinePNG as CFData,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {throw SceneRenderError.snapshotPending("ink_baseline")}
        let texture=try MTKTextureLoader(device:device).newTexture(cgImage:image,options:[.SRGB:false])
        try Task.checkCancellation();return ExportTexture(texture:texture)
      }
      baselineTexture=try await withTaskCancellationHandler {try await decode.value.texture} onCancel:{decode.cancel()}
    } else {baselineTexture=nil}
    guard let encoder=command.makeRenderCommandEncoder(descriptor:scratch.descriptor(output:color)) else {throw SceneRenderError.resourceLimit}
    try encodeOrdered(prepared.events,baseline:baselineTexture,textureRect:.init(Float(region.minX/viewport.x),Float(region.minY/viewport.y),Float(region.width/viewport.x),Float(region.height/viewport.y)),encoder:encoder)
    encoder.endEncoding();try Task.checkCancellation()
    let succeeded=await withCheckedContinuation { (continuation:CheckedContinuation<Bool,Never>) in
      command.addCompletedHandler { command in continuation.resume(returning:command.status == .completed) }
      command.commit()
    }
    withExtendedLifetime((held,geometry,scratch,prepared)) {}
    try Task.checkCancellation()
    guard succeeded else {throw SceneRenderError.resourceLimit}
    let completedTexture=ExportTexture(texture:output)
    let readback=Task.detached(priority:.utility) { () throws -> CGImage in
      try Task.checkCancellation()
      var bytes=[UInt8](repeating:0,count:width*height*4)
      completedTexture.texture.getBytes(&bytes,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)
      guard let provider=CGDataProvider(data:Data(bytes) as CFData),let image=CGImage(width:width,height:height,
        bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
        bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)],
        provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else {throw SceneRenderError.resourceLimit}
      try Task.checkCancellation();return image
    }
    return try await withTaskCancellationHandler {try await readback.value} onCancel:{readback.cancel()}
  }
}
