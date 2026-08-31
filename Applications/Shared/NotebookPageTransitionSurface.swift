import NotebookCore
import SwiftUI

/// Keeps the live page mounted once and adds only transient readouts around it.
/// PageMotionController supplies every curl coordinate; Metal cannot settle or
/// commit a page by itself.
struct NotebookPageTransitionSurface: View {
  @Environment(\.displayScale) private var displayScale

  let page: PageDocument
  let previousPage: PageDocument?
  let nextPage: PageDocument?
  let departingPage: PageDocument?
  let pageMotion: PageMotionController
  let isInteractive: Bool
  let isVisible: Bool

  @State private var preparedRevision = 0

  var body: some View {
    ZStack {
      rail
        .opacity(materialImages == nil ? 1 : 0)

      if let materialImages {
        NotebookPageCurlMetalSurface(
          textureKey: materialImages.key,
          baseImage: materialImages.base,
          movingImage: materialImages.moving,
          projection: materialImages.projection,
          gripY: pageMotion.gripY
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .accessibilityIdentifier("physical-page-curl")
      }
    }
    .frame(
      width: NotebookGeometry.width,
      height: NotebookGeometry.height
    )
    .clipShape(
      RoundedRectangle(
        cornerRadius: NotebookGeometry.cornerRadius,
        style: .continuous
      )
    )
    .transaction { transaction in
      transaction.animation = nil
    }
    .task(id: textureRequest) {
      await prepareTextures()
    }
  }

  private var rail: some View {
    ZStack {
      if pageMotion.presentation == .dissolve {
        if let departingPage {
          PageReadoutSurface(
            page: departingPage,
            fallbackSize: page.size
          )
          .opacity(dissolveOutgoingOpacity)
        }
      } else {
        if let previousPage {
          PageReadoutSurface(
            page: previousPage,
            fallbackSize: page.size
          )
          .overlay(alignment: .trailing) {
            sheetEdgeShadow(trailing: true)
          }
          .offset(x: (pageMotion.position - 1) * NotebookGeometry.width)
        }

        PageReadoutSurface(
          page: nextPage,
          fallbackSize: page.size
        )
        .overlay(alignment: .leading) {
          sheetEdgeShadow(trailing: false)
        }
        .offset(x: (pageMotion.position + 1) * NotebookGeometry.width)
      }

      PageSurface(
        page: page,
        isInteractive: isInteractive,
        isVisible: isVisible
      )
      .allowsHitTesting(isInteractive)
      .offset(
        x: pageMotion.presentation == .dissolve
          ? 0
          : pageMotion.position * NotebookGeometry.width
      )
      .opacity(
        pageMotion.presentation == .dissolve
          ? dissolveIncomingOpacity
          : 1
      )
    }
  }

  private var materialImages: PageCurlMaterialImages? {
    _ = preparedRevision
    guard pageMotion.presentation == .rail,
      pageMotion.isActive,
      PageCurlMetalSupport.isAvailable,
      let projection = PageCurlProjection.resolve(
        position: pageMotion.position,
        hasPrevious: previousPage != nil,
        hasNext: true
      ),
      let base = texture(for: projection.base),
      let moving = texture(for: projection.moving)
    else { return nil }

    return PageCurlMaterialImages(
      key: "\(descriptor(for: projection.base).cacheKey)->\(descriptor(for: projection.moving).cacheKey)",
      base: base,
      moving: moving,
      projection: projection
    )
  }

  private func texture(for slot: PageCurlProjection.TextureSlot) -> CGImage? {
    PageCurlTextureCache.shared.image(
      for: page(for: slot),
      fallbackSize: page.size,
      scale: textureScale
    )
  }

  private func descriptor(
    for slot: PageCurlProjection.TextureSlot
  ) -> PageCurlTextureDescriptor {
    PageCurlTextureDescriptor(
      page: page(for: slot),
      fallbackSize: page.size,
      scale: textureScale
    )
  }

  private func page(
    for slot: PageCurlProjection.TextureSlot
  ) -> PageDocument? {
    switch slot {
    case .previous: previousPage
    case .current: page
    case .next: nextPage
    }
  }

  private var textureScale: CGFloat {
    min(2, max(1, displayScale))
  }

  private var textureRequest: PageCurlTextureRequest {
    PageCurlTextureRequest(
      previous: PageCurlTextureDescriptor(
        page: previousPage,
        fallbackSize: page.size,
        scale: textureScale
      ),
      current: PageCurlTextureDescriptor(
        page: page,
        fallbackSize: page.size,
        scale: textureScale
      ),
      next: PageCurlTextureDescriptor(
        page: nextPage,
        fallbackSize: page.size,
        scale: textureScale
      )
    )
  }

  private func prepareTextures() async {
    let cache = PageCurlTextureCache.shared
    await cache.prepare(
      page: page,
      fallbackSize: page.size,
      scale: textureScale
    )
    guard !Task.isCancelled else { return }
    await cache.prepare(
      page: nextPage,
      fallbackSize: page.size,
      scale: textureScale
    )
    guard !Task.isCancelled else { return }
    if let previousPage {
      await cache.prepare(
        page: previousPage,
        fallbackSize: page.size,
        scale: textureScale
      )
    }
    guard !Task.isCancelled else { return }
    preparedRevision &+= 1
  }

  private func sheetEdgeShadow(trailing: Bool) -> some View {
    LinearGradient(
      colors: trailing
        ? [.clear, .black.opacity(0.11)]
        : [.black.opacity(0.11), .clear],
      startPoint: .leading,
      endPoint: .trailing
    )
    .frame(width: 14)
    .opacity(min(1, abs(pageMotion.position) * 1.8))
    .allowsHitTesting(false)
  }

  private var dissolveOutgoingOpacity: Double {
    Double(max(0, 1 - pageMotion.dissolveProgress))
  }

  private var dissolveIncomingOpacity: Double {
    Double(max(0, pageMotion.dissolveProgress))
  }
}

private struct PageCurlTextureRequest: Hashable {
  let previous: PageCurlTextureDescriptor
  let current: PageCurlTextureDescriptor
  let next: PageCurlTextureDescriptor
}

private struct PageCurlMaterialImages {
  let key: String
  let base: CGImage
  let moving: CGImage
  let projection: PageCurlProjection
}
