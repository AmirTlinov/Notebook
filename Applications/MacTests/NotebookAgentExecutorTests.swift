import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import NotebookCore
import XCTest
@testable import Notebook

final class NotebookAgentExecutorTests: XCTestCase {
  func testBoundedTextEventsPreserveEveryUTF8Scalar() {
    let text = String(repeating: "Человеческий смысл 👨‍👩‍👧‍👦 é — ", count: 2_000)
    let chunks = NotebookAgentExecutor.textChunks(text)
    XCTAssertGreaterThan(chunks.count, 1)
    XCTAssertEqual(chunks.joined(), text)
    XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.utf8.count <= 8192 })
  }

  func testInvalidToolGrantCannotLaunchAProcess() async {
    let executor = makeUnavailableExecutor()
    let result = await executor.run(requestID: UUID(), prompt: "Помоги с выбранным объектом", context: .null,
      tools: [.init(name: "functions.exec", description: "Not a Notebook function", inputSchema: .object(["type": .string("object")]))],
      onEvent: { _ in XCTFail("An invalid grant emitted an event") },
      callTool: { _ in XCTFail("An invalid grant invoked a tool"); return .init(value: .null) })
    XCTAssertEqual(result.status, .unavailable)
    XCTAssertEqual(result.failure, .invalidRequest)
    await executor.stop()
  }

  func testContextLimitIsCheckedBeforeStartingAnUnknownBinary() async {
    let executor = makeUnavailableExecutor()
    let result = await executor.run(requestID: UUID(), prompt: "Помоги", context: .string(String(repeating: "a", count: 1_048_577)),
      tools: [.init(name: "read", description: "An addressed Notebook read", inputSchema: .object(["type": .string("object")]))],
      onEvent: { _ in XCTFail("Oversized context emitted an event") }, callTool: { _ in .init(value: .null) })
    XCTAssertEqual(result.failure, .invalidRequest)
    await executor.stop()
  }

  func testUnknownExecutableIsUnavailableAndCancellationDoesNotInventARun() async {
    let executor = makeUnavailableExecutor()
    let availability = await executor.availability()
    XCTAssertEqual(availability, .unavailable(.unsupportedRuntime))
    let cancellation = await executor.cancel(requestID: UUID())
    XCTAssertEqual(cancellation, .notRunning)
    await executor.stop()
  }

  func testRuntimeDirectoryRejectsAnUnprotectedDirectoryAndASymbolicLink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(try NotebookAgentRuntimeProfile.privateDirectory(root))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    XCTAssertNoThrow(try NotebookAgentRuntimeProfile.privateDirectory(root))
    let link = root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    XCTAssertThrowsError(try NotebookAgentRuntimeProfile.privateDirectory(link))
  }

  func testImageIsRealBoundedPNGAndNotBase64InsideText() throws {
    let png = try makePNG()
    let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    let image = try NotebookAgentImage(png: png, sha256: hash, pixelWidth: 16, pixelHeight: 8)
    let items = try NotebookAgentToolResult(value: .object(["receipt": .string(hash)]), images: [image]).contentItems()
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items[0]["type"], .string("inputText"))
    XCTAssertEqual(items[1]["type"], .string("inputImage"))
    XCTAssertEqual(items[1]["imageUrl"], .string("data:image/png;base64," + png.base64EncodedString()))
    XCTAssertThrowsError(try NotebookAgentImage(png: png, sha256: hash, pixelWidth: 16, pixelHeight: 8, mimeType: "image/jpeg"))
    XCTAssertThrowsError(try NotebookAgentImage(png: png, sha256: String(repeating: "0", count: 64), pixelWidth: 16, pixelHeight: 8))
    XCTAssertThrowsError(try NotebookAgentImage(png: png, sha256: hash, pixelWidth: 17, pixelHeight: 8))
    XCTAssertThrowsError(try NotebookAgentImage(png: png, sha256: hash, pixelWidth: 4096, pixelHeight: 4096))
    XCTAssertThrowsError(try NotebookAgentToolResult(value: .null, images: Array(repeating: image, count: 5)).contentItems())
    let truncated = Data(png.prefix(40)), truncatedHash = SHA256.hash(data: truncated).map { String(format: "%02x", $0) }.joined()
    XCTAssertThrowsError(try NotebookAgentImage(png: truncated, sha256: truncatedHash, pixelWidth: 16, pixelHeight: 8))
  }

  func testMockLoginMessagesBindOneHandshakeAndPreserveEarlyCompletion() throws {
    var login = NotebookAgentLoginState()
    let response = JSONValue.object(["type": .string("chatgpt"), "loginId": .string("current-login"),
      "authUrl": .string("https://auth.openai.com/authorize?state=isolated-test")])
    let completion = JSONValue.object(["loginId": .string("current-login"), "success": .bool(true)])
    XCTAssertNil(login.receive(completion), "An unsolicited account notification does not sign in the helper")
    try login.begin()
    XCTAssertThrowsError(try login.begin(), "Only one explicit sign-in may own the callback")
    XCTAssertNil(login.receive(completion), "Stdio may deliver completion before the suspended RPC caller resumes")
    let accepted = try login.accept(response)
    XCTAssertEqual(accepted.completion, true)
    XCTAssertEqual(accepted.id, "current-login")
    XCTAssertEqual(accepted.url.host, "auth.openai.com")
    login.reset()
    XCTAssertFalse(login.isPending)
    XCTAssertNil(login.receive(completion), "Duplicate completion does not revive a finished login")
    try login.begin()
    XCTAssertNil(login.receive(.object(["loginId": .string("previous-login"), "success": .bool(true)])))
    let next = try login.accept(response)
    XCTAssertNil(next.completion, "A previous account cannot satisfy a newly requested sign-in")
    XCTAssertNil(login.receive(.object(["loginId": .string("previous-login"), "success": .bool(true)])))
    XCTAssertEqual(login.receive(.object(["loginId": .string("current-login"), "success": .bool(false)])), false)
    for address in ["http://auth.openai.com/login", "https://auth.openai.com.attacker.example/login",
      "https://user@auth.openai.com/login", "https://auth.openai.com:8443/login", "file:///tmp/auth"] {
      login.reset(); try login.begin()
      XCTAssertThrowsError(try login.accept(.object(["type": .string("chatgpt"), "loginId": .string("test"), "authUrl": .string(address)])))
    }
  }

  private func makePNG() throws -> Data {
    let data = Data(repeating: 42, count: 16 * 8 * 4)
    let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
    let image = try XCTUnwrap(CGImage(width: 16, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let png = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return png as Data
  }

  private func makeUnavailableExecutor() -> NotebookAgentExecutor {
    let unavailable = URL(fileURLWithPath: "/notebook-contract-no-such-executable")
    return NotebookAgentExecutor(binary: unavailable,
      runtimeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), configuration: unavailable)
  }
}
