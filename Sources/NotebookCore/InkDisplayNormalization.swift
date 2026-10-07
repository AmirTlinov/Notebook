import Foundation

extension InkSampleRelations {
  public enum DisplayPredecessor: Equatable, Sendable {
    case point(Address), none, unproven
  }

  /// The last raw point before `index` that survives its immediate raw
  /// successor. Only source summaries and bounded ambiguous leaves are read;
  /// an unproved long near-coincident chain retains conservative damage.
  public func lastDisplayPredecessor(before index:Int,projection:InkSampleProjection)
    -> (result:DisplayPredecessor,cost:AccessCost) {
    precondition((0..<count).contains(index))
    var cost=AccessCost(),remaining=2048
    guard index > 0 else {return (.none,cost)}
    guard storage.root.worldEvents == 0 || projection.origin != nil,
      projection.scale.isFinite,projection.offset.x.isFinite,projection.offset.y.isFinite else {
      return (.unproven,cost)
    }
    func consume(_ read:AccessCost)->Bool {
      cost.visitedNodes += read.visitedNodes;cost.jumps += read.jumps;cost.decodedSamples += read.decodedSamples
      remaining -= read.visitedNodes+read.decodedSamples
      return remaining >= 0
    }
    func point(at index:Int)->SpatialInkGeometry.RenderPoint? {
      guard remaining > 0 else {return nil}
      var read=AccessCost()
      let sample=storage.root.sample(at:index,cost:&read)
      guard consume(read) else {return nil}
      return SpatialInkGeometry.renderPoint(from:sample,color:.init(repeating:1),projection:projection)
    }
    func visit(_ range:Range<Int>,next:SpatialInkGeometry.RenderPoint)->DisplayPredecessor {
      guard remaining > 0 else {return .unproven}
      var read=AccessCost()
      let summary=storage.root.geometryCovering(range,cost:&read)
      guard consume(read),let last=point(at:range.upperBound-1) else {return .unproven}
      if !SpatialInkGeometry.areCoincident(last,next) {return .point(address(at:range.upperBound-1))}
      if summary.stationary {return .none}
      let error=Sequence.projectionError(summary,projection:projection)
      if Sequence.hasDistinctDisplayInterior(summary,projection:projection,error:error) {
        return range.count > 1 ? .point(address(at:range.upperBound-2)):.none
      }
      if range.count <= Self.blockSize {
        guard remaining >= range.count else {return .unproven}
        remaining -= range.count;cost.decodedSamples += range.count
        var points:[SpatialInkGeometry.RenderPoint]=[]
        points.reserveCapacity(range.count)
        storage.root.forEachSample(in:range) {
          points.append(SpatialInkGeometry.renderPoint(from:$0,color:.init(repeating:1),projection:projection))
        }
        var successor=next
        for offset in points.indices.reversed() {
          let previous=points[offset]
          if !SpatialInkGeometry.areCoincident(previous,successor) {
            return .point(address(at:range.lowerBound+offset))
          }
          // Always advance to the RAW predecessor, including discarded points.
          successor=previous
        }
        return .none
      }
      let middle=range.lowerBound+range.count/2
      let right=visit(middle..<range.upperBound,next:next)
      guard case .none=right else {return right}
      guard let boundary=point(at:middle) else {return .unproven}
      return visit(range.lowerBound..<middle,next:boundary)
    }
    guard let next=point(at:index) else {return (.unproven,cost)}
    let result=visit(0..<index,next:next)
    return (result,cost)
  }
}

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
    if Self.hasDistinctDisplayInterior(geometry,projection:projection,error:error) {
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

  static func hasDistinctDisplayInterior(_ geometry:InkSampleRelations.Geometry,
    projection:InkSampleProjection,error:Double)->Bool {
    error.isFinite && geometry.minimumSpacing*abs(projection.scale)
      > Double(InkStrokeGeometry.minimumDistanceSquared.squareRoot())+error
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
