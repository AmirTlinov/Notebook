import Foundation

/// A derived view of the accepted sequence, not another authored ink source.
/// A point survives the existing normalizer exactly when its RAW successor is
/// distinct (or absent). Testing against a previously retained point would
/// normalize twice and change a returning contour, its alpha and its tangents.
extension InkSampleRelations.Sequence {
  func normalizedForDisplay(projection:InkSampleProjection,next:SpatialInkGeometry.RenderPoint? = nil,
    cost:inout InkSampleRelations.AccessCost) -> InkSampleRelations.Sequence {
    cost.visitedNodes += 1
    guard count > 0 else { return self }
    func point(_ sample:SpatialInkSample) -> SpatialInkGeometry.RenderPoint {
      SpatialInkGeometry.renderPoint(from:sample,color:.init(repeating:1),projection:projection)
    }
    func survives(_ last:SpatialInkGeometry.RenderPoint) -> Bool {
      next.map { !SpatialInkGeometry.areCoincident(last,$0) } ?? true
    }
    let geometry=geometry
    if geometry.stationary {
      let last=sample(at:count-1,cost:&cost)
      return survives(point(last)) ? slice((count-1)..<count) : Self.empty
    }
    let error=Self.projectionError(geometry,projection:projection)
    if error.isFinite,geometry.minimumSpacing*abs(projection.scale)
      > Double(InkStrokeGeometry.minimumDistanceSquared.squareRoot())+error {
      // The entire interior is proven distinct without visiting its children.
      if next == nil || survives(point(sample(at:count-1,cost:&cost))) { return self }
      return slice(0..<(count-1))
    }
    if case .repeated(let body,let repetitions,let step)=content,body.count > 1,repetitions > 1,
      error.isFinite,body.geometry.minimumSpacing*abs(projection.scale)
        > Double(InkStrokeGeometry.minimumDistanceSquared.squareRoot())+error,
      body.geometry.last == body.geometry.first?.shifted(step),
      let prefix=Self.repeated(body.slice(0..<(body.count-1)),count:repetitions-1,step:step),
      let offset=step.multiplied(by:repetitions-1),let tail=body.shifted(offset) {
      // Every interior is distinct at this projection, and each exact seam
      // discards the preceding occurrence's last event. Keep that repeated
      // relation shared rather than visiting all of its logical occurrences.
      return Self.balance(prefix,tail.normalizedForDisplay(projection:projection,next:next,cost:&cost))
    }
    if count <= InkSampleRelations.blockSize {
      var raw:[SpatialInkSample]=[]
      forEachSample(in:0..<count) { raw.append($0) }
      cost.decodedSamples += raw.count
      let points=raw.map(point)
      let kept=raw.indices.filter { i in
        i+1 == raw.count ? survives(points[i]) : !SpatialInkGeometry.areCoincident(points[i],points[i+1])
      }
      if kept.count == count { return self }
      return Self(block:.init(kept.map { raw[$0] }[...]))
    }
    let left:InkSampleRelations.Sequence,right:InkSampleRelations.Sequence
    if case .pair(let a,let b)=content { left=a;right=b }
    else { let mid=count/2;left=slice(0..<mid);right=slice(mid..<count) }
    let boundary=point(right.sample(at:0,cost:&cost))
    let a=left.normalizedForDisplay(projection:projection,next:boundary,cost:&cost)
    let b=right.normalizedForDisplay(projection:projection,next:next,cost:&cost)
    return a === left && b === right ? self : Self.balance(a,b)
  }

  static func projectionError(_ geometry:InkSampleRelations.Geometry,projection:InkSampleProjection) -> Double {
    var box=geometry.bounds
    if let origin=geometry.origin,let target=projection.origin {
      let d=target.delta(to:origin);box=InkSampleRelations.Geometry.offset(box,x:d.x,y:d.y)
    }
    let magnitude=[box.minX*projection.scale+projection.offset.x,box.maxX*projection.scale+projection.offset.x,
      box.minY*projection.scale+projection.offset.y,box.maxY*projection.scale+projection.offset.y]
      .map { abs(Float($0)) }.max() ?? .infinity
    return 4*Double(magnitude.ulp)
  }
}
