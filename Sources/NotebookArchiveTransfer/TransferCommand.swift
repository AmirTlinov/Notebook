import Foundation

@main
struct TransferCommand {
  static func main() {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      guard args.count == 6, args[0] == "--source", args[2] == "--output", args[4] == "--workspace-id",
        let id = UUID(uuidString: args[5]), args[1].hasPrefix("/"), args[3].hasPrefix("/") else {
        throw ArchiveTransferError.invalidSource("Usage: notebook-archive-transfer --source ABSOLUTE_BACKUP --output NEW_ABSOLUTE_DIRECTORY --workspace-id UUID\nPrepares an offline checkpoint. Does not stop, replace, pair, or install applications.")
      }
      let report = try ArchiveTransfer.prepare(source: URL(fileURLWithPath: args[1]),
        destination: URL(fileURLWithPath: args[3]), workspaceID: id)
      print("Verified offline checkpoint: \(report.checkpoint.checkpointSHA256)")
      print("Pages: \(report.checkpoint.pageCount); spatial actions: \(report.checkpoint.spatialActionCount).")
      print("Accepted-input quiescence is NOT proven. Installed applications are unchanged.")
    } catch {
      FileHandle.standardError.write(Data("Archive transfer refused: \(error)\n".utf8))
      exit(1)
    }
  }
}
