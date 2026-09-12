#if os(iOS)
import Foundation
import Observation
import NotebookCore

/// Window-space document state. No board navigation or presence writer is
/// reachable from this controller; closing a document only hides its view.
@MainActor @Observable
final class NotebookFileController {
  private(set) var window = NotebookFileWindowState()
  private(set) var document: NotebookFileDraft?
  private(set) var directories: [NotebookFileAddress: NotebookFileDirectory] = [:]
  private(set) var expandedFolders = Set<NotebookFileAddress>()
  private(set) var error: String?
  private(set) var notice: String?
  private(set) var loading = false
  private(set) var saving = false
  var remoteAvailable: Bool { chat?.connected == true && document?.address.computer == chat?.computerID }
  let notes: NotebookCodeAnnotations
  private(set) var navigation: (id: UUID, file: NotebookFileAddress, range: NSRange)?
  @ObservationIgnored var captureSelection: (@MainActor () -> NotebookCodeFragment?)?
  @ObservationIgnored weak var chat: NotebookChatController?
  @ObservationIgnored private let persistence: NotebookPersistenceQueue
  @ObservationIgnored private let author: UUID
  @ObservationIgnored private var opening: UUID?
  @ObservationIgnored private var poll: Task<Void, Never>?
  @ObservationIgnored private var upload: Task<Void, Never>?
  @ObservationIgnored private var integrating = Set<UUID>()
  @ObservationIgnored private var loaded = false
  @ObservationIgnored private var stopped = false

  init(persistence: NotebookPersistenceQueue, author: UUID) { self.persistence = persistence; self.author = author; notes = .init(persistence: persistence, author: author) }
  func start() async throws {
    try await restoreWindow()
    loaded = true
    poll = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(3)) } catch { break }
        guard let self else { return }
        if let pending = document?.pending, let job = chat?.jobs.first(where: { $0.id == pending }), chat?.connected == true { receive(job) }
        else if window.isOpen, !loading, !saving, !notes.contactActive, chat?.connected == true { await refresh() }
        if window.isOpen { await notes.refresh() }
      }
    }
  }
  func suspendForComputerSwitch() async {
    opening = nil; loading = false; upload?.cancel(); await upload?.value
  }
  func restoreWindow() async throws {
    let author = author, computer = chat?.computerID
    let saved = try await persistence.submit { store in
      try store.readTransaction { store in
        let window = try store.fileWindow(author: author, computer: computer)
        return (window, try window.selected.flatMap { try store.fileDraft($0) })
      }
    }
    guard chat?.computerID == computer else { return }
    await installWindow(saved.0, document: saved.1)
  }
  func installWindow(_ state: NotebookFileWindowState, document: NotebookFileDraft?) async {
    window = state; self.document = document; directories = [:]; expandedFolders = []; navigation = nil; error = nil; notice = nil
    await notes.select(document?.address)
  }
  func stop() async {
    stopped = true; notes.stop(); opening = nil
    poll?.cancel(); upload?.cancel()
    await poll?.value; await upload?.value
    poll = nil; upload = nil
  }
  func chooseProject(_ project: CodexProject?) {
    window.project = project; directories = [:]; expandedFolders = []; persistWindow()
    if window.sidebar { Task { await roots() } }
  }
  func toggleTerminal() { window.terminal = !(window.terminal ?? false); persistWindow() }
  func chooseRunRoot(_ root: String) { window.runRoot = root; persistWindow() }
  func toggleSidebar() { window.sidebar.toggle(); persistWindow(); if window.sidebar { Task { await roots() } } }
  func roots() async {
    guard let computer = chat?.computerID, let project = window.project else { return }
    for root in project.roots { await expand(.init(computer: computer, project: project.id, root: root, path: "")) }
  }
  func expand(_ address: NotebookFileAddress, more: Bool = false) async {
    expandedFolders.insert(address)
    do {
      guard case .directory(let page) = try await query(.directory(address, after: more ? directories[address]?.next : nil)) else { throw NotebookTransportError.invalidAcknowledgement }
      guard address.computer == chat?.computerID, address.project == window.project?.id else { return }
      if more, let previous = directories[address] {
        directories[address] = .init(entries: previous.entries + page.entries.filter { entry in !previous.entries.contains { $0.name == entry.name } }, next: page.next)
      } else { directories[address] = page }
      error = nil
    } catch { self.error = error.localizedDescription }
  }
  func collapse(_ address: NotebookFileAddress) { expandedFolders.remove(address) }
  func open(_ address: NotebookFileAddress) async {
    guard !stopped else { return }
    if let chat, chat.computerID != address.computer, chat.computers.contains(where: { $0.deviceID == address.computer }) {
      await chat.chooseComputer(address.computer)
      guard chat.computerID == address.computer else { return }
    }
    if document?.address == address { window.isOpen = true; persistWindow(); return }
    guard !notes.contactActive else { return }
    let token = UUID(); opening = token; loading = true
    defer { if opening == token { loading = false } }
    do {
      var value = try await persistence.submit { try $0.fileDraft(address) }
      if value == nil { value = NotebookFileDraft(address: address, text: try await read(address)) }
      guard !stopped, !notes.contactActive, opening == token, let value else { return }
      document = value; window.selected = address; window.isOpen = true; error = nil
      persistDocument(); persistWindow(); await notes.select(address)
      if let id = value.pending, let job = chat?.jobs.first(where: { $0.id == id }) { receive(job) }
    } catch { if opening == token { self.error = error.localizedDescription } }
  }
  func close() { guard !notes.contactActive else { return }; window.isOpen = false; opening = nil; loading = false; persistWindow() }
  func navigate(to fragment: NotebookCodeFragment) async {
    await open(fragment.currentFile)
    guard !notes.contactActive else { return }
    if let document, document.address == fragment.currentFile, let range = fragment.range(in: document.text) {
      navigation = (UUID(), fragment.currentFile, range)
      notes.reviewed = nil
    } else { await notes.review(fragment) }
  }
  func navigate(to file: NotebookFileAddress, line: Int) async {
    await open(file)
    guard !notes.contactActive, let document, document.address == file else { return }
    let text = document.text as NSString
    var offset = 0
    for _ in 1..<line {
      guard offset < text.length else { break }
      offset = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
    }
    navigation = (UUID(), file, NSRange(location: offset, length: 0))
  }
  func edit(_ text: String, address: NotebookFileAddress, selection: Int, scroll: Double) {
    guard !stopped, !notes.contactActive, var value = document, value.address == address else { return }
    guard text.utf8.count <= NotebookFileVersion.maximumBytes else { error = "Черновик превышает 2 МиБ. Последний принятый текст сохранён."; return }
    value.text = text; value.selection = min(max(0, selection), text.utf16.count); value.scroll = max(0, scroll)
    document = value; persistDocument()
  }
  func readPosition(address: NotebookFileAddress, selection: Int, scroll: Double) {
    guard !stopped, var value = document, value.address == address, scroll.isFinite else { return }
    value.selection = min(max(0, selection), value.text.utf16.count); value.scroll = max(0, scroll)
    if value != document { document = value; persistDocument() }
  }
  func refresh() async {
    guard !stopped, !notes.contactActive, let value = document, value.pending == nil else { return }
    do {
      let text = try await read(value.address, unchanged: value.other ?? value.base)
      guard !stopped, !notes.contactActive, document?.address == value.address, document?.pending == nil else { return }
      error = nil
      if text != document?.base, text != document?.other {
        document?.receive(text); notice = document?.other == nil ? "Файл обновлён на Mac" : "Есть несовместимые правки. Обе версии сохранены."
        persistDocument()
      }
    } catch { self.error = error.localizedDescription }
  }
  func resolveUsingMac() { guard !notes.contactActive, let other = document?.other else { return }; document?.text = other; document?.base = other; document?.other = nil; document?.selection = 0; notice = nil; persistDocument() }
  /// The person deliberately keeps their edited resolution against this exact
  /// observed version. A newer Mac change still goes through the same merge.
  func resolveUsingDraft() { guard !notes.contactActive, let other = document?.other else { return }; document?.base = other; document?.other = nil; notice = nil; persistDocument() }

  func save() {
    guard !stopped, !notes.contactActive, !saving, let value = document, value.pending == nil, value.other == nil, value.text != value.base else { return }
    saving = true; error = nil
    upload = Task { [weak self] in
      guard let self else { return }; defer { saving = false; upload = nil }
      do {
        let id = UUID(), payload = try JSONEncoder().encode(NotebookFileEdit(address: value.address, base: value.base, text: value.text))
        let digest = NotebookFileVersion.hash(payload)
        var offset = 0
        while offset < payload.count {
          try Task.checkCancellation()
          let chunk = payload.subdata(in: offset..<min(payload.count, offset + NotebookFileVersion.chunkBytes))
          guard case .uploaded(let received) = try await query(.upload(.init(id: id, digest: digest, total: payload.count, offset: offset, data: chunk))), received == offset + chunk.count else { throw NotebookTransportError.invalidAcknowledgement }
          offset = received
        }
        try Task.checkCancellation()
        // Do not bind an older asynchronous save to a newly opened document.
        var draft = document?.address == value.address ? document! : try await persistence.submit { try $0.fileDraft(value.address) ?? value }
        draft.pending = id; draft.submitted = value.text
        let input = NotebookChatInput(id: id, author: author, action: .saveFile(value.address))
        let savedDraft = draft
        _ = try await persistence.submit { try $0.saveFileSubmission(input, draft: savedDraft) }
        if document?.address == value.address {
          // Text typed during the database wait is newer than savedDraft.
          document?.pending = id; document?.submitted = value.text; persistDocument()
        }
        await chat?.refreshFileJobs(); notice = "Черновик отправлен · ожидается запись на Mac"
      } catch { self.error = error.localizedDescription }
    }
  }
  func receive(_ job: NotebookChatJob) {
    guard !stopped, !notes.contactActive, case .saveFile(let address) = job.input.action, job.isTerminal, integrating.insert(job.id).inserted else { return }
    Task { [weak self] in
      guard let self else { return }; defer { integrating.remove(job.id) }
      do {
        guard let saved = try await persistence.submit({ try $0.fileDraft(address) }), saved.pending == job.id else { return }
        let remote: String?
        if case .file(let result) = job.result { remote = try await read(address, version: result.version) } else { remote = nil }
        guard !notes.contactActive else { return }
        var current = document?.address == address ? document! : try await persistence.submit { try $0.fileDraft(address) ?? saved }
        guard current.pending == job.id else { return }
        if let remote, case .file(let result) = job.result {
          if result.status == .conflict { current.other = remote }
          else { current.receive(remote, submitted: current.submitted) }
        }
        current.pending = nil; current.submitted = nil
        let accepted = current
        // Enqueue before yielding so later native typing cannot be overwritten
        // by a stale receipt callback returning from persistence.
        if document?.address == address { document = current; persistDocument(); error = job.error; notice = job.error ?? (current.other == nil ? "Сохранено на Mac" : "Конфликт · обе версии сохранены") }
        else { try await persistence.submit { try $0.saveFileDraft(accepted) } }
      } catch { self.error = error.localizedDescription }
    }
  }
  private func read(_ address: NotebookFileAddress, version: NotebookFileVersion? = nil, unchanged: String? = nil) async throws -> String {
    var expected = version, bytes = Data()
    repeat {
      guard case .part(let part) = try await query(.read(address, version: expected, offset: bytes.count)), part.offset == bytes.count,
        part.version.isValid, expected == nil || part.version == expected, part.data.count <= NotebookFileVersion.chunkBytes,
        bytes.count + part.data.count <= part.version.size, !part.data.isEmpty || part.version.size == 0 else { throw NotebookTransportError.invalidAcknowledgement }
      if let unchanged, part.version == NotebookFileVersion(Data(unchanged.utf8)) { return unchanged }
      expected = part.version; bytes.append(part.data)
    } while bytes.count < expected!.size
    guard NotebookFileVersion(bytes) == expected, let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else { throw NotebookTransportError.invalidAcknowledgement }
    return text
  }
  private func query(_ value: NotebookFileQuery) async throws -> NotebookFileReply {
    guard let chat, value.address == nil || value.address?.computer == chat.computerID else { throw NotebookTransportError.disconnected }
    return try await chat.fileQuery(value)
  }
  private func persistDocument() {
    guard !stopped, let value = document else { return }
    persistence.enqueue(owner: .fileDraft(value.address.id), publishesChanges: false) { try $0.saveFileDraft(value); return false }
  }
  private func persistWindow() {
    guard !stopped, loaded else { return }
    let value = window, author = author, computer = chat?.computerID
    persistence.enqueue(owner: .fileWindow(computer), publishesChanges: false) { try $0.saveFileWindow(value, author: author, computer: computer); return false }
  }
}
#endif
