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
  @ViewBuilder func erased(by erasures: [InkElementErasure], appearance: NotebookElementAppearance? = nil,transform:NotebookGraphicTransform? = nil,layout:NotebookGraphicLayout? = nil,visibility:NotebookGraphicMask? = nil) -> some View {
    if appearance?.state == .erased || visibility?.erasesWholeRegion == true || erasures.contains(where: { $0.target.wholeElement }) {
      // Retire WebKit and its input/capture leases, not a hidden running program.
      Color.clear.allowsHitTesting(false).accessibilityHidden(true)
    }
    else {
      mask {
        // Keep the source's structural identity when Undo removes the last
        // cut. Switching between `self` and `self.mask` remounts the retained
        // handwriting body too, blanking all of it before its next drawable.
        if erasures.isEmpty && visibility?.operations.contains(where:{ $0.erasures != nil }) != true {
          Color.white
        } else {
          NotebookInkMaterialView(erasures:erasures,transform:transform,layout:layout,mask:visibility)
        }
      }
    }
  }

  /// Offscreen composition cannot capture the live Metal mask. It consumes
  /// the already prepared vector appearance from the same erasure actions.
  @ViewBuilder func snapshotErased(by erasures:[InkElementErasure],appearance:NotebookElementAppearance?,
    transform:NotebookGraphicTransform? = nil,layout:NotebookGraphicLayout? = nil)->some View {
    if erasures.isEmpty { self }
    else if appearance?.state == .erased || erasures.contains(where:{ $0.target.wholeElement }) {
      Color.clear
    } else {
      mask {
        Canvas { context,size in
          if let appearance { context.clip(to:Path(appearance.mask),options:.inverse) }
          else { NotebookElementErasurePaint.clip(erasures,context:&context,size:size,transform:transform,layout:layout) }
          context.fill(Path(CGRect(origin:.zero,size:size)),with:.color(.white))
        }
      }
    }
  }
}
