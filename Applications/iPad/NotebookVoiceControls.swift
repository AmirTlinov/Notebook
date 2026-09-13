import SwiftUI
import NotebookCore

/// An unavailable capability explains itself without changing capture, draft or
/// a remembered communication mode. Both chat presentations use the same action.
struct NotebookDictationButton: View {
  var compact = false
  @State private var explainsAvailability = false
  var body: some View {
    Button { explainsAvailability = true } label: {
      Image(systemName: "mic.slash").font(.system(size: 16)).foregroundStyle(.tertiary)
        .frame(width: 44, height: compact ? 48 : 44).contentShape(Rectangle())
    }
    .accessibilityLabel("Диктовка Codex пока недоступна").accessibilityValue("Пока недоступен")
    .accessibilityHint("Показать причину недоступности диктовки в черновик")
    .accessibilityIdentifier(compact ? "notebook-compact-dictation" : "notebook-chat-dictation")
    .popover(isPresented: $explainsAvailability) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Диктовка Codex недоступна").font(.headline)
        Text(NotebookVoiceController.dictationUnavailable).font(.callout).foregroundStyle(.secondary)
          .accessibilityIdentifier("notebook-dictation-unavailable")
        Button("Готово") { explainsAvailability = false }
          .accessibilityIdentifier("notebook-dictation-close")
      }.padding(18).frame(width: 300).fixedSize(horizontal: false, vertical: true)
        .presentationCompactAdaptation(.popover)
    }
  }
}

struct NotebookVoiceStartButton: View {
  @Bindable var chat: NotebookChatController
  var compact = false
  @State private var showsSettings = false
  var body: some View {
    Button { showsSettings = true } label: {
      Image(systemName: "waveform").font(.system(size: 16))
        .frame(width: 44, height: compact ? 48 : 44).contentShape(Rectangle())
    }.accessibilityLabel("Голосовой разговор и обращение к GPT")
      .accessibilityIdentifier(compact ? "notebook-compact-voice-settings" : "notebook-chat-voice")
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
        Button("Начать разговор сейчас", systemImage: "waveform") { close(); Task { await voice.begin() } }
          .frame(minHeight: 44).disabled(!canStart).accessibilityIdentifier("notebook-voice-begin")
        Button("Ожидать «GPT»", systemImage: "ear.badge.waveform") { close(); Task { await voice.arm() } }
          .frame(minHeight: 44).disabled(!canStart).accessibilityIdentifier("notebook-voice-arm")
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
      Text("До обращения звук остаётся на iPad. Ожидание включается только этой кнопкой и выключается вместе с микрофоном или при уходе из Notebook.")
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
