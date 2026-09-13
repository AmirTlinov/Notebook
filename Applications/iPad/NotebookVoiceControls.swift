import SwiftUI
import NotebookCore

struct NotebookDictationButton: View {
  @Bindable var chat: NotebookChatController
  var compact = false
  private var dictation: NotebookDictationController { chat.dictation }
  var body: some View {
    Button {
      if dictation.recording { dictation.finish() }
      else if dictation.canRetry { dictation.retry() }
      else { Task { await dictation.begin() } }
    } label: {
      Group {
        if dictation.busy && !dictation.recording && !dictation.canRetry { ProgressView().controlSize(.small) }
        else { Image(systemName: dictation.recording ? "stop.circle.fill" : dictation.canRetry ? "arrow.clockwise" : "mic").font(.system(size: 16)) }
      }.foregroundStyle(dictation.recording ? Color.red : Color.primary)
        .frame(width: 44, height: compact ? 48 : 44).contentShape(Rectangle())
    }
    .disabled((dictation.busy && !dictation.recording && !dictation.canRetry) || chat.voice.capturing)
    .accessibilityLabel(dictation.recording ? "Завершить диктовку" : dictation.canRetry ? "Повторить распознавание" : "Диктовать в черновик")
    .accessibilityValue(dictation.status.isEmpty ? "Готова" : dictation.status)
    .accessibilityHint("Речь появится в черновике. Отправка выполняется отдельно.")
    .accessibilityIdentifier(compact ? "notebook-compact-dictation" : "notebook-chat-dictation")
  }
}

struct NotebookDictationStatus: View {
  @Bindable var dictation: NotebookDictationController
  var body: some View {
    if dictation.busy || dictation.error != nil {
      HStack(spacing: 8) {
        if dictation.recording {
          HStack(spacing: 2) {
            ForEach(0..<5) { bar in
              Capsule().fill(.red).frame(width: 3, height: 4 + 16 * dictation.level * [0.5, 0.8, 1, 0.8, 0.5][bar])
            }
          }.frame(width: 24, height: 22).accessibilityHidden(true)
        }
        Text(dictation.status).font(.system(size: 12)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("notebook-dictation-status")
        if dictation.canRetry {
          Button { dictation.retry() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
            .accessibilityLabel("Повторить распознавание").accessibilityIdentifier("notebook-dictation-retry")
        }
        Button { dictation.cancel() } label: { Image(systemName: "xmark").font(.system(size: 12)).frame(width: 44, height: 44) }
          .disabled(dictation.phase == .inserting)
          .accessibilityLabel(dictation.pending == nil ? "Закрыть сообщение" : "Отменить диктовку и удалить запись")
          .accessibilityIdentifier("notebook-dictation-cancel")
      }.padding(.leading, 12).padding(.trailing, 3)
    }
  }
}

struct NotebookVoiceStartButton: View {
  @Bindable var chat: NotebookChatController
  var compact = false
  @State private var showsSettings = false
  var body: some View {
    Button {
      if chat.voice.capturing { showsSettings = true }
      else { Task { await chat.voice.begin() } }
    } label: {
      Image(systemName: "waveform").font(.system(size: 16))
        .frame(width: 44, height: compact ? 48 : 44).contentShape(Rectangle())
    }.accessibilityLabel(chat.voice.capturing ? "Управление голосом" : "Начать голосовой разговор")
      .disabled(chat.dictation.busy)
      .accessibilityHint("Нажмите и говорите. Удерживайте для настройки обращения к GPT.")
      .accessibilityIdentifier(compact ? "notebook-compact-voice" : "notebook-chat-voice")
      .highPriorityGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in showsSettings = true })
      .accessibilityAction(named: "Параметры голоса") { showsSettings = true }
      .popover(isPresented: $showsSettings) {
        NotebookVoiceSettings(voice: chat.voice, task: chat.taskTitle,
          canStart: chat.connected && chat.threadID != nil && !chat.browsesChats && !chat.switchingComputer) { showsSettings = false }
          .presentationCompactAdaptation(.popover)
      }
  }
}

private struct NotebookVoiceSettings: View {
  @Bindable var voice: NotebookVoiceController
  let task: String
  let canStart: Bool
  let close: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Голосовой разговор").font(.headline)
        Spacer()
        Button("Готово", action: close).accessibilityIdentifier("notebook-voice-settings-close")
      }
      Text(voice.capturing ? voice.taskTitle : task).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      if voice.capturing { NotebookVoiceControls(voice: voice) }
      else {
        Button("Включить обращение «GPT»", systemImage: "ear.badge.waveform") { close(); Task { await voice.arm() } }
          .frame(minHeight: 44).disabled(!canStart).accessibilityIdentifier("notebook-voice-wake")
        if !canStart { Text("Выберите чат и подключите Mac.").font(.caption).foregroundStyle(.secondary) }
      }
      Text(NotebookWakeAddress.examples(language: voice.language, address: voice.address) + ". Просьбу можно произнести сразу после имени.")
        .font(.caption).foregroundStyle(.secondary)
      DisclosureGroup("Язык и обращение") {
        Picker("Язык обращения", selection: $voice.language) {
          ForEach(NotebookWakeRecognizer.languages, id: \.self) { language in
            Text(Locale.current.localizedString(forIdentifier: language) ?? language).tag(language)
          }
        }.disabled(voice.capturing)
        TextField("Местное обращение перед GPT", text: $voice.address).textFieldStyle(.roundedBorder).disabled(voice.capturing)
      }.font(.callout)
      Text("Кнопка голоса в чате сразу начинает разговор. Ожидание имени включается отдельно здесь: до обращения звук остаётся на iPad. Выключение микрофона или уход из Notebook прекращает ожидание.")
        .font(.caption2).foregroundStyle(.secondary)
    }.padding(18).frame(width: 330).fixedSize(horizontal: false, vertical: true)
  }
}

struct NotebookVoiceControls: View {
  @Bindable var voice: NotebookVoiceController
  @State private var showingText = false
  var body: some View {
    if voice.capturing {
      HStack(spacing: 8) {
        NotebookVoiceOrb(phase: voice.phase).frame(width: 20, height: 20)
        Text(voice.status).font(.caption).lineLimit(2)
        Spacer(minLength: 0)
        Button { Task { await voice.mute() } } label: { Image(systemName: voice.muted ? "mic.fill" : "mic.slash").frame(width: 44,height: 44).contentShape(Rectangle()) }
          .accessibilityLabel(voice.muted ? "Включить микрофон" : "Выключить микрофон").disabled(voice.ending || voice.changingMute)
        if voice.activeID != nil {
        Button { Task { await voice.toggleSpeaker() } } label: { Image(systemName: voice.speakerMuted ? "speaker.slash" : "speaker.wave.2").frame(width: 40, height: 44).contentShape(Rectangle()) }
          .accessibilityLabel(voice.speakerMuted ? "Включить звук GPT" : "Выключить звук GPT").disabled(voice.ending || voice.changingSpeaker)
        Button { showingText = true } label: { Image(systemName: "text.bubble").frame(width: 36, height: 44).contentShape(Rectangle()) }
          .accessibilityLabel("Текст голосового разговора")
        Button { Task { await voice.end() } } label: { Image(systemName: "phone.down.fill").foregroundStyle(.red).frame(width: 44,height: 44).contentShape(Rectangle()) }
          .accessibilityLabel("Завершить голосовой разговор").disabled(voice.ending)
        }
      }.padding(.leading,12)
        .popover(isPresented: $showingText) {
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              Text(voice.taskTitle).font(.headline)
              if let text = voice.state?.userText, !text.isEmpty { Text(text).foregroundStyle(.secondary) }
              if let text = voice.state?.assistantText, !text.isEmpty { Text(text) }
              Button("Готово") { showingText = false }
            }.textSelection(.enabled).padding(18)
          }.frame(width: 310, height: 260).presentationCompactAdaptation(.popover)
        }
    }
  }
}
