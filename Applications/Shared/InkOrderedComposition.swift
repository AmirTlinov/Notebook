import CoreGraphics
import Foundation
import Metal
import NotebookCore

extension InkRasterRenderer {
  /// Already admitted geometry. Both live and readback owners bind these same
  /// buffers; this value owns no preparation, reservation or presentation clock.
  struct Draw {
    let buffer:any MTLBuffer
    let offset:Int
    let count:Int
    let flags:UInt32
    let color:SIMD4<Float>
    let affine:InkAffine
    let viewport:SIMD2<Float>
    let tool:SpatialInkTool
  }
  enum OrderedEvent {
    case raw(Draw)
    /// The local body remains a forward pen/cut sequence. Only the OUTER paint
    /// events are traversed backwards. The clip is an exact even-odd triangle fan.
    case body(draws:[Draw],clip:Draw)
  }
  struct OrderedPipelines:Sendable {
    let raw:any MTLRenderPipelineState
    let body:any MTLRenderPipelineState
    let cut:any MTLRenderPipelineState
    let fold:any MTLRenderPipelineState
    let clear:any MTLRenderPipelineState
    let finish:any MTLRenderPipelineState
    let clip:any MTLRenderPipelineState
    let baseline:any MTLRenderPipelineState
    let invertClip:any MTLDepthStencilState
    let insideClip:any MTLDepthStencilState
    let clearClip:any MTLDepthStencilState

    init(device:any MTLDevice,library:any MTLLibrary,samples:Int) throws {
      func pipeline(_ vertex:String,_ fragment:String,_ writes:Set<Int>,erase:Bool? = nil) throws -> any MTLRenderPipelineState {
        let value=MTLRenderPipelineDescriptor()
        value.vertexFunction=library.makeFunction(name:vertex)
        value.fragmentFunction=library.makeFunction(name:fragment)
        value.rasterSampleCount=samples;value.stencilAttachmentPixelFormat = .stencil8
        let formats:[MTLPixelFormat]=[.rgba32Float,.r32Float,.rgba16Float,.bgra8Unorm]
        for i in formats.indices {
          let c=value.colorAttachments[i]!;c.pixelFormat=formats[i]
          c.writeMask=writes.contains(i) ? .all:[]
          if let erase,writes.contains(i) {
            c.isBlendingEnabled=true
            c.sourceRGBBlendFactor=erase ? .zero:.one;c.sourceAlphaBlendFactor=erase ? .zero:.one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha;c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
          }
        }
        return try device.makeRenderPipelineState(descriptor:value)
      }
      raw=try pipeline("compactInkVertex","orderedInkRawFragment",[0,1])
      body=try pipeline("compactInkVertex","orderedInkBodyFragment",[2],erase:false)
      cut=try pipeline("compactInkVertex","orderedInkBodyFragment",[2],erase:true)
      fold=try pipeline("stableInkVertex","orderedInkFoldFragment",[0,1])
      clear=try pipeline("stableInkVertex","orderedInkClearFragment",[2])
      finish=try pipeline("stableInkVertex","orderedInkFinalFragment",[3])
      clip=try pipeline("compactInkVertex","orderedInkBodyFragment",[])
      baseline=try pipeline("stableInkVertex","orderedInkBaselineFragment",[0,1])
      func stencil(compare:MTLCompareFunction,operation:MTLStencilOperation,write:UInt32) throws -> any MTLDepthStencilState {
        let s=MTLStencilDescriptor();s.stencilCompareFunction=compare
        s.stencilFailureOperation = .keep;s.depthFailureOperation = .keep;s.depthStencilPassOperation=operation
        s.readMask=1;s.writeMask=write
        let d=MTLDepthStencilDescriptor();d.frontFaceStencil=s;d.backFaceStencil=s
        guard let state=device.makeDepthStencilState(descriptor:d) else { throw SceneRenderError.resourceLimit }
        return state
      }
      invertClip=try stencil(compare:.always,operation:.invert,write:1)
      insideClip=try stencil(compare:.equal,operation:.keep,write:0)
      clearClip=try stencil(compare:.always,operation:.zero,write:1)
    }
  }

  /// Three transient colour attachments plus one stencil. On the supported
  /// Apple-family targets these are tile memory, never per-body retained pixels.
  /// The caller retains this value with the existing command's resources.
  final class OrderedAttachments: @unchecked Sendable {
    let width:Int,height:Int,samples:Int
    let textures:[any MTLTexture]
    let stencil:any MTLTexture
    var allocatedBytes:Int { textures.reduce(stencil.allocatedSize){$0+$1.allocatedSize} }
    init(device:any MTLDevice,width:Int,height:Int,samples:Int) throws {
      guard device.supportsFamily(.apple1),width>0,height>0 else { throw SceneRenderError.resourceLimit }
      self.width=width;self.height=height;self.samples=samples
      func texture(_ format:MTLPixelFormat) throws -> any MTLTexture {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
        d.usage = .renderTarget;d.storageMode = .memoryless
        if samples>1 {d.textureType = .type2DMultisample;d.sampleCount=samples}
        guard let result=device.makeTexture(descriptor:d),result.allocatedSize == 0 else { throw SceneRenderError.resourceLimit }
        return result
      }
      textures=try [.rgba32Float,.r32Float,.rgba16Float].map(texture)
      stencil=try texture(.stencil8)
    }
    func matches(_ texture:any MTLTexture)->Bool {
      width == texture.width && height == texture.height && samples == texture.sampleCount
    }
    func descriptor(output:MTLRenderPassColorAttachmentDescriptor)->MTLRenderPassDescriptor {
      let pass=MTLRenderPassDescriptor()
      for i in textures.indices {
        let c=pass.colorAttachments[i]!;c.texture=textures[i];c.loadAction = .clear;c.storeAction = .dontCare
        c.clearColor=i == 0 ? .init(red:0,green:0,blue:0,alpha:1)
          : i == 1 ? .init(red:1,green:0,blue:0,alpha:0):.init(red:0,green:0,blue:0,alpha:0)
      }
      pass.colorAttachments[3]=output.copy() as? MTLRenderPassColorAttachmentDescriptor
      pass.colorAttachments[3].loadAction = .clear
      pass.colorAttachments[3].clearColor = .init(red:0,green:0,blue:0,alpha:0)
      pass.stencilAttachment.texture=stencil;pass.stencilAttachment.loadAction = .clear
      pass.stencilAttachment.storeAction = .dontCare;pass.stencilAttachment.clearStencil=0
      return pass
    }
  }

  func encode(_ draw:Draw,pipeline:any MTLRenderPipelineState,encoder:any MTLRenderCommandEncoder) {
    guard let connectivity else { return }
    var viewport=draw.viewport,affine=draw.affine
    var primitive=InkPrimitive(count:UInt32(draw.count),flags:draw.flags,color:draw.color)
    var erases:UInt32=draw.tool == .eraser ? 1:0
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(draw.buffer,offset:draw.offset,index:0)
    encoder.setVertexBytes(&viewport,length:MemoryLayout<SIMD2<Float>>.stride,index:1)
    encoder.setVertexBytes(&affine,length:MemoryLayout<InkAffine>.stride,index:2)
    encoder.setVertexBytes(&primitive,length:MemoryLayout<InkPrimitive>.stride,index:3)
    encoder.setFragmentBytes(&erases,length:MemoryLayout<UInt32>.stride,index:0)
    connectivity.draw(nodes:draw.count,flags:draw.flags,encoder:encoder)
  }

  /// The only outer composition algorithm, shared by live canvases and exported
  /// pixels. The caller has already selected visible geometry and admitted all
  /// buffers. No await, source query, allocation or presentation occurs here.
  func encodeOrdered(_ events:[OrderedEvent],baseline:(any MTLTexture)?,textureRect:SIMD4<Float>,
    encoder:any MTLRenderCommandEncoder) throws {
    guard let p=ordered else { throw SceneRenderError.resourceLimit }
    func quad(_ pipeline:any MTLRenderPipelineState) {
      var rect=textureRect
      encoder.setRenderPipelineState(pipeline)
      encoder.setVertexBytes(&rect,length:MemoryLayout<SIMD4<Float>>.stride,index:0)
      encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
    }
    for event in events.reversed() {
      switch event {
      case .raw(let draw):
        encoder.setDepthStencilState(nil);encode(draw,pipeline:p.raw,encoder:encoder)
      case .body(let draws,let clip):
        encoder.setStencilReferenceValue(1);encoder.setDepthStencilState(p.invertClip)
        encode(clip,pipeline:p.clip,encoder:encoder)
        encoder.setDepthStencilState(p.insideClip)
        for draw in draws {encode(draw,pipeline:draw.tool == .eraser ? p.cut:p.body,encoder:encoder)}
        encoder.setDepthStencilState(nil);quad(p.fold)
        // Do not combine the fetch with scratch clear: MSAA sample ownership
        // must finish reading the body before this separate raster operation.
        encoder.setDepthStencilState(p.clearClip);quad(p.clear)
      }
    }
    encoder.setDepthStencilState(nil)
    if let baseline {encoder.setFragmentTexture(baseline,index:0);quad(p.baseline)}
    quad(p.finish)
  }
}
