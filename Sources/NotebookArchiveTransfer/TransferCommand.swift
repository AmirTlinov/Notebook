import Foundation
import NotebookCore

@main
struct TransferCommand {
  static func main() {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      if args.count == 4, args[0] == "--prepare-computer", args[2] == "--output",
        args[1].hasPrefix("/"), args[3].hasPrefix("/") {
        let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        guard data.count <= 16_384 else { throw ArchiveTransferError.invalidSource("computer request is too large") }
        let report = try ArchiveComputerPreparation.prepare(JSONDecoder().decode(ArchiveComputerRequest.self, from: data), output: URL(fileURLWithPath: args[3]))
        print("Independent current-workspace Mac prepared: \(report.manifest.target.actorID). Existing devices and trust are unchanged.")
        print("Collect the new Mac activation receipt, admit it, then explicitly pair it with the current iPad.")
        return
      }
      if args.count == 5, args[0] == "--admit-computer", args[3] == "--output", [1, 2, 4].allSatisfy({ args[$0].hasPrefix("/") }) {
        let reportData = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let receiptData = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        guard reportData.count <= 256 * 1024 * 1024, receiptData.count <= 16_384 else { throw ArchiveTransferError.invalidSource("invalid computer receipt") }
        let report = try JSONDecoder().decode(ArchiveComputerReport.self, from: reportData)
        let receipt = try JSONDecoder().decode(NotebookArchiveActivationReceipt.self, from: receiptData)
        try report.source.publishAdmission(receipt: receipt, manifest: report.manifest, at: URL(fileURLWithPath: args[4]))
        print("Admission prepared ONLY for the new Mac. Do not replace either existing device's admission or trust.")
        return
      }
      if args.count == 4, args[0] == "--prepare-pair", args[2] == "--output",
        args[1].hasPrefix("/"), args[3].hasPrefix("/") {
        let input = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        guard input.count <= 16_384 else { throw ArchiveTransferError.invalidSource("pair request is too large") }
        let request = try JSONDecoder().decode(ArchivePairRequest.self, from: input)
        let report = try ArchivePairPreparation.prepare(request, output: URL(fileURLWithPath: args[3]))
        print("Verified pair payload: \(report.transitionID). Shared records: \(report.iPadManifest.content.sharedRecordsSHA256).")
        print("Applications are unchanged. Activation and two real device receipts are still required.")
        return
      }
      if args.count == 5, args[0] == "--prepare-installation-pairing", args[3] == "--output",
        [1, 2, 4].allSatisfy({ args[$0].hasPrefix("/") }) {
        let receipts = try [args[1], args[2]].map { path -> NotebookArchiveActivationReceipt in
          let data = try Data(contentsOf: URL(fileURLWithPath: path))
          guard data.count <= 16_384 else { throw ArchiveTransferError.invalidSource("activation receipt is too large") }
          return try JSONDecoder().decode(NotebookArchiveActivationReceipt.self, from: data)
        }
        let grant = try NotebookInstallationPairingGrant(admission: .init(receipts: receipts))
        let destination = URL(fileURLWithPath: args[4])
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ArchiveTransferError.invalidSource("pairing grant already exists") }
        try grant.publish(at: destination)
        print("Installation pairing prepared for the two activated devices. Deliver privately over authenticated USB; never publish the credential.")
        return
      }
      if args.count == 5, args[0] == "--admit-pair", args[3] == "--output",
        [1, 2, 4].allSatisfy({ args[$0].hasPrefix("/") }) {
        let destination = URL(fileURLWithPath: args[4])
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ArchiveTransferError.invalidSource("admission output already exists") }
        let receipts = try [args[1], args[2]].map { path -> NotebookArchiveActivationReceipt in
          let data = try Data(contentsOf: URL(fileURLWithPath: path))
          guard data.count <= 16_384 else { throw ArchiveTransferError.invalidSource("activation receipt is too large") }
          return try JSONDecoder().decode(NotebookArchiveActivationReceipt.self, from: data)
        }
        let admission = try NotebookArchiveAdmission(receipts: receipts)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(admission).write(to: destination, options: .withoutOverwriting)
        print("Matching activation receipts validated. Copy this admission to each verified application control directory.")
        return
      }
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
        throw ArchiveTransferError.invalidSource("Usage: notebook-archive-transfer --prepare-computer ABSOLUTE_CURRENT_IPAD_REQUEST --output NEW_ABSOLUTE_DIRECTORY\nOr: --admit-computer ABSOLUTE_REPORT ABSOLUTE_NEW_MAC_RECEIPT --output NEW_ABSOLUTE_JSON\nOr: --source ABSOLUTE_BACKUP --output NEW_ABSOLUTE_DIRECTORY --workspace-id UUID\nOr: --legacy-ipad ABSOLUTE_BACKUP --legacy-mac ABSOLUTE_BACKUP --current ABSOLUTE_BACKUP --output NEW_ABSOLUTE_DIRECTORY\nOr: --prepare-pair ABSOLUTE_REQUEST_JSON --output NEW_ABSOLUTE_DIRECTORY\nOr: --admit-pair ABSOLUTE_IPAD_RECEIPT ABSOLUTE_MAC_RECEIPT --output NEW_ABSOLUTE_JSON\nOr: --prepare-installation-pairing ABSOLUTE_IPAD_RECEIPT ABSOLUTE_MAC_RECEIPT --output NEW_ABSOLUTE_JSON\nPrepares offline data only. Does not stop, replace, pair, or install applications.")
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
