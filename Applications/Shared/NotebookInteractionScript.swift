#if os(iOS)
import Foundation

/// Added only for an explicitly configured private Simulator measurement. The
/// observers never write DOM, prevent an event, move focus, or schedule input.
enum NotebookInteractionScript {
  static func source(selectorsJSON: String) -> String {
    """
    (() => {
      const selectors = \(selectorsJSON);
      let sequence = 0, stopped = false, lastEvent = null;
      const send = observation => {
        if (stopped) return;
        if (++sequence > 4096) {
          stopped = true;
          window.webkit.messageHandlers.notebook.postMessage({token:notebookLoadToken,
            kind:'interactionObservation', observation:{stage:'truncated',reason:'DOM observer budget exceeded'}});
          return;
        }
        window.webkit.messageHandlers.notebook.postMessage({token:notebookLoadToken,
          kind:'interactionObservation', observation:{...observation, sequence,
            jsNow:performance.now(), jsTimeOrigin:performance.timeOrigin}});
      };
      const target = node => node instanceof Element ? {
        tag:node.tagName, id:node.id.slice(0,128), role:(node.getAttribute('role')||'').slice(0,80),
        label:(node.getAttribute('aria-label')||'').slice(0,256)
      } : null;
      const observables = () => selectors.map(selector => {
        let node;
        try { node = document.querySelector(selector); }
        catch { return {selector, error:'invalid_selector'}; }
        if (!node) return {selector, found:false};
        const rect = node.getBoundingClientRect();
        return {selector, found:true, target:target(node), text:(node.textContent||'').slice(0,512),
          value:typeof node.value === 'string' ? node.value.slice(0,512) : null,
          rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height},
          viewport:{width:innerWidth,height:innerHeight}};
      });
      const record = event => {
        if (!event.isTrusted) return;
        const eventID = ++sequence;
        lastEvent = {eventID, name:event.type, timeStamp:event.timeStamp,
          pointerID:Number.isFinite(event.pointerId)?event.pointerId:null};
        send({stage:'trusted_event', ...lastEvent, target:target(event.target),
          clientX:Number.isFinite(event.clientX)?event.clientX:null,
          clientY:Number.isFinite(event.clientY)?event.clientY:null});
        // This is a DOM endpoint, explicitly not rendering or display evidence.
        queueMicrotask(() => send({stage:'post_listener_microtask_dom', eventID, observables:observables()}));
      };
      for (const name of ['pointerdown','pointerup','pointercancel','click','input','change','keydown'])
        addEventListener(name, record, {capture:true,passive:true});
      let previous = '';
      const inspect = () => {
        const value = observables(), serialized = JSON.stringify(value);
        if (serialized === previous) return;
        previous = serialized;
        send({stage:'dom_observable_change', precedingEvent:lastEvent, observables:value});
      };
      addEventListener('DOMContentLoaded', () => {
        inspect(); new MutationObserver(inspect).observe(document.body,
          {subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['value','aria-valuenow']});
      }, {once:true});
      const types = typeof PerformanceObserver !== 'undefined' ? PerformanceObserver.supportedEntryTypes : [];
      send({stage:'capabilities', eventTiming:types.includes('event'), firstInput:types.includes('first-input'),
        eventTimingMinimumDurationMs:16, displayMeasured:false});
      for (const type of ['event','first-input']) {
        if (!types.includes(type)) continue;
        try {
          new PerformanceObserver(list => {
            for (const entry of list.getEntries()) send({stage:'event_timing', name:entry.name,
              entryType:entry.entryType, startTime:entry.startTime, duration:entry.duration,
              processingStart:entry.processingStart, processingEnd:entry.processingEnd,
              interactionID:entry.interactionId??null, target:target(entry.target),
              durationQuantizationMs:8, displayMeasured:false});
          }).observe({type, buffered:true, ...(type==='event'?{durationThreshold:16}:{})});
        } catch (error) { send({stage:'event_timing_unavailable', entryType:type, reason:String(error).slice(0,256)}); }
      }
    })();
    """
  }
}
#endif
