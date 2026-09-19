// The browser contract shared by spatial, document and local-preview adapters.
// This function is self-contained so an isolated iframe can install the exact
// same source without opening its CSP or sharing its parent's JavaScript heap.
function createNotebookProgram({state = null, onCommit = () => {}, report = () => {},
  paint = () => Promise.resolve(), timeoutMS = 4000, readyTimeoutMS = 8000} = {}) {
  const version = 'NotebookProgram/1';
  const canonical = value => JSON.stringify(value, (_, v) => v && typeof v === 'object' && !Array.isArray(v)
    ? Object.fromEntries(Object.keys(v).sort().map(key => [key, v[key]])) : v);
  const copy = value => JSON.parse(JSON.stringify(value));
  let value = copy(state), revision = 0n, disposed = false, suspended = false, frozen = false;
  let hooks = {}, registered = false, generation = 0, operation = null, started = null;
  let semantic = null, semanticValue = null;
  const readiness = [];
  const error = code => new Error(code);
  const alive = () => { if (disposed) throw error('program_disposed'); };
  const abort = () => { generation++; operation?.abort(); operation = null; };
  const bounded = (work, signal, code, budget = timeoutMS) => new Promise((resolve, reject) => {
    if (signal?.aborted) { reject(error('program_superseded')); return; }
    const cancel = () => finish(reject, error('program_superseded'));
    const timer = setTimeout(() => finish(reject, error(code + '_timeout')), budget);
    const finish = (complete, result) => {
      clearTimeout(timer); signal?.removeEventListener('abort', cancel); complete(result);
    };
    signal?.addEventListener('abort', cancel, {once:true});
    Promise.resolve().then(work).then(result => finish(resolve, result), reason => finish(reject, reason));
  });
  const announce = reason => report('program_lifecycle_error', String(reason?.message || reason));
  const commit = next => {
    if (disposed || suspended) return false;
    const accepted = copy(next);
    if (canonical(accepted) === canonical(value)) return false;
    value = accepted; revision++;
    onCommit(copy(value), String(revision));
    return true;
  };
  const api = Object.freeze({
    version,
    get state() { return copy(value); },
    commit,
    ready(promise) {
      alive();
      if (started) throw error('program_ready_declared_late');
      const pending = Promise.resolve(promise);
      // Observe rejection immediately, including before the document load event.
      pending.catch(() => {}); readiness.push(pending); return pending;
    },
    // A selected object, not the scene graph. The callback is read-only and
    // synchronous; asynchronous hit tests must settle in the author's input owner.
    semantic(callback) {
      alive();
      if (semantic || typeof callback !== 'function') throw error('program_semantic_invalid');
      semantic = callback;
    },
    lifecycle(callbacks) {
      alive();
      if (registered || !callbacks || typeof callbacks !== 'object') throw error('program_lifecycle_invalid');
      for (const [name, callback] of Object.entries(callbacks))
        if (!['pause','checkpoint','resume','dispose'].includes(name) || typeof callback !== 'function')
          throw error('program_lifecycle_invalid');
      hooks = {...callbacks}; registered = true;
    }
  });
  const controller = Object.freeze({
    version, api,
    get revision() { return String(revision); },
    get suspended() { return suspended; },
    start({requiresReady = true} = {}) {
      alive();
      if (started) return started;
      started = bounded(async () => {
        if (requiresReady && !readiness.length) throw error('program_completion_unknown');
        await Promise.all(readiness); await paint(); alive();
        return {version, revision:String(revision)};
      }, null, 'program_ready', readyTimeoutMS);
      started.catch(reason => report('program_ready_error', String(reason?.message || reason)));
      return started;
    },
    async apply(next, expectedRevision = String(revision)) {
      alive();
      if (String(revision) !== expectedRevision || suspended) return false;
      const accepted = copy(next);
      if (canonical(value) !== canonical(accepted)) {
        value = accepted;
        dispatchEvent(new CustomEvent('notebookstate', {detail:copy(value)}));
      }
      await paint();
      return !disposed && !suspended && String(revision) === expectedRevision;
    },
    semanticSelection() {
      alive();
      if (!suspended || !frozen) throw error('program_semantic_pause_required');
      return copy(semanticValue);
    },
    async checkpoint() {
      alive();
      if (suspended && frozen) return copy(value);
      if (suspended) throw error('program_checkpoint_busy');
      suspended = true; abort();
      const expected = generation, request = new AbortController(); operation = request;
      try {
        const next = await bounded(async () => {
          await hooks.pause?.({signal:request.signal});
          if (request.signal.aborted) throw error('program_superseded');
          return hooks.checkpoint ? await hooks.checkpoint({signal:request.signal}) : copy(value);
        }, request.signal, 'program_checkpoint');
        alive();
        if (expected !== generation) throw error('program_superseded');
        const accepted = copy(next);
        // Do not wait for rAF here: WebKit may already have parked this
        // viewport. The author has finished its model/DOM update; the existing
        // native snapshot owner establishes the pixel boundary afterwards.
        // No optimistic commit: the native checkpoint owner must admit this
        // value and confirm the existing writer before disposing the surface.
        value = accepted; frozen = true; semanticValue = null;
        if (semantic && hooks.pause && hooks.checkpoint) {
          try {
            const selected = semantic();
            if (selected?.then) { Promise.resolve(selected).catch(() => {}); throw error('program_semantic_async'); }
            const json = JSON.stringify(selected);
            // UTF-16 bound also bounds UTF-8 to 16 KiB; native validates fields.
            if (typeof json !== 'string' || json.length > 4096) throw error('program_semantic_limit');
            semanticValue = JSON.parse(json);
          } catch (reason) { report('program_semantic_unavailable', String(reason?.message || reason)); }
        }
        return copy(value);
      } catch (reason) {
        request.abort(); announce(reason); throw reason;
      } finally { if (operation === request) operation = null; }
    },
    async resume() {
      alive(); abort(); semanticValue = null;
      if (!suspended) return true;
      const expected = generation, request = new AbortController(); operation = request;
      try {
        await bounded(() => hooks.resume?.({signal:request.signal}), request.signal, 'program_resume');
        alive();
        if (expected !== generation) throw error('program_superseded');
        suspended = false; frozen = false; return true;
      } catch (reason) { request.abort(); announce(reason); throw reason; }
      finally { if (operation === request) operation = null; }
    },
    dispose() {
      if (disposed) return Promise.resolve();
      disposed = true; suspended = true; semanticValue = null; semantic = null; abort();
      // Invoke synchronously before a native owner removes the browsing context.
      let result;
      try { result = hooks.dispose?.(); } catch (reason) { announce(reason); return Promise.reject(reason); }
      const pending = bounded(() => result, null, 'program_dispose');
      pending.catch(announce); return pending;
    }
  });
  return controller;
}
