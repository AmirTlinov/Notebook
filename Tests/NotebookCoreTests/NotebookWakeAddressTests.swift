import Foundation
import Testing
@testable import NotebookCore

@Suite("Local addresses: missed calls and accidental activations are separate contracts")
struct NotebookWakeAddressTests {
  func words(_ text: String, start: Double = 0) -> [NotebookWakeAddress.Segment] {
    text.split(separator: " ").enumerated().map { .init(String($0.element), start: start + Double($0.offset) * 0.2, duration: 0.18) }
  }
  @Test func addressedRequestsAndShortNameKeepTheBeginningOfTheSameUtterance() {
    for (language, phrase) in [("ru-RU", "Слушай, GPT, объясни эту формулу"), ("ru-RU", "GPT объясни формулу"),
      ("ru-RU", "Слушай джи пи ти"), ("en-US", "Hey GPT explain this formula"), ("en-US", "GPT"),
      ("es-ES", "Oye ge pe te explica esto"), ("fr-FR", "Dis GPT explique ceci"), ("de-DE", "Hey ge pe te erkläre das"),
      ("ja-JP", "ねえジーピーティー"), ("zh-CN", "嘿 GPT"), ("ko-KR", "헤이 지피티"), ("ar-SA", "يا جي بي تي"), ("hi-IN", "सुनो जी पी टी")] {
      #expect(NotebookWakeAddress.start(in: words(phrase, start: 2), language: language,
        address: NotebookWakeAddress.localAddress(language: language), settled: true) == 2, "Missed address: \(phrase)")
    }
    #expect(NotebookWakeAddress.localAddress(language: "zz-ZZ").isEmpty, "An unknown locale is not forced to say Hey")
    #expect(NotebookWakeAddress.start(in: words("Hei GPT"), language: "fi-FI", address: "Hei", settled: true) == 0)
  }
  @Test func mentionInsideSpeechOrAgentOutputDoesNotCallTheAgent() {
    for text in ["Мы обсуждали GPT вчера", "Мне GPT помогает", "GPT это модель", "GPT является моделью", "GPTs are tools",
      "I used GPT today", "GPT is a model", "GPT was helpful", "GPT means generative pretrained transformer", "hey friend GPT"] {
      #expect(NotebookWakeAddress.start(in: words(text), language: text.first?.isASCII == true ? "en-US" : "ru-RU",
        address: text.first?.isASCII == true ? "Hey" : "Слушай", settled: true) == nil, "Accidental address: \(text)")
    }
    #expect(NotebookWakeAddress.start(in: words("Hey GPT"), language: "en-US", address: "Hey", settled: true, agentSpeaking: true) == nil)
    #expect(NotebookWakeAddress.start(in: words("GPT"), language: "en-US", address: "Hey", settled: false) == nil)
  }
  @Test func aNewAddressAfterSilenceExcludesTheEarlierAmbientConversation() {
    let input = words("Ordinary conversation") + words("Hey GPT explain this", start: 3)
    #expect(NotebookWakeAddress.start(in: input, language: "en-US", address: "Hey", settled: false) == 3)
    #expect(NotebookWakeAddress.start(in: words("Ordinary conversation Hey GPT explain this"), language: "en-US", address: "Hey", settled: true) == nil)
  }
  @Test func streamingSpellingCannotAdmitAudioUntilSpeechSuppliesItsLocation() {
    // The on-device recognizer emits these zero-timed hypotheses on real audio,
    // including an early combined segment before its final word boundaries.
    for text in ["Слушай GPT", "Слушай GPT GPT", "GPT объясни формулу"] {
      let partial = [NotebookWakeAddress.Segment(text, start: 0, duration: 0)]
      #expect(NotebookWakeAddress.start(in: partial, language: "ru-RU", address: "Слушай", settled: false) == nil)
      #expect(NotebookWakeAddress.start(in: partial, language: "ru-RU", address: "Слушай", settled: true) == nil,
        "A debounce cannot turn an unknown audio location into frame zero")
    }
    let located = [NotebookWakeAddress.Segment("Слушай", start: 16, duration: 0.63),
      .init("GPT", start: 16.75, duration: 0.93), .init("объясни", start: 17.8, duration: 0.57)]
    #expect(NotebookWakeAddress.start(in: located, language: "ru-RU", address: "Слушай", settled: false) == 16)
    for invalid in [Double.nan, .infinity, -1] {
      #expect(NotebookWakeAddress.start(in: [.init("GPT", start: invalid, duration: 0.4)], language: "en-US", address: "Hey", settled: true) == nil)
    }
  }
  @Test func aTimedSegmentCanContainTheAddressAndTheWholeRequest() {
    for phrase in ["Hey GPT explain des former", "Хэй джипити объясни эту формулу", "Слушай GPT объясни формулу", "GPT объясни формулу"] {
      #expect(NotebookWakeAddress.start(in: [.init(phrase, start: 0.96, duration: 2.55)], language: "ru-RU", address: "Слушай", settled: false) == 0.96)
    }
    for phrase in ["Hey GPTs explain this", "Мы обсуждали GPT вчера", "GPT это модель", "Слушай я хотел задать вопрос"] {
      #expect(NotebookWakeAddress.start(in: [.init(phrase, start: 0.96, duration: 2.55)], language: "ru-RU", address: "Слушай", settled: true) == nil)
    }
  }
  @Test func russianRecognizerAcceptsEnglishAddressWithoutChangingTheSelectedLanguage() {
    for text in ["Hey GPT объясни формулу", "Хей джи пи ти объясни формулу", "Хэй джипити", "Эй GPT", "GPT", "Слушай ГПТ"] {
      #expect(NotebookWakeAddress.start(in: words(text, start: 1), language: "ru-RU", address: "Слушай", settled: true) == 1, "Missed address: \(text)")
    }
    for text in ["Я сказал хей GPT", "Хей GPTs", "Эй друг GPT", "GPT это пример", "Привет GPT"] {
      #expect(NotebookWakeAddress.start(in: words(text), language: "ru-RU", address: "Слушай", settled: true) == nil, "Accidental activation: \(text)")
    }
    #expect(NotebookWakeAddress.start(in: words("Хей GPT"), language: "ru-RU", address: "Слушай", settled: true, agentSpeaking: true) == nil)
    #expect(NotebookWakeAddress.phrases(language: "ru-RU", address: "Слушай").contains("Hey GPT"))
    #expect(NotebookWakeAddress.examples(language: "ru-RU", address: "Слушай") == "Слушай, GPT · Hey, GPT · GPT")
    #expect(NotebookWakeAddress.start(in: words("Hey GPT"), language: "ru-RU", address: "Алло", settled: true) == nil, "An explicit custom address is not replaced")
    #expect(NotebookWakeAddress.start(in: words("Алло GPT"), language: "ru-RU", address: "Алло", settled: true) == 0)
  }
}
