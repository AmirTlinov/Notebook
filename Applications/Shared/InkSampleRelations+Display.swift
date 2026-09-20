import NotebookCore

extension InkSampleRelations {
  /// GPU approximation only. Keeping an ordered exact description is distinct
  /// from reducing its display matrix; failure to compose exactly retains frames.
  var displayAffine: InkAffine {
    var a = InkAffine()
    for frame in frames {
      let x = SIMD4<Float>(Float(frame.a.value),Float(frame.c.value),Float(frame.x.value),0)
      let y = SIMD4<Float>(Float(frame.b.value),Float(frame.d.value),Float(frame.y.value),0)
      a = .init(x:.init(x.x*a.x.x+x.y*a.y.x,x.x*a.x.y+x.y*a.y.y,x.x*a.x.z+x.y*a.y.z+x.z,0),
        y:.init(y.x*a.x.x+y.y*a.y.x,y.x*a.x.y+y.y*a.y.y,y.x*a.x.z+y.y*a.y.z+y.z,0))
    }
    return a
  }
}
