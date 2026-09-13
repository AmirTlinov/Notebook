import Foundation

/// A local address detector, not an authorization parser or a dictation service.
/// It returns the beginning of an addressed utterance, never a permission decision.
public enum NotebookWakeAddress {
  public static func localAddress(language: String) -> String {
    switch language.prefix(2) {
    case "ru": "Слушай"; case "en": "Hey"; case "es": "Oye"; case "fr": "Dis"
    case "de": "Hey"; case "it": "Ehi"; case "pt": "Ei"; case "nl": "Hé"
    case "ja": "ねえ"; case "zh": "嘿"; case "ko": "헤이"; case "ar": "يا"
    case "tr": "Hey"; case "uk": "Слухай"; case "hi": "सुनो"
    case "ca": "Ei"; case "cs", "da", "hr", "pl", "sk", "sv": "Hej"
    case "fi", "nb", "no", "ro": "Hei"; case "el": "Γεια"; case "he": "היי"
    case "hu": "Helló"; case "id", "ms": "Hai"; case "th": "เฮ้"; case "vi": "Này"
    default: ""
    }
  }
  public static func names(language: String) -> [String] {
    let local: [String]
    switch language.prefix(2) {
    case "ru", "uk": local = ["джи пи ти", "джипити", "гпт"]
    case "es": local = ["ge pe te", "ye pe te"]
    case "fr": local = ["gé pé té", "ji pi ti"]
    case "de": local = ["ge pe te", "dschi pi ti"]
    case "it", "id", "ms": local = ["gi pi ti", "ji pi ti"]
    case "pt": local = ["gê pê tê", "jê pê tê"]
    case "nl", "fi", "sv", "da", "nb", "no": local = ["gee pee tee", "ge pe te"]
    case "he": local = ["ג׳י פי טי", "ג'י פי טי"]
    case "el": local = ["τζι πι τι"]
    case "pl": local = ["dżi pi ti"]
    case "cs", "sk": local = ["dží pí tí"]
    case "th": local = ["จีพีที"]
    case "ja": local = ["ジーピーティー"]
    case "zh": local = ["吉皮提"]
    case "ko": local = ["지피티"]
    case "ar": local = ["جي بي تي"]
    case "hi": local = ["जी पी टी"]
    default: local = []
    }
    return ["GPT", "G P T"] + local
  }
  public static func examples(language: String, address: String) -> String {
    var values = address.isEmpty ? [String]() : [address + ", GPT"]
    if language.prefix(2) == "ru", fold(address) == fold(localAddress(language: language)) { values.append("Hey, GPT") }
    return (values + ["GPT"]).joined(separator: " · ")
  }
  /// Names and addresses share one vocabulary with the local speech recognizer.
  /// Russian recognition can spell the English address phonetically; these are
  /// exact alternatives, not fuzzy matches of surrounding conversation.
  public static func phrases(language: String, address: String) -> [String] {
    let names = names(language: language)
    var addresses = address.isEmpty ? [String]() : [address]
    if language.prefix(2) == "ru", fold(address) == fold(localAddress(language: language)) {
      addresses += ["Hey", "Хей", "Хэй", "Эй"]
    }
    return names + addresses.flatMap { prefix in names.map { prefix + " " + $0 } }
  }
  /// Classification has no authority over audio position. The caller supplies one
  /// acoustically delimited utterance, never a rolling ambient transcript.
  public static func match(_ utterance: String, language: String, address: String, settled: Bool, agentSpeaking: Bool = false) -> Bool? {
    guard !agentSpeaking else { return nil }
    let text = fold(utterance)
    var boundaryOffsets = Set<Int>(), offset = 0
    for token in utterance.components(separatedBy: CharacterSet.alphanumerics.inverted) where !token.isEmpty {
      offset += fold(token).count; boundaryOffsets.insert(offset)
    }
    let names = names(language: language).map(fold)
    let candidates = phrases(language: language, address: address).map { phrase in
      let name = fold(phrase)
      return (name: name, prefixed: !names.contains(name))
    }
    for candidate in candidates.sorted(by: { $0.name.count > $1.name.count }) where text.hasPrefix(candidate.name) {
      let rest = String(text.dropFirst(candidate.name.count))
      // A name-only partial must settle before it can admit the next phrase.
      if rest.isEmpty && !settled { continue }
      if !candidate.prefixed && ["это", "этот", "был", "является", "означает", "is", "was", "means", "standsfor", "est", "ist", "esun", "esuna"].contains(where: { rest.hasPrefix($0) }) { continue }
      // Word boundaries belong to the text, not the recognizer's segmentation:
      // it can return "Hey GPT explain this" as a single timed segment.
      if !boundaryOffsets.contains(candidate.name.count) && !["ja", "zh", "ko"].contains(String(language.prefix(2))) { continue }
      return !rest.isEmpty
    }
    return nil
  }
  /// Only an already voice-activated recording uses this projection. The local
  /// detector never supplies the dictation text: Codex still transcribes it.
  public static func removingPrefix(from text: String, language: String, address: String) -> String {
    let normalized = fold(text)
    for phrase in phrases(language: language, address: address).map(fold).sorted(by: { $0.count > $1.count }) where normalized.hasPrefix(phrase) {
      var count = 0
      for index in text.indices {
        count += fold(String(text[index])).count
        guard count == phrase.count else { if count > phrase.count { break }; continue }
        let end = text.index(after: index)
        if end < text.endIndex, text[end].isLetter || text[end].isNumber,
          !["ja", "zh", "ko"].contains(String(language.prefix(2))) { break }
        let separators = CharacterSet(charactersIn: " \n\t\r,.:;!?—–")
        return String(text[end...].drop(while: { $0.unicodeScalars.allSatisfy { separators.contains($0) } }))
      }
    }
    return text
  }
  private static func fold(_ text: String) -> String {
    String(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
  }
}
