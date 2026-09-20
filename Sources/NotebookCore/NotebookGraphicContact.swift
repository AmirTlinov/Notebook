import CoreGraphics
import Foundation

extension NotebookGraphicGeometry {
  /// Closest contact on the painter's contour, measured AFTER the whole basis.
  /// Query-only subdivision uses a physical-point error; source curves stay intact.
  static func outlineContact(_ graphic: NotebookGraphic,size: CGSize,transform: CGAffineTransform,
    point: SpatialPoint,tolerance: Double) -> (inside:Bool,distance:Double,point:SpatialPoint) {
    var map=transform
    let path=outlinePath(graphic,in:CGRect(origin:.zero,size:size)).copy(using:&map)!
    let p=CGPoint(x:point.x,y:point.y),inside=graphic.shape != .plus && path.contains(p)
    if inside { return (true,0,point) }
    let error=max(0.000001,min(0.1,tolerance/32))
    var nearest=CGPoint.zero,best=max(0,tolerance)+error,current=CGPoint.zero,start=CGPoint.zero
    var found=false,unresolved=false,visits=0
    func segment(_ a: CGPoint,_ b: CGPoint) {
      let dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy
      let t=length>0 ? min(1,max(0,((p.x-a.x)*dx+(p.y-a.y)*dy)/length)) : 0
      let q=CGPoint(x:a.x+t*dx,y:a.y+t*dy),d=hypot(p.x-q.x,p.y-q.y)
      if d<=best { best=d;nearest=q;found=true }
    }
    func midpoint(_ a: CGPoint,_ b: CGPoint) -> CGPoint { .init(x:a.x/2+b.x/2,y:a.y/2+b.y/2) }
    func curve(_ a: CGPoint,_ b: CGPoint,_ c: CGPoint,_ d: CGPoint,_ depth: Int = 0) {
      let left=min(a.x,b.x,c.x,d.x),right=max(a.x,b.x,c.x,d.x),top=min(a.y,b.y,c.y,d.y),bottom=max(a.y,b.y,c.y,d.y)
      guard hypot(max(left-p.x,0,p.x-right),max(top-p.y,0,p.y-bottom))<=best else { return }
      // Control-point distance to the chord segment bounds the cubic's error,
      // including loops whose midpoint happens to land on that chord.
      let dx=d.x-a.x,dy=d.y-a.y,length=dx*dx+dy*dy
      func deviation(_ q: CGPoint) -> Double {
        let t=length>0 ? min(1,max(0,((q.x-a.x)*dx+(q.y-a.y)*dy)/length)) : 0
        return hypot(q.x-a.x-t*dx,q.y-a.y-t*dy)
      }
      visits += 1
      if max(deviation(b),deviation(c))<=error { segment(a,d);return }
      guard depth<20,visits<4096 else { unresolved=true;return }
      let ab=midpoint(a,b),bc=midpoint(b,c),cd=midpoint(c,d),abc=midpoint(ab,bc),bcd=midpoint(bc,cd),middle=midpoint(abc,bcd)
      curve(a,ab,abc,middle,depth+1);curve(middle,bcd,cd,d,depth+1)
    }
    path.applyWithBlock { pointer in
      let e=pointer.pointee
      switch e.type {
      case .moveToPoint: current=e.points[0];start=current
      case .addLineToPoint: segment(current,e.points[0]);current=e.points[0]
      case .addQuadCurveToPoint:
        let b=e.points[0],end=e.points[1]
        curve(current,.init(x:current.x/3+2*b.x/3,y:current.y/3+2*b.y/3),
          .init(x:end.x/3+2*b.x/3,y:end.y/3+2*b.y/3),end);current=end
      case .addCurveToPoint: curve(current,e.points[0],e.points[1],e.points[2]);current=e.points[2]
      case .closeSubpath: segment(current,start);current=start
      @unknown default: break
      }
    }
    // Optional attraction may remain unproved; it must never move the nib
    // to a coarse chord merely because the subdivision budget was exhausted.
    guard found,!unresolved else { return (false,.infinity,point) }
    return (false,best,.init(x:nearest.x,y:nearest.y))
  }

  /// First forward boundary on the SAME local contour. Solve each cubic's
  /// signed distance to the ray between derivative extrema; no ellipse stand-in
  /// or pose-dependent tessellation can change an internal connector's anchor.
  static func outlineRayContact(_ graphic: NotebookGraphic,size: CGSize,from origin: SpatialPoint,
    toward: SpatialPoint) -> SpatialPoint? {
    guard graphic.shape != .plus else { return nil }
    let length=hypot(toward.x-origin.x,toward.y-origin.y)
    guard length.isFinite,length>0 else { return nil }
    let dx=(toward.x-origin.x)/length,dy=(toward.y-origin.y)/length
    let path=outlinePath(graphic,in:CGRect(origin:.zero,size:size))
    var current=CGPoint.zero,start=CGPoint.zero,best=Double.infinity,hasSubpath=false
    func side(_ p: CGPoint) -> Double { dx*(p.y-origin.y)-dy*(p.x-origin.x) }
    func admit(_ p: CGPoint) {
      let distance=(p.x-origin.x)*dx+(p.y-origin.y)*dy
      if distance.isFinite,distance>=0 { best=min(best,distance) }
    }
    func line(_ a: CGPoint,_ b: CGPoint) {
      let u=side(a),v=side(b)
      if u==0 { admit(a) }; if v==0 { admit(b) }
      if u==0,v==0 {
        let first=(a.x-origin.x)*dx+(a.y-origin.y)*dy,last=(b.x-origin.x)*dx+(b.y-origin.y)*dy
        if min(first,last)<=0,max(first,last)>=0 { best=0 }
      }
      guard (u<0 && v>0) || (u>0 && v<0) else { return }
      let scale=max(abs(u),abs(v)),t=(u/scale)/(u/scale-v/scale)
      admit(.init(x:a.x*(1-t)+b.x*t,y:a.y*(1-t)+b.y*t))
    }
    func extrema(_ y: [Double]) -> [Double] {
      let e=y[1]-y[0],f=y[2]-y[1],g=y[3]-y[2],qa=e-2*f+g,qb=2*(f-e),qc=e
      var splits=[0.0,1.0]
      func split(_ t: Double) { if t.isFinite,t>0,t<1 { splits.append(t) } }
      if qa==0 { if qb != 0 { split(-qc/qb) } }
      else {
        let discriminant=qb*qb-4*qa*qc
        if discriminant>=0 {
          let q = -0.5*(qb+(qb>=0 ? 1 : -1)*sqrt(discriminant))
          if q==0 { split(-qb/(2*qa)) }
          else { split(q/qa);split(qc/q) }
        }
      }
      return splits.sorted()
    }
    func cubic(_ a: CGPoint,_ b: CGPoint,_ c: CGPoint,_ d: CGPoint) {
      let raw=[side(a),side(b),side(c),side(d)],scale=raw.map(abs).max()!
      guard scale.isFinite else { return }
      if scale==0 {
        let distances=[a,b,c,d].map { ($0.x-origin.x)*dx+($0.y-origin.y)*dy }
        let ends=extrema(distances).map { t -> Double in
          let s=1-t
          return s*s*s*distances[0]+3*s*s*t*distances[1]+3*s*t*t*distances[2]+t*t*t*distances[3]
        }
        let low=ends.min()!,high=ends.max()!
        if high>=0 { best=min(best,max(0,low)) }
        return
      }
      let y=raw.map { $0/scale }
      if y.allSatisfy({ $0>0 }) || y.allSatisfy({ $0<0 }) { return }
      let splits=extrema(y)
      func value(_ t: Double) -> Double {
        let s=1-t
        return s*s*s*y[0]+3*s*s*t*y[1]+3*s*t*t*y[2]+t*t*t*y[3]
      }
      func at(_ t: Double) {
        let s=1-t
        admit(.init(x:s*s*s*a.x+3*s*s*t*b.x+3*s*t*t*c.x+t*t*t*d.x,
          y:s*s*s*a.y+3*s*s*t*b.y+3*s*t*t*c.y+t*t*t*d.y))
      }
      for t in splits where abs(value(t))<=32*Double.ulpOfOne { at(t) }
      for (lower,upper) in zip(splits,splits.dropFirst()) {
        var lo=lower,hi=upper,u=value(lo)
        let v=value(hi)
        guard (u<0 && v>0) || (u>0 && v<0) else { continue }
        for _ in 0..<60 {
          let mid=lo+(hi-lo)/2,w=value(mid)
          if w==0 { lo=mid;hi=mid;break }
          if (w<0)==(u<0) { lo=mid;u=w } else { hi=mid }
        }
        at(lo+(hi-lo)/2)
      }
    }
    path.applyWithBlock { pointer in
      let e=pointer.pointee
      switch e.type {
      case .moveToPoint:
        if hasSubpath { line(current,start) }
        current=e.points[0];start=current;hasSubpath=true
      case .addLineToPoint: line(current,e.points[0]);current=e.points[0]
      case .addQuadCurveToPoint:
        let b=e.points[0],end=e.points[1]
        cubic(current,.init(x:current.x/3+2*b.x/3,y:current.y/3+2*b.y/3),
          .init(x:end.x/3+2*b.x/3,y:end.y/3+2*b.y/3),end);current=end
      case .addCurveToPoint: cubic(current,e.points[0],e.points[1],e.points[2]);current=e.points[2]
      case .closeSubpath: line(current,start);current=start
      @unknown default: break
      }
    }
    if hasSubpath { line(current,start) } // CGPath containment also closes open subpaths.
    return best.isFinite ? .init(x:origin.x+best*dx,y:origin.y+best*dy) : nil
  }

}
