import NotebookCore
import SwiftUI

struct NotebookGuideSettingsView: View {
  @Environment(NotebookAppModel.self) private var model
  var body: some View {
    VStack(alignment:.leading,spacing:10) {
      HStack(spacing:4) {
        ForEach(NotebookGuideKind.allCases,id:\.self) { kind in
          Button { model.drawingTools.selectGuide(kind) } label: {
            VStack(spacing:4) { Image(systemName:kind.symbol); Text(kind.title).font(.caption2) }
              .frame(maxWidth:.infinity,minHeight:44)
              .background(model.drawingTools.guideKind == kind ? NotebookChrome.selectionSurface : .clear,in:RoundedRectangle(cornerRadius:8))
          }.accessibilityIdentifier("guide-kind-"+kind.rawValue)
        }
      }
      if let guide=model.drawingTools.guide {
        value("Угол",path:\.angle,value:guide.angle,range:-180...180,unit:"°",id:"guide-angle")
        if guide.kind == .protractor {
          value("Между сторонами",path:\.openingAngle,value:guide.openingAngle,range:0.1...180,unit:"°",id:"guide-opening")
        }
        value(guide.kind == .ruler ? "Длина" : "Радиус",path:\.length,
          value:guide.length/PhysicalPaper.pointsPerCentimeter,range:0.1...50,unit:"см",id:"guide-length",factor:PhysicalPaper.pointsPerCentimeter)
        if guide.kind == .ruler {
          Toggle("Привязка длины к сетке",isOn:Binding(get:{ guide.snapToGrid },set:{ enabled in
            var next=guide;next.snapToGrid=enabled;model.drawingTools.updateGuide(next)
          })).accessibilityIdentifier("guide-grid")
        }
      }
      Button(model.drawingTools.guideEnabled ? "Убрать направляющую" : "Показать направляющую") { model.drawingTools.toggleGuide() }
        .frame(minHeight:44).accessibilityIdentifier("guide-toggle")
      Text("Пальцем — положение и ручки. Pencil рисует вдоль края выбранным пером или маркером.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
  private func value(_ title: String, path: WritableKeyPath<NotebookDrawingGuide,Double>, value: Double,
    range: ClosedRange<Double>, unit: String, id: String, factor: Double = 1) -> some View {
    let binding=Binding(get:{ model.drawingTools.guide.map { $0[keyPath:path]/factor } ?? value },set:{ value in
      guard value.isFinite, var next=model.drawingTools.guide else { return }
      next[keyPath:path]=min(range.upperBound,max(range.lowerBound,value))*factor
      model.drawingTools.updateGuide(next)
    })
    return VStack(alignment:.leading,spacing:2) {
      HStack {
        Text(title); Spacer()
        TextField(title,value:binding,format:.number.precision(.fractionLength(0...1)))
          .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(width:64)
          .accessibilityIdentifier(id+"-value")
        Text(unit).foregroundStyle(.secondary)
      }.font(.caption)
      Slider(value:binding,in:range,step:0.1).accessibilityLabel(title).accessibilityIdentifier(id)
    }
  }
}
