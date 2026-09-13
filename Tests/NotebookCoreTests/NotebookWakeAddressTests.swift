import Foundation
import Testing
@testable import NotebookCore

@Suite("Local address classification and source-audio boundaries")
struct NotebookWakeAddressTests {
  @Test func nameOnlyWaitsButARequestDoesNotWaitForFinalTimestamps() {
    for name in ["GPT", "Hey GPT", "Слушай GPT"] {
      #expect(NotebookWakeAddress.match(name, language: "ru-RU", address: "Слушай", settled: false) == nil)
      #expect(NotebookWakeAddress.match(name, language: "ru-RU", address: "Слушай", settled: true) == false)
      #expect(NotebookWakeAddress.match(name + " объясни", language: "ru-RU", address: "Слушай", settled: false) == true)
    }
  }
  @Test func activatedDictationRemovesOnlyTheAddressAndKeepsTheRequestVerbatim() {
    for text in ["GPT, объясни эту формулу?", "Слушай, GPT: объясни эту формулу?", "Hey GPT — объясни эту формулу?", "Хей джипити, объясни эту формулу?"] {
      #expect(NotebookWakeAddress.removingPrefix(from: text, language: "ru-RU", address: "Слушай") == "объясни эту формулу?")
    }
    for text in ["Обсудим GPT", "GPTs are models", "Что такое GPT?"] {
      #expect(NotebookWakeAddress.removingPrefix(from: text, language: "ru-RU", address: "Слушай") == text)
    }
    #expect(NotebookWakeAddress.removingPrefix(from: "GPT, -2 + 3", language: "en-US", address: "Hey") == "-2 + 3")
    #expect(NotebookWakeAddress.removingPrefix(from: "GPT", language: "en-US", address: "Hey").isEmpty)
  }
  @Test func naturalLocalAddressesAndExactRussianSpellingsOfHey() {
    for (language, phrase) in [("ru-RU", "Слушай, GPT, объясни эту формулу"), ("ru-RU", "GPT объясни формулу"),
      ("ru-RU", "Слушай джи пи ти"), ("en-US", "Hey GPT explain this formula"), ("en-US", "GPT"),
      ("es-ES", "Oye ge pe te explica esto"), ("fr-FR", "Dis GPT explique ceci"), ("de-DE", "Hey ge pe te erkläre das"),
      ("ja-JP", "ねえジーピーティー"), ("zh-CN", "嘿 GPT"), ("ko-KR", "헤이 지피티"), ("ar-SA", "يا جي بي تي"), ("hi-IN", "सुनो जी पी टी")] {
      #expect(NotebookWakeAddress.match(phrase, language: language, address: NotebookWakeAddress.localAddress(language: language), settled: true) != nil, "Missed: \(phrase)")
    }
    for text in ["Hey GPT объясни формулу", "Хей джи пи ти объясни формулу", "Хэй джипити", "Эй GPT", "GPT", "Слушай ГПТ"] {
      #expect(NotebookWakeAddress.match(text, language: "ru-RU", address: "Слушай", settled: true) != nil)
    }
    #expect(NotebookWakeAddress.match("Hey GPT", language: "ru-RU", address: "Алло", settled: true) == nil)
    #expect(NotebookWakeAddress.match("Алло GPT", language: "ru-RU", address: "Алло", settled: true) == false)
    #expect(NotebookWakeAddress.localAddress(language: "zz-ZZ").isEmpty)
    #expect(NotebookWakeAddress.phrases(language: "ru-RU", address: "Слушай").contains("Hey GPT"))
  }
  @Test func ambientMentionsPrefixesAndAgentSpeechDoNotActivate() {
    for text in ["Мы обсуждали GPT вчера", "Мне GPT помогает", "GPT это модель", "GPT является моделью", "GPTs are tools",
      "I used GPT today", "GPT is a model", "GPT was helpful", "GPT means generative pretrained transformer", "hey friend GPT",
      "Я сказал хей GPT", "Хей GPTs", "Эй друг GPT", "Слушай я хотел задать вопрос", "Ordinary conversation Hey GPT explain this"] {
      #expect(NotebookWakeAddress.match(text, language: text.first?.isASCII == true ? "en-US" : "ru-RU",
        address: text.first?.isASCII == true ? "Hey" : "Слушай", settled: true) == nil, "Accidental address: \(text)")
    }
    #expect(NotebookWakeAddress.match("Hey GPT", language: "en-US", address: "Hey", settled: true, agentSpeaking: true) == nil)
  }
  @Test func anAudioBoundaryIsAvailableBeforeRecognitionAndCannotIncludeThePreviousPhrase() {
    var stream = NotebookAcousticUtterance(), frame = 0
    func feed(_ rms: Double, _ chunks: Int) -> [NotebookAcousticUtterance.Boundary] {
      var boundaries: [NotebookAcousticUtterance.Boundary] = []
      for _ in 0..<chunks {
        if let boundary = stream.append(rms: rms, frame: frame, count: 2400, rate: 24000) { boundaries.append(boundary) }
        frame += 2400
      }
      return boundaries
    }
    #expect(feed(0.0001, 160).isEmpty, "Long waiting has no utterance and no frame-zero admission")
    #expect(feed(0.02, 4) == [.began(379200)])
    #expect(feed(0.0001, 4).isEmpty, "An intra-word pause does not create a new address boundary")
    #expect(feed(0.02, 4).isEmpty)
    #expect(feed(0.0001, 10) == [.ended])
    let next = frame
    #expect(feed(0.002, 4) == [.began(next - 4800)], "Quiet speech is not rejected by the former -44 dB gate")
    #expect(stream.start! > 384000 + 28800, "The surrounding utterance is outside the admitted window")
  }
  @Test func sustainedRoomNoiseDoesNotKeepCreatingUtterances() {
    var stream = NotebookAcousticUtterance(), starts = 0
    for index in 0..<200 {
      if case .began = stream.append(rms: 0.003, frame: index * 2400, count: 2400, rate: 24000) { starts += 1 }
    }
    #expect(starts <= 1); #expect(stream.start == nil)
    #expect(stream.append(rms: 0.04, frame: 480000, count: 2400, rate: 24000) == .began(475200))
  }
}
