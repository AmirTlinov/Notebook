import Foundation
import Testing
@testable import NotebookCore

@Suite("Exact JSON primitives and typed ink round trips")
struct JSONValueTests {
  @Test func numbersRemainDistinctFromBooleansAndStrings() throws {
    let cases: [(String, JSONValue)] = [
      ("null", .null), ("true", .bool(true)), ("false", .bool(false)),
      ("0", .number(0)), ("1", .number(1)), ("-12.5", .number(-12.5)),
      ("1e-12", .number(1e-12)), ("9007199254740991", .number(9_007_199_254_740_991)),
      ("0.004166666666666667", .number(1.0 / 240)),
      (#""1""#, .string("1")), (#""false""#, .string("false")),
      (#""NaN""#, .string("NaN")), (#""Перо 🖊\n\u0000""#, .string("Перо 🖊\n\0")),
      ("[]", .array([])), ("{}", .object([:])),
      (#"{"values":[true,1,false,0,"1",null]}"#,
        .object(["values": .array([.bool(true), .number(1), .bool(false), .number(0), .string("1"), .null])]))
    ]
    for (source, expected) in cases {
      let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
      #expect(decoded == expected)
      #expect(try JSONValue.encode(decoded) == expected)
    }
    for source in ["NaN", "Infinity", "{\"unfinished\":"] {
      #expect(throws: (any Error).self) { try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)) }
    }
    #expect(throws: (any Error).self) { try JSONValue.encode(Double.infinity) }
  }

  @Test func numericInkRetainsEveryMeasuredValueAndCanonicalIdentity() throws {
    let actor = UUID(), surface = SurfaceID.board(UUID())
    var journal = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
    for stroke in 0..<8 {
      let samples: [SpatialInkSample] = (0..<600).map { index in
        let x = Double(index) / 3, y = Double(stroke) * 0.7
        return SpatialInkSample(point: .init(x: x, y: y), worldPoint: .init(x: x, y: y),
          timeOffset: Double(index) / 240, width: 2.5, opacity: 1,
          force: Double(index % 100) / 100, azimuth: .pi / 3, altitude: .pi / 2)
      }
      let accepted = journal.append(tool: stroke == 7 ? .eraser : .pen,
        spans: [.init(surface: surface, samples: samples)], actor: actor)
      #expect(accepted != nil)
    }
    let value = try JSONValue.encode(journal)
    let decoded = try value.decode(SpatialInkJournal.self)
    #expect(decoded == journal)
    #expect(try collaborationHash(value) == collaborationHash(JSONValue.encode(decoded)))
    let first = try #require(decoded.actions.first?.spans.first?.samples.dropFirst().first)
    #expect(first.timeOffset.bitPattern == (1.0 / 240).bitPattern)
    #expect(value["actions"]?.array.last?["isActive"] == .bool(true))
  }
}
