import NotebookCore
import SwiftUI

/// Paint and interaction consume the same measured cutout geometry.
enum NotebookElementErasurePaint {
  static func clip(_ erasures: [InkElementErasure], context: inout GraphicsContext, size: CGSize) {
    guard !erasures.isEmpty else { return }
    context.clipToLayer(options:.inverse) { mask in
      mask.fill(Path(NotebookElementAppearance.erasurePath(erasures,size:size)),with:.color(.white))
    }
  }
}

extension View {
  @ViewBuilder func erased(by erasures: [InkElementErasure]) -> some View {
    if erasures.isEmpty { self }
    else {
      mask {
        Canvas { context, size in
          NotebookElementErasurePaint.clip(erasures, context: &context, size: size)
          context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
        }
      }
    }
  }
}
