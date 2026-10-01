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
      const types = ['click','dblclick','contextmenu','pointerdown','pointermove','pointerup',
        'pointercancel','touchstart','touchmove','touchend','touchcancel','mousedown','mousemove','mouseup'];
      const inputTypes = new Set(types);
      const targets = new WeakMap();
      const add = EventTarget.prototype.addEventListener, remove = EventTarget.prototype.removeEventListener;
      // This document owns one input index. Text/state painting changes its
      // geometry, not the membership of every passive SVG/DOM node.
      const candidates = new Map(), dirtyRoots = new Set(), dirtyTargets = new Set();
      let started = false, stopped = false, queued = false, previous = '', observed = new Set(), revision = 0;
      let classifyAll = true, refreshStyles = true, stylesheetOwnsInput = true, inlineVariableOwnsInput = false, styles = [];
      const changed = (target = null) => {
        if (stopped) return;
        if (target instanceof Element) dirtyTargets.add(target);
        if (!started || queued) return;
        queued = true;
        // Keep this edge before paint. Moving a control in an author's rAF
        // must update the native hit map in this same frame, not the next rAF.
        queueMicrotask(() => { queued = false; if (started) publish(); });
      };
      EventTarget.prototype.addEventListener = function(type, listener, options) {
        if (!inputTypes.has(type) || !listener) return add.call(this, type, listener, options);
        const capture = typeof options === 'boolean' ? options : !!options?.capture;
        const entries = targets.get(this) || [];
        const existing = entries.find(e => e.type === type && e.listener === listener && e.capture === capture);
        if (existing) return add.call(this, type, existing.wrapped, options);
        const target = this, entry = {type, listener, capture, once:!!options?.once, signal: options?.signal};
        const forget = () => {
          const i = entries.indexOf(entry); if (i >= 0) entries.splice(i, 1);
          if (entry.signal) remove.call(entry.signal, 'abort', forget);
          changed(target);
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
        changed(target);
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
            descriptor.set.call(this, value); changed(this);
          }});
        }
      }
      const handlesInput = node => (targets.get(node) || []).some(e => !e.signal?.aborted)
        || types.some(type => typeof node['on' + type] === 'function');
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
      // An arbitrary CSS selector (including :has or a sibling selector) can
      // change touch-action outside the mutated subtree. Retain that full
      // classification only when a stylesheet can actually own finger input.
      const inspectStyles = () => {
        stylesheetOwnsInput = false;
        const visited = new Set();
        const visit = rules => {
          for (const rule of rules) {
            if (rule.style && (rule.style.getPropertyValue('touch-action') || rule.style.getPropertyValue('all')))
              stylesheetOwnsInput = true;
            if (rule.cssRules) visit(rule.cssRules);
            if (rule.styleSheet) sheet(rule.styleSheet);
          }
        };
        const sheet = value => {
          if (visited.has(value)) return;
          visited.add(value);
          visit(value.cssRules);
        };
        try {
          for (const entry of styles) sheet(entry.sheet);
        } catch { stylesheetOwnsInput = true; classifyAll = true; }
        refreshStyles = false;
      };
      // CSSOM edits have no MutationObserver event. Their actual mutator marks
      // this document's CSS dependency dirty; text painting never serializes
      // every stylesheet just to rediscover that it has not changed.
      const cssRestorations = [];
      const stylesChanged = () => { if (!stopped) { refreshStyles = true; classifyAll = true; changed(); } };
      const stylesheetLoaded = event => { if (event.target?.matches?.('link[rel="stylesheet"]')) stylesChanged(); };
      // Focus, validation, :target and pointer pseudo states can change CSS
      // ownership without a DOM mutation or a size change. Observe those state
      // edges through the saved native add, so our observer owns no input.
      const cssStateEvents = ['focusin','focusout','input','change','invalid',
        'pointerover','pointerout','pointerdown','pointerup','pointercancel','keydown','keyup'];
      const cssStateChanged = () => {
        if (!stopped && (stylesheetOwnsInput || inlineVariableOwnsInput)) { classifyAll = true; changed(); }
      };
      const ruleDeclaration = declaration => !!declaration.parentRule;
      const watchMethod = (prototype, name, relevant = () => true) => {
        const original = prototype?.[name]; if (typeof original !== 'function') return;
        const descriptor = Object.getOwnPropertyDescriptor(prototype, name);
        const wrapped = function(...args) {
          const result = original.apply(this, args);
          if (relevant(this)) {
            if (result?.then) result.then(stylesChanged, () => {}); else stylesChanged();
          }
          return result;
        };
        prototype[name] = wrapped;
        cssRestorations.push(() => {
          if (prototype[name] !== wrapped) return;
          if (descriptor) Object.defineProperty(prototype, name, descriptor); else delete prototype[name];
        });
      };
      const watchSetter = (prototype, name, relevant = () => true) => {
        let owner = prototype, descriptor;
        while (owner) {
          descriptor = Object.getOwnPropertyDescriptor(owner, name);
          if (descriptor) break;
          owner = Object.getPrototypeOf(owner);
        }
        if (!descriptor?.set || !descriptor.configurable) return;
        const setter = function(value) { descriptor.set.call(this, value); if (relevant(this)) stylesChanged(); };
        Object.defineProperty(owner, name, {...descriptor, set:setter});
        cssRestorations.push(() => {
          if (Object.getOwnPropertyDescriptor(owner, name)?.set === setter)
            Object.defineProperty(owner, name, descriptor);
        });
      };
      for (const prototype of [window.CSSStyleSheet?.prototype, window.CSSGroupingRule?.prototype,
        window.CSSKeyframesRule?.prototype]) {
        for (const name of ['insertRule','deleteRule','appendRule','replace','replaceSync']) watchMethod(prototype, name);
      }
      for (const name of ['setProperty','removeProperty']) watchMethod(window.CSSStyleDeclaration?.prototype, name, ruleDeclaration);
      // cssText belongs to the base declaration; CSS property accessors belong
      // to the actual CSSStyleProperties declaration in current WebKit. Follow
      // that object's chain rather than silently missing a subclass accessor.
      const declarationPrototype = Object.getPrototypeOf(document.documentElement.style);
      for (const name of ['cssText','touchAction','touch-action','all']) watchSetter(declarationPrototype, name, ruleDeclaration);
      watchSetter(window.CSSStyleRule?.prototype, 'selectorText');
      watchSetter(window.StyleSheet?.prototype, 'disabled');
      watchSetter(window.MediaList?.prototype, 'mediaText');
      for (const name of ['appendMedium','deleteMedium']) watchMethod(window.MediaList?.prototype, name);
      const classify = node => {
        if (!node.isConnected) { candidates.delete(node); return; }
        if ((node.style?.getPropertyValue('touch-action') || node.style?.getPropertyValue('all') || '').includes('var('))
          inlineVariableOwnsInput = true;
        const input = kind(node);
        if (input === 'scene') candidates.delete(node); else candidates.set(node, input);
      };
      const classifySubtree = root => {
        if (root instanceof Element) classify(root);
        for (const node of root.querySelectorAll('*')) classify(node);
      };
      const updateIndex = () => {
        const current = [...document.styleSheets, ...(document.adoptedStyleSheets || [])]
          .map(sheet => ({sheet, disabled:sheet.disabled, media:sheet.media.mediaText}));
        if (current.length !== styles.length || current.some((entry, index) => entry.sheet !== styles[index].sheet
          || entry.disabled !== styles[index].disabled || entry.media !== styles[index].media)) {
          styles = current; refreshStyles = true; classifyAll = true;
        }
        if (refreshStyles) inspectStyles();
        if (classifyAll) {
          inlineVariableOwnsInput = false;
          candidates.clear(); classifySubtree(document); classifyAll = false;
        } else {
          // Keep only the outermost changed roots; a listener in an added
          // subtree must not cause a second walk through the same nodes.
          for (const root of dirtyRoots) {
            if (!root.isConnected) continue;
            let parent = root.parentElement;
            while (parent && !dirtyRoots.has(parent)) parent = parent.parentElement;
            if (parent) continue;
            classifySubtree(root);
          }
          for (const target of dirtyTargets) classify(target);
        }
        dirtyRoots.clear(); dirtyTargets.clear();
      };
      const resize = new ResizeObserver(() => {
        if (stylesheetOwnsInput || inlineVariableOwnsInput) classifyAll = true;
        changed();
      });
      const resized = () => { if (stylesheetOwnsInput || inlineVariableOwnsInput) classifyAll = true; changed(); };
      const mutation = new MutationObserver(records => {
        // Text can change :dir(auto), and an authored value change can affect
        // :has(input:invalid) before its adjacent text notification. Preserve
        // the complete classification whenever stylesheet CSS owns input.
        if (stylesheetOwnsInput || inlineVariableOwnsInput) classifyAll = true;
        for (const record of records) {
          const target = record.target instanceof Element ? record.target : record.target.parentElement;
          if (target?.closest('style,link[rel="stylesheet"]')) {
            refreshStyles = true; classifyAll = true; continue;
          }
          if (record.type === 'childList') {
            const elements = [...record.addedNodes, ...record.removedNodes].filter(node => node instanceof Element);
            if (elements.some(node => node.matches('style,link[rel="stylesheet"]') || node.querySelector('style,link[rel="stylesheet"]'))) {
              refreshStyles = true; classifyAll = true;
            } else if (elements.length) {
              if (stylesheetOwnsInput) classifyAll = true;
              else for (const node of record.addedNodes) if (node instanceof Element) dirtyRoots.add(node);
            }
          } else if (record.type === 'attributes' && !stylesheetOwnsInput && target) {
            // Styles can set inline touch-action or inherit it into descendants;
            // controls/onclick/tabindex/SMIL attributes belong to this subtree.
            if (record.attributeName === 'style') dirtyRoots.add(target); else dirtyTargets.add(target);
          }
        }
        changed();
      });
      const snapshot = () => {
        updateIndex();
        const regions = [], next = new Set();
        if (handlesInput(window) || handlesInput(document))
          regions.push({kind:'input', x:0, y:0, width:innerWidth, height:innerHeight});
        for (const [node, input] of candidates) {
          if (!node.isConnected) { candidates.delete(node); continue; }
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
      const stop = () => {
        started = false; stopped = true;
        mutation.disconnect(); resize.disconnect();
        remove.call(window, 'resize', resized); remove.call(window, 'pagehide', stop);
        remove.call(document, 'load', stylesheetLoaded, true);
        for (const event of cssStateEvents) remove.call(document, event, cssStateChanged, true);
        remove.call(window, 'hashchange', cssStateChanged);
        candidates.clear(); dirtyRoots.clear(); dirtyTargets.clear(); observed.clear(); styles = []; previous = '';
        for (const restore of cssRestorations.splice(0).reverse()) restore();
      };
      window.notebookFingerInput = Object.freeze({
        forEvent(event) {
          const path = event.composedPath();
          if (path.some(node => kind(node) === 'input')) return 'input';
          return path.some(node => kind(node) === 'link') ? 'link' : 'scene';
        },
        start() {
          if (stopped) throw new Error('finger_input_retired');
          started = true;
          mutation.observe(document.documentElement, {subtree:true,childList:true,attributes:true,characterData:true,
            attributeOldValue:true,characterDataOldValue:true});
          resize.observe(document.documentElement);
          add.call(window, 'resize', resized); add.call(window, 'pagehide', stop, {once:true});
          add.call(document, 'load', stylesheetLoaded, true);
          for (const event of cssStateEvents) add.call(document, event, cssStateChanged, true);
          add.call(window, 'hashchange', cssStateChanged);
          const value = snapshot(); previous = JSON.stringify(value); return {...value,revision:++revision};
        },
        stop
      });
    })();
    """#
}
