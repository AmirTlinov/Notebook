import Foundation
import Testing
@testable import NotebookCore

struct InkElementContactTests {
  private func sample(_ x: Double, _ y: Double, origin: WorldPoint? = nil) -> SpatialInkSample {
    .init(point:.init(x:x,y:y),worldPoint:origin?.offsetBy(x:x,y:y),timeOffset:0,
      width:12,opacity:1,force:1,azimuth:0,altitude:1)
  }
  private func source() -> InkSampleRelations.Contact { .init(header:.init(tool:.eraser,color:.black)) }

  @Test func correctedSuffixRetractsOnlyItsOwnHitsAndKeepsSweptContact() {
    let targets = (0..<4).map { InkElementTarget(elementID:"\($0)",
      frame:.init(x:Double($0)*100,y:100,width:20,height:20),wholeElement:true) }
    var contact = InkElementContact(targets), measured = source()
    measured.replaceTail(from:0,with:[sample(0,110),sample(100,110),sample(200,110)])
    contact.update(measured,from:0)
    #expect(!contact.isEmpty)
    #expect(contact.selected == Array(targets.prefix(3)))
    measured.replaceTail(from:2,with:[sample(100,0)])
    contact.update(measured,from:2)
    #expect(contact.selected == Array(targets.prefix(2)))
    measured.replaceTail(from:1,with:[sample(300,110)])
    contact.update(measured,from:1)
    #expect(contact.selected == targets, "The new crossing includes its preceding sample")
    measured.replaceTail(from:0,with:[sample(0,0)])
    contact.update(measured,from:0)
    #expect(contact.isEmpty)
    #expect(contact.selected.isEmpty)
  }

  @Test func incrementalSelectionMatchesFullOracleAcrossFarWorldOrigins() {
    let origin = WorldPoint(tileX:8_000_000_000_000_000,tileY:-8_000_000_000_000_000,localX:1,localY:2)
    let targets = (0..<100).map { i in InkElementTarget(elementID:"\(i)",
      frame:.init(x:0,y:0,width:40,height:40),worldOrigin:origin.offsetBy(x:Double(i)*70,y:100),wholeElement:i%2==0) }
    var contact = InkElementContact(targets), measured = source()
    for i in 0..<300 {
      let start=measured.count
      measured.replaceTail(from:start,with:[sample(Double(i)*24,100+sin(Double(i))*100,origin:origin)])
      contact.update(measured,from:start)
    }
    #expect(contact.selected == targets.filter { $0.intersects(measured.decoded()) })
  }

  @Test func hundredThousandTargetsDoNotMultiplyEveryNewSampleByTheWholeScene() {
    let targets = (0..<100_000).map { i in InkElementTarget(elementID:"\(i)",
      frame:.init(x:Double(i%1000)*40,y:Double(i/1000)*40,width:10,height:10)) }
    var contact = InkElementContact(targets), measured = source()
    for i in 0..<2400 {
      let start=measured.count
      measured.replaceTail(from:start,with:[sample(20+Double(i%10)/10,20)])
      contact.update(measured,from:start)
    }
    #expect(contact.isEmpty)
    #expect(contact.selected.isEmpty)
    #expect(contact.testedSegments == 0)
    #expect(contact.visitedNodes < 2400*100)
    let before = contact.visitedNodes
    measured.replaceTail(from:2400,with:[sample(20,20)])
    contact.update(measured,from:2400)
    #expect(contact.visitedNodes-before < 100, "The 2401st point never rescans the prefix")
  }

  @Test func retainedSceneCandidatesAccumulateAndCorrectWithoutASecondIndex() {
    let first = InkElementTarget(elementID:"first",frame:.init(x:90,y:90,width:20,height:20),wholeElement:true)
    let second = InkElementTarget(elementID:"second",frame:.init(x:190,y:90,width:20,height:20),wholeElement:true)
    var contact=InkElementContact([]),measured=source()
    measured.replaceTail(from:0,with:[sample(0,100),sample(100,100)])
    contact.update(measured,from:0,queried:[first],visitedNodes:7)
    #expect(!contact.isEmpty)
    #expect(contact.selected == [first])
    measured.replaceTail(from:2,with:[sample(200,100)])
    contact.update(measured,from:2,queried:[second],visitedNodes:5)
    #expect(contact.selected == [first,second])
    #expect(contact.visitedNodes == 12)
    measured.replaceTail(from:1,with:[sample(0,0)])
    contact.update(measured,from:1,queried:[],visitedNodes:1)
    #expect(contact.isEmpty)
    #expect(contact.selected.isEmpty, "A corrected suffix retracts hits without retaining all queried targets")
  }
}

struct InkMeasurementsPrefixTests {
  @Test func prefixSkipsSharedContactAndFindsCorrectedMeasurement() {
    var contact=InkSampleRelations.Contact(header:.init(tool:.eraser,color:.black))
    let points=(0..<100_000).map { i in SpatialInkSample(point:.init(x:Double(i%700),y:Double(i%313)),
      timeOffset:Double(i)/240,width:12,opacity:1,force:1,azimuth:0,altitude:1) }
    contact.replaceTail(from:0,with:points)
    let initial=contact.frozen().measurements
    contact.replaceTail(from:contact.count,with:[points[0]])
    #expect(contact.frozen().measurements.unchangedPrefix(comparedTo:initial) == points.count)
    contact.replaceTail(from:70_001,with:[points[0]])
    #expect(contact.frozen().measurements.unchangedPrefix(comparedTo:initial) == 70_001)
    #expect(InkMeasurements([]).unchangedPrefix(comparedTo:initial) == 0)
  }
}
