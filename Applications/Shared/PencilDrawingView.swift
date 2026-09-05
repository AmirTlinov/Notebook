#if os(macOS)
import SwiftUI
import NotebookCore

struct PencilDrawingView: View {
  let page: PageDocument

  var body: some View {
    if !page.drawingData.isEmpty,
       let raster = PageInkRasterCache.shared.image(for:page) {
      Image(nsImage:NSImage(cgImage:raster,size:CGSize(width:page.size.width,height:page.size.height)))
      .resizable()
    }
  }
}
#endif
