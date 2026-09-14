import SwiftUI
import UIKit
import NotebookCore

struct NotebookDictationButton: View {
  @Bindable var chat: NotebookChatController
  var compact = false
  private var dictation: NotebookDictationController { chat.dictation }
  var body: some View {
    Menu {
      if dictation.needsAddressAuthorization {
        Button("Включить ожидание GPT", systemImage: "ear.badge.waveform") {
          dictation.setMicrophoneMuted(false)
        }.accessibilityIdentifier("notebook-dictation-enable-address")
      }
      Button(dictation.microphoneMuted ? "Включить микрофон" : "Выключить микрофон",
        systemImage: dictation.microphoneMuted ? "mic" : "mic.slash") {
          dictation.setMicrophoneMuted(!dictation.microphoneMuted)
        }.accessibilityIdentifier("notebook-microphone-mute")
    } label: {
      Image(systemName: dictation.microphoneMuted ? "mic.slash" : "mic")
        .font(.system(size: 16))
        .overlay(alignment: .bottom) {
          if dictation.waiting { Circle().fill(Color.accentColor).frame(width: 3, height: 3).offset(y: 7) }
        }
        .frame(width: 44, height: compact ? 48 : 44).contentShape(Rectangle())
    } primaryAction: {
      if dictation.microphoneMuted { dictation.setMicrophoneMuted(false) }
      else { Task { await dictation.begin() } }
    }
    .disabled(dictation.busy || chat.voice.capturing)
    .accessibilityLabel(dictation.microphoneMuted ? "Включить микрофон" : "Диктовать сообщение")
    .accessibilityValue(dictation.status.isEmpty ? "Готова" : dictation.status)
    .accessibilityHint("Нажмите для диктовки с редактируемым черновиком. Удерживайте, чтобы выключить микрофон. Обращение GPT отправляется после паузы.")
    .accessibilityIdentifier(compact ? "notebook-compact-dictation" : "notebook-chat-dictation")
    .accessibilityAction(named: dictation.microphoneMuted ? "Включить микрофон" : "Выключить микрофон") {
      dictation.setMicrophoneMuted(!dictation.microphoneMuted)
    }
  }
}

/// A failed background listener owns this notice, not the text composer's
/// controls. Dismissing it neither deletes a recording nor retries capture.
struct NotebookDictationNotice: View {
  @Bindable var dictation: NotebookDictationController
  let message: String
  static func preferredHeight(message: String, width: CGFloat) -> CGFloat {
    let font = UIFont.preferredFont(forTextStyle: .caption1)
    let textHeight = (message as NSString).boundingRect(
      with: .init(width: max(1, width - 36), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height
    return max(32, ceil(min(textHeight, font.lineHeight * 3)))
  }
  var body: some View {
    HStack(alignment: .top, spacing: 4) {
      Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("notebook-dictation-notice")
      Button { dictation.dismissNotice() } label: {
        Image(systemName: "xmark").font(.system(size: 12))
          .frame(width: 32, height: 32).contentShape(Rectangle())
      }.accessibilityLabel("Убрать уведомление о микрофоне")
        .accessibilityIdentifier("notebook-dictation-dismiss-notice")
    }
  }
}

/// Capture replaces the existing controls row, not the editable draft. Every visible bar
/// comes from the recorder's bounded meter history, including actual silence.
struct NotebookDictationInput: View {
  @Environment(NotebookAppModel.self) private var model
  @Bindable var chat: NotebookChatController
  private var dictation: NotebookDictationController { chat.dictation }
  var body: some View {
    let levels = dictation.levels
    HStack(spacing: 0) {
      Button { dictation.cancel() } label: { symbol("xmark") }
        .disabled(dictation.phase == .inserting)
        .accessibilityLabel("Отменить диктовку").accessibilityIdentifier("notebook-dictation-cancel")
      if dictation.recording {
        Image(systemName: "mic.fill").font(.system(size: 13)).foregroundStyle(Color.accentColor)
          .padding(.trailing, 6).accessibilityHidden(true)
        Canvas { context, size in
          let count = max(1, Int(size.width / 5)), samples = Array(levels.suffix(count))
          for index in 0..<count {
            let sample = index < count - samples.count ? 0 : samples[index - (count - samples.count)]
            let height = max(2, min(30, sample * 30))
            let rect = CGRect(x: CGFloat(index) * 5 + 1, y: (size.height - height) / 2, width: 2.5, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: 1.25), with: .color(.accentColor.opacity(sample > 0 ? 0.85 : 0.2)))
          }
        }.frame(minWidth: 28, maxWidth: .infinity).frame(height: 32)
          .accessibilityLabel(dictation.status).accessibilityValue("Уровень микрофона: \(Int(dictation.level * 100))")
          .accessibilityIdentifier("notebook-dictation-waveform")
        Button { model.finishDictation(sending: false) } label: { symbol("stop.fill") }
          .accessibilityLabel("Остановить и редактировать").accessibilityIdentifier("notebook-dictation-review")
        Button { model.finishDictation(sending: true) } label: { symbol("arrow.up", send: true) }
          .disabled(model.isSavingAgentQuestion || model.selectionSession.isResolvingContext || chat.continuationUnavailable)
          .accessibilityLabel("Завершить диктовку и отправить").accessibilityIdentifier("notebook-dictation-send")
      } else {
        Text(dictation.status).font(.system(size: 12)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
          .accessibilityIdentifier("notebook-dictation-status")
        if dictation.canRetry {
          Button { dictation.retry() } label: { symbol("arrow.clockwise") }
            .accessibilityLabel("Повторить распознавание").accessibilityIdentifier("notebook-dictation-retry")
        } else if dictation.error == nil { ProgressView().controlSize(.small).frame(width: 44, height: 48) }
      }
    }.padding(.horizontal, 3).frame(height: 48)
      .accessibilityElement(children: .contain).accessibilityIdentifier("notebook-dictation-input")
  }
  private func symbol(_ name: String, send: Bool = false) -> some View {
    Image(systemName: name).font(.system(size: name == "stop.fill" ? 10 : 13, weight: .medium))
      .foregroundStyle(send ? Color(.systemBackground) : Color.primary)
      .frame(width: 28, height: 28)
      .background(send ? Color(.label) : Color(.secondarySystemBackground), in: Circle())
      .frame(width: 44, height: 48).contentShape(Rectangle())
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
