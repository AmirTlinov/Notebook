import Foundation
struct Point { let x:Double; let y:Double }
func simplifiedLasso(_ points:[Point],screenScale:Double,maximum:Int=2048) -> (Int,Int,Double) {
 let started=ProcessInfo.processInfo.systemUptime
 var visits=0
 func distance(_ p:Point,_ a:Point,_ b:Point)->Double {
  let dx=b.x-a.x,dy=b.y-a.y,square=dx*dx+dy*dy
  let t=square == 0 ? 0 : min(1,max(0,((p.x-a.x)*dx+(p.y-a.y)*dy)/square))
  return hypot(p.x-a.x-t*dx,p.y-a.y-t*dy)
 }
 func reduced(_ tolerance:Double)->[Point] {
  var keep=Array(repeating:false,count:points.count);keep[0]=true;keep[points.count-1]=true
  var stack=[(0,points.count-1)]
  while let (start,end)=stack.popLast() {
   guard end > start+1 else { continue }
   var far=start,value=0.0
   for index in (start+1)..<end {
    visits+=1;let d=distance(points[index],points[start],points[end]);if d > value { value=d;far=index }
   }
   if value > tolerance { keep[far]=true;stack.append((start,far));stack.append((far,end)) }
  }
  return points.indices.filter { keep[$0] }.map { points[$0] }
 }
 var tolerance=0.5/max(screenScale,0.001),result=reduced(tolerance)
 while result.count > maximum { tolerance *= 1.5;result=reduced(tolerance) }
 return (result.count,visits,(ProcessInfo.processInfo.systemUptime-started)*1000)
}
for count in [1024,2048,4096,8192] {
 let points=(0..<count).map { Point(x:Double($0)/8,y:$0%2 == 0 ? 0 : 16) }
 let r=simplifiedLasso(points,screenScale:1)
 print("points=\(count) result=\(r.0) distance_visits=\(r.1) ms=\(r.2)")
}
struct Contact { var points:[Point] }
final class Owner {
 var contact:Contact? = Contact(points:[])
 @inline(never) func move(_ p:Point) {
  guard var current=contact else { return }
  current.points.append(p)
  contact=current
 }
}
for count in [2048,4096,8192] {
 let owner=Owner();var moved=0
 let t=ProcessInfo.processInfo.systemUptime
 for i in 0..<count {
  let prior=owner.contact!.points.withUnsafeBufferPointer { Int(bitPattern:$0.baseAddress) }
  owner.move(Point(x:Double(i),y:0))
  let after=owner.contact!.points.withUnsafeBufferPointer { Int(bitPattern:$0.baseAddress) }
  if prior != after { moved+=1 }
 }
 print("COW points=\(count) reallocations=\(moved) ms=\((ProcessInfo.processInfo.systemUptime-t)*1000)")
}
