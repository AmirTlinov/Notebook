import AppKit
import PencilKit

func strokePoint(
  x: CGFloat,
  timeOffset: TimeInterval,
  width: CGFloat
) -> PKStrokePoint {
  PKStrokePoint(
    location: CGPoint(x: x, y: 100),
    timeOffset: timeOffset,
    size: CGSize(width: width, height: width),
    opacity: 1,
    force: 1,
    azimuth: 0,
    altitude: .pi / 2
  )
}

let sourcePath = PKStrokePath(
  controlPoints: stride(from: 0.0, through: 200.0, by: 25.0)
    .enumerated()
    .map { index, x in
      strokePoint(
        x: x,
        timeOffset: Double(index) * 0.05,
        width: 4
      )
    },
  creationDate: Date()
)
let drawing = PKDrawing(strokes: [
  PKStroke(
    ink: PKInk(.pen, color: .black),
    path: sourcePath
  )
])
func erase(width: CGFloat) -> PKDrawing {
  let eraserPath = PKStrokePath(
    controlPoints: [strokePoint(x: 100, timeOffset: 0, width: width)],
    creationDate: Date()
  )
  return drawing.erasingPath(eraserPath)
}

let erased = erase(width: 12)
let widelyErased = erase(width: 30)
let pieces = erased.strokes.sorted { $0.renderBounds.minX < $1.renderBounds.minX }
let widePieces = widelyErased.strokes.sorted {
  $0.renderBounds.minX < $1.renderBounds.minX
}

guard erased.strokes.count == 2,
  widelyErased.strokes.count == 2,
  erased.bounds.minX < 20,
  erased.bounds.maxX > 180,
  widePieces[0].renderBounds.maxX < pieces[0].renderBounds.maxX,
  widePieces[1].renderBounds.minX > pieces[1].renderBounds.minX
else {
  fatalError("Ластик должен локально расширять вырез по заданной толщине")
}

print("PencilKit: ластик сохранил края штриха и расширил вырез по толщине.")
