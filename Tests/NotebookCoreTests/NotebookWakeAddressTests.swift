import Foundation
import Testing
@testable import NotebookCore

@Suite("Local addresses: missed calls and accidental activations are separate contracts")
struct NotebookWakeAddressTests {
  func words(_ text: String, start: Double = 0) -> [NotebookWakeAddress.Word] {
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
}
