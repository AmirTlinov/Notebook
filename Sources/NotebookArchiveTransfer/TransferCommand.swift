import Foundation

@main
struct TransferCommand {
  static func main() {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      if args.count == 8, args[0] == "--legacy-ipad", args[2] == "--legacy-mac",
        args[4] == "--current", args[6] == "--output", [1, 3, 5, 7].allSatisfy({ args[$0].hasPrefix("/") }) {
        let report = try ArchiveConsolidation.prepare(legacyIPad: URL(fileURLWithPath: args[1]),
          legacyMac: URL(fileURLWithPath: args[3]), current: URL(fileURLWithPath: args[5]),
          destination: URL(fileURLWithPath: args[7]))
        print("Verified offline consolidation: \(report.combinedContentSHA256)")
        print("Items: \(report.itemCount); pages: \(report.pageCount); documents: \(report.documentCount); spatial actions: \(report.spatialActionCount).")
        print("Existing protected records retained unchanged: \(report.retainedCurrentRecordCount).")
        print("Accepted-input quiescence is NOT proven. Installed applications are unchanged.")
        return
      }
      guard args.count == 6, args[0] == "--source", args[2] == "--output", args[4] == "--workspace-id",
        let id = UUID(uuidString: args[5]), args[1].hasPrefix("/"), args[3].hasPrefix("/") else {
        throw ArchiveTransferError.invalidSource("Usage: notebook-archive-transfer --source ABSOLUTE_BACKUP --output NEW_ABSOLUTE_DIRECTORY --workspace-id UUID\nOr: --legacy-ipad ABSOLUTE_BACKUP --legacy-mac ABSOLUTE_BACKUP --current ABSOLUTE_BACKUP --output NEW_ABSOLUTE_DIRECTORY\nPrepares an offline archive. Does not stop, replace, pair, or install applications.")
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
