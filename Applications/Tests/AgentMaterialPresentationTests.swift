import NotebookCore
import XCTest
@testable import Notebook

final class AgentMaterialPresentationTests: XCTestCase {
  private func material(_ html: String, css: String = "", script: String = "") -> AgentElement {
    .init(id: "drawing", kind: .web, frame: .init(x: 0, y: 0, width: 100, height: 100),
      source: "Drawing", html: html, css: css, javaScript: script)
  }

  func testPlainSVGUsesTheExistingStaticProducer() {
    let svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><defs><path id='p' d='M0 0L100 100'/></defs><use href='#p'/><text x='5' y='10'>Hello</text></svg>"
    XCTAssertFalse(material(svg).requiresLiveRuntime)
    XCTAssertTrue(material(svg, script: "notebook.ready(new Promise(()=>{}))").requiresLiveRuntime)
    XCTAssertTrue(material(svg, css: "svg{animation:spin 1s infinite}").requiresLiveRuntime)
  }

  func testControlsLinksAnimationsAndUnprovenMarkupStayLive() {
    for html in ["<button>Go</button>", "<input>", "<a href='#x'>Link</a>",
      "<svg onclick='go()'><rect/></svg>", "<svg><a href='#x'><path/></a></svg>",
      "<svg><animate attributeName='x'/></svg>", "<svg><foreignObject><input/></foreignObject></svg>",
      "<svg><script>go()</script></svg>", "<svg><style>svg{animation:spin 1s}</style></svg>",
      "<svg style='animation:spin 1s'><rect/></svg>", "<svg><use href='external.svg#p'/></svg>",
      "<svg><image href='animation.gif'/></svg>", "<svg><rect></svg>", "<div><svg/></div>",
      "<?xml-stylesheet href='animated.css'?><svg/>"] {
      XCTAssertTrue(material(html).requiresLiveRuntime, html)
    }
  }
}
