import NotebookCore
import SwiftUI

/// Paint and interaction consume the same measured cutout geometry.
enum NotebookElementErasurePaint {
  static func clip(_ erasures: [InkElementErasure], context: inout GraphicsContext, size: CGSize,transform:NotebookGraphicTransform? = nil,layout:NotebookGraphicLayout? = nil) {
    guard !erasures.isEmpty else { return }
    context.clipToLayer(options:.inverse) { mask in
      mask.fill(Path(NotebookElementAppearance.measuredErasurePath(erasures,size:size,transform:transform,layout:layout)),with:.color(.white))
    }
  }
}

extension View {
  @ViewBuilder func erased(by erasures: [InkElementErasure], appearance: NotebookElementAppearance? = nil,transform:NotebookGraphicTransform? = nil,layout:NotebookGraphicLayout? = nil) -> some View {
    if erasures.isEmpty { self }
    else if appearance?.state == .erased || erasures.contains(where: { $0.target.wholeElement }) {
      // Retire WebKit and its input/capture leases, not a hidden running program.
      Color.clear.allowsHitTesting(false).accessibilityHidden(true)
    }
    else {
      mask {
        Canvas { context, size in
          if let appearance {
            context.clip(to: Path(appearance.mask), options: .inverse)
          } else {
            NotebookElementErasurePaint.clip(erasures, context: &context, size:size,transform:transform,layout:layout)
          }
          context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
        }
      }
    }
  }
}
