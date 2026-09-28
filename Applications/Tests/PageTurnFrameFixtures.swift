import CoreImage
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

/// Synthetic test sheets explicitly publish pixels, just like production
/// paper owners. No test depends on a hidden UIKit hierarchy capture fallback.
@MainActor enum PageTurnFrameFixture {
  static func frame(_ image: CGImage, size: CGSize? = nil, scale: Double = 1) async throws -> PageTurnFrame {
    let size = size ?? CGSize(width: image.width, height: image.height)
    return try await PageTurnFrame.compose(size: size, scale: scale,
      images: [.init(image: image, frame: CGRect(origin: .zero, size: size))])
  }
  static func solid(_ color: UIColor = .white, size: CGSize = .init(width: 300, height: 400), scale: Double = 1) async throws -> PageTurnFrame {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: .init(width: 4, height: 4), format: format).image { context in
      color.setFill(); context.fill(.init(x: 0, y: 0, width: 4, height: 4))
    }.cgImage!
    return try await frame(image, size: size, scale: scale)
  }
  static func artwork(index: Int, size: CGSize) async throws -> PageTurnFrame {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
      (index == 0 ? UIColor.blue : UIColor.red).setFill()
      context.fill(CGRect(x: (size.width - 400) / 2, y: (size.height - 400) / 2, width: 400, height: 400))
    }.cgImage!
    return try await frame(image, size: size)
  }
  static func install(on controller: IPadCoverOpeningController) {
    controller.prepareMaterial = { _, revision, scale in
      try await solid(.red, size: .init(width: revision.geometry.width, height: revision.geometry.height), scale: scale)
    }
  }
  static func install(on controller: IPadSheetCurlController) {
    // Renderer-only fixtures explicitly supply the operation owner. Product
    // execution receives it from IPadPageTurnController, never a native fallback.
    var operations: [UUID: (source: UIViewController, gesture: Bool, completion: ((Bool) -> Void)?)] = [:]
    controller.beginOperation = { source, _, gesture, completion in
      let id = UUID(); operations[id] = (source, gesture, completion); return id
    }
    controller.resolveOperation = { [weak controller] id, outcome, presented, notify in
      guard let operation = operations.removeValue(forKey: id) else { return }
      let completed = outcome == .completed
      controller?.resolveMotion(id, completed: completed, presented: presented)
      operation.completion?(completed)
      if notify, operation.gesture { controller?.didTurn(operation.source, completed) }
    }
    controller.acquireSheetFrame = { [weak controller] sheet in
      let size = controller?.view.bounds.size ?? .init(width: 300, height: 400)
      return try await solid(sheet.view.backgroundColor ?? .white, size: size)
    }
  }
  /// Logic tests admit the same native operation as a gesture, then report an
  /// endpoint explicitly. Physical UX tests let the renderer report its OS cut.
  static func begin(on owner: IPadPageTurnController, target: UIViewController,
    direction: IPadSheetCurlController.Direction = .forward) throws -> UUID {
    let native = owner.sheetController
    native.loadViewIfNeeded()
    if native.view.bounds.isEmpty { native.view.frame = .init(x: 0, y: 0, width: 300, height: 400) }
    let accept = native.beginOperation
    var operationID: UUID?
    native.beginOperation = { source, target, gesture, completion in
      let id = accept(source, target, gesture, completion); operationID = id; return id
    }
    defer { native.beginOperation = accept }
    XCTAssertTrue(native.beginInteractiveTurn(direction: direction, target: target))
    return try XCTUnwrap(operationID)
  }
  static func finish(on owner: IPadPageTurnController, operation: UUID, completed: Bool) {
    owner.sheetController.resolveOperation(operation, completed ? .completed : .cancelled, false, true)
  }
  static func image(_ frame: PageTurnFrame) -> CGImage? {
    guard let image = CIImage(mtlTexture: frame.texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]) else { return nil }
    let flipped = image.transformed(by: CGAffineTransform(translationX: 0, y: Double(frame.texture.height)).scaledBy(x: 1, y: -1))
    return CIContext().createCGImage(flipped, from: flipped.extent)
  }
}

extension PageTurnReadiness {
  func installTestFrame(color: UIColor = .white) { setFrameProvider { _ in try await PageTurnFrameFixture.solid(color) } }
}
