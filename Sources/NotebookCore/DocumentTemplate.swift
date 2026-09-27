import Foundation

/// Templates create ordinary editable source files, not a renderer mode.
public enum DocumentTemplate: String, Codable, CaseIterable, Sendable {
  case article, report, contract, instruction, book
  public var entrypoint: String { "main.tex" }
  public var title: String {
    switch self {
    case .article: "Статья"
    case .report: "Отчёт"
    case .contract: "Договор"
    case .instruction: "Инструкция"
    case .book: "Книга"
    }
  }
  public var files: [DocumentFile] {
    let documentClass = self == .book ? "book" : self == .report ? "report" : "article"
    let body: String
    switch self {
    case .article: body = "\\maketitle\n\\section{Введение}\nНачните статью здесь."
    case .report: body = "\\maketitle\n\\tableofcontents\n\\chapter{Резюме}\nНачните отчёт здесь."
    case .contract: body = "\\maketitle\n\\section{Стороны}\nСтороны настоящего договора.\n\\section{Условия}\nУсловия договора.\n\\section{Подписи}\n\\vspace{2cm}"
    case .instruction: body = "\\maketitle\n\\section{Начало работы}\n\\begin{enumerate}\n\\item Первый шаг.\n\\item Следующий шаг.\n\\end{enumerate}"
    case .book: body = "\\maketitle\n\\tableofcontents\n\\include{chapters/introduction}"
    }
    let main = """
      \\documentclass[11pt]{\(documentClass)}
      \\usepackage{fontspec}
      \\setmainfont{Libertinus Serif}
      \\usepackage[margin=25mm]{geometry}
      \\usepackage{graphicx}
      \\usepackage{hyperref}
      \\usepackage{notebook}
      \\title{\(title)}
      \\author{}
      \\date{}
      \\begin{document}
      \(body)
      \\end{document}

      """
    var files = [DocumentFile(id: "main", path: entrypoint, source: main)]
    if self == .book {
      files.append(.init(id: "introduction", path: "chapters/introduction.tex", source: "\\chapter{Введение}\nНачните книгу здесь.\n"))
    }
    return files
  }
}
