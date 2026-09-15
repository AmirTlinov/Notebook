import CoreGraphics

/// WebKit publishes input areas in its own layout coordinates. The native
/// projection converts the first contact; camera movement never rewrites this
/// map or uses WebKit's accessibility frames. Accepted contacts stay frozen in
/// NotebookInputGate until they end.
enum AgentWebFingerInput: String {
  case scene, link, input
}

struct AgentWebFingerRegions {
  let revision: Int
  let size: CGSize
  let regions: [(CGRect, AgentWebFingerInput)]

  init?(_ value: Any) {
    guard let object = value as? [String: Any], let revision = object["revision"] as? Int, revision >= 0,
      let width = object["width"] as? Double,
      let height = object["height"] as? Double, width.isFinite, height.isFinite,
      width > 0, height > 0, let entries = object["regions"] as? [[String: Any]],
      entries.count <= 2_048 else { return nil }
    self.revision = revision
    size = .init(width: width, height: height)
    var decoded: [(CGRect, AgentWebFingerInput)] = []
    for entry in entries {
      guard let kind = (entry["kind"] as? String).flatMap(AgentWebFingerInput.init(rawValue:)),
        let x = entry["x"] as? Double, let y = entry["y"] as? Double,
        let w = entry["width"] as? Double, let h = entry["height"] as? Double,
        [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else { return nil }
      decoded.append((.init(x: x, y: y, width: w, height: h), kind))
    }
    regions = decoded
  }

  func input(at point: CGPoint, in size: CGSize) -> AgentWebFingerInput {
    // A resized browser must publish its new layout before yielding a contact.
    guard size.width > 0, size.height > 0,
      abs(size.width - self.size.width) <= 1, abs(size.height - self.size.height) <= 1 else { return .input }
    let point = CGPoint(x: point.x * self.size.width / size.width, y: point.y * self.size.height / size.height)
    let hits = regions.filter { $0.0.contains(point) }
    if hits.contains(where: { $0.1 == .input }) { return .input }
    return hits.contains(where: { $0.1 == .link }) ? .link : .scene
  }

  /// Installed after Notebook's own bridge listeners and before authored code.
  /// Track actual input listener targets, not the presence of arbitrary script:
  /// resize/typesetting/state code does not own a finger. The wrappers preserve
  /// listener identity, capture, once and AbortSignal removal.
  static let script = #"""
    (() => {
      const types = new Set(['click','dblclick','contextmenu','pointerdown','pointermove','pointerup',
        'pointercancel','touchstart','touchmove','touchend','touchcancel','mousedown','mousemove','mouseup']);
      const targets = new WeakMap();
      const add = EventTarget.prototype.addEventListener, remove = EventTarget.prototype.removeEventListener;
      let started = false, queued = false, previous = '', observed = new Set(), revision = 0;
      const changed = () => {
        if (!started || queued) return;
        queued = true;
        queueMicrotask(() => { queued = false; publish(); });
      };
      EventTarget.prototype.addEventListener = function(type, listener, options) {
        if (!types.has(type) || !listener) return add.call(this, type, listener, options);
        const capture = typeof options === 'boolean' ? options : !!options?.capture;
        const entries = targets.get(this) || [];
        const existing = entries.find(e => e.type === type && e.listener === listener && e.capture === capture);
        if (existing) return add.call(this, type, existing.wrapped, options);
        const target = this, entry = {type, listener, capture, once:!!options?.once, signal: options?.signal};
        const forget = () => {
          const i = entries.indexOf(entry); if (i >= 0) entries.splice(i, 1);
          if (entry.signal) remove.call(entry.signal, 'abort', forget);
          changed();
        };
        entry.forget = forget;
        entry.wrapped = function(event) {
          if (entry.once) forget();
          if (typeof listener === 'function') return listener.call(this, event);
          return listener.handleEvent(event);
        };
        add.call(target, type, entry.wrapped, options);
        if (entry.signal?.aborted) return;
        entries.push(entry); targets.set(target, entries);
        if (entry.signal) add.call(entry.signal, 'abort', forget, {once:true});
        changed();
      };
      EventTarget.prototype.removeEventListener = function(type, listener, options) {
        const capture = typeof options === 'boolean' ? options : !!options?.capture;
        const entries = targets.get(this);
        const i = entries?.findIndex(e => e.type === type && e.listener === listener && e.capture === capture) ?? -1;
        if (i < 0) return remove.call(this, type, listener, options);
        const entry = entries[i];
        remove.call(this, type, entry.wrapped, options); entry.forget();
      };
      // Assigning element.onclick does not mutate an HTML attribute. Keep the
      // same native property semantics while notifying this layout boundary.
      for (const prototype of [Window.prototype, Document.prototype, HTMLElement.prototype, SVGElement.prototype]) {
        for (const type of types) {
          const name = 'on' + type, descriptor = Object.getOwnPropertyDescriptor(prototype, name);
          if (!descriptor?.set || !descriptor.configurable) continue;
          Object.defineProperty(prototype, name, {...descriptor, set(value) {
            descriptor.set.call(this, value); changed();
          }});
        }
      }
      const handlesInput = node => (targets.get(node) || []).some(e => !e.signal?.aborted)
        || [...types].some(type => typeof node['on' + type] === 'function');
      const controls = 'button,input,textarea,select,details,summary,audio[controls],video[controls],iframe,object,embed,[tabindex]:not([tabindex="-1"]),[contenteditable]:not([contenteditable="false"])';
      const kind = node => {
        if (handlesInput(node)) return 'input';
        if (!(node instanceof Element)) return 'scene';
        if (node.matches(controls)) return 'input';
        if ([...node.attributes].some(a => ['begin','end'].includes(a.name)
          && /(?:click|mouse|pointer|touch|key|focus|activate)/i.test(a.value))) return 'input';
        if (getComputedStyle(node).touchAction === 'none') return 'input';
        return node.matches('a,area') ? 'link' : 'scene';
      };
      const resize = new ResizeObserver(changed);
      const snapshot = () => {
        const regions = [], next = new Set();
        if (handlesInput(window) || handlesInput(document))
          regions.push({kind:'input', x:0, y:0, width:innerWidth, height:innerHeight});
        for (const node of document.querySelectorAll('*')) {
          const input = kind(node);
          if (input === 'scene') continue;
          const style = getComputedStyle(node);
          if (style.visibility === 'hidden' || style.display === 'none' || style.pointerEvents === 'none') continue;
          // An SVG animation's input belongs to its rendered parent.
          const target = node.matches('animate,animateTransform,set') ? node.parentElement : node;
          if (!target) continue;
          next.add(target);
          // An inline anchor's own line box may exclude its replaced image.
          // Its rendered descendants still belong to the link's tap target.
          const boxes = [target, ...(input === 'link' ? target.querySelectorAll('*') : [])];
          for (const rect of boxes.flatMap(box => [...box.getClientRects()])) {
            const x = Math.max(0, rect.x), y = Math.max(0, rect.y);
            const width = Math.min(innerWidth, rect.right) - x, height = Math.min(innerHeight, rect.bottom) - y;
            if (width > 0 && height > 0) regions.push({kind:input,x,y,width,height});
          }
        }
        for (const node of observed) if (!next.has(node)) resize.unobserve(node);
        for (const node of next) if (!observed.has(node)) resize.observe(node);
        observed = next;
        return {width:innerWidth, height:innerHeight, regions};
      };
      const publish = () => {
        const value = snapshot(), signature = JSON.stringify(value);
        if (signature === previous) return;
        previous = signature;
        window.webkit.messageHandlers.notebook.postMessage({token:notebookLoadToken,kind:'fingerRegions',value:{...value,revision:++revision}});
      };
      window.notebookFingerInput = Object.freeze({
        forEvent(event) {
          const path = event.composedPath();
          if (path.some(node => kind(node) === 'input')) return 'input';
          return path.some(node => kind(node) === 'link') ? 'link' : 'scene';
        },
        start() {
          started = true;
          new MutationObserver(changed).observe(document.documentElement, {subtree:true,childList:true,attributes:true,characterData:true});
          resize.observe(document.documentElement);
          add.call(window, 'resize', changed);
          const value = snapshot(); previous = JSON.stringify(value); return {...value,revision:++revision};
        }
      });
    })();
    """#
}
