// The browser contract shared by spatial, document and local-preview adapters.
// An isolated iframe installs this owner and its bounded receiver without
// opening its CSP or sharing its parent's JavaScript heap.
function createNotebookProgram({state = null, onCommit = () => {}, report = () => {},
  paint = () => Promise.resolve(), stateTransport = null, timeoutMS = 4000, readyTimeoutMS = 8000} = {}) {
  const version = 'NotebookProgram/1';
  const utf8Length = text => {
    let bytes=0;
    for(let i=0;i<text.length;i++) {
      const c=text.charCodeAt(i);
      if(c<128)bytes++;else if(c<2048)bytes+=2;
      else if(c>=0xd800&&c<=0xdbff&&text.charCodeAt(i+1)>=0xdc00&&text.charCodeAt(i+1)<=0xdfff){bytes+=4;i++;}
      else bytes+=3;
    }
    return bytes;
  };
  const serialize = value => {
    let nodes = 0;
    const json = JSON.stringify(value, (_, v) => {
      nodes++;
      return v && typeof v === 'object' && !Array.isArray(v)
        ? Object.fromEntries(Object.keys(v).sort().map(key => [key, v[key]])) : v;
    });
    if (typeof json !== 'string') throw new Error('program_state_not_json');
    return {json,nodes,bytes:utf8Length(json)};
  };
  const copy = value => JSON.parse(JSON.stringify(value));
  // Measure plain JSON without first allocating its potentially huge string.
  // Authored JavaScript already owns the input object; native credit covers the
  // additional immutable transfer copy. Actual serialization is checked again.
  const measure = input => {
    let units = 0, nodes = 0, extraBytes = 0; const ancestors = new Set();
    const string = text => {
      units += 2;
      for(let i=0;i<text.length;i++) {
        const c=text.charCodeAt(i);
        if(c<32)units += [8,9,10,12,13].includes(c)?2:6;
        else if(c===34||c===92)units+=2;
        else if(c>=0xd800&&c<=0xdbff) {
          const next=text.charCodeAt(i+1);
          if(next>=0xdc00&&next<=0xdfff){units+=2;extraBytes+=2;i++;}else units+=6;
        } else { units += c>=0xdc00&&c<=0xdfff?6:1;
          if(c>=128&&!(c>=0xdc00&&c<=0xdfff))extraBytes+=c<2048?1:2;
        }
      }
    };
    const visit = (value, arrayMember = false) => {
      nodes++;
      if(value===null){units+=4;return;}
      if(typeof value==='string'){string(value);return;}
      if(typeof value==='number'){units+=Number.isFinite(value)?String(value).length:4;return;}
      if(typeof value==='boolean'){units+=value?4:5;return;}
      if(typeof value!=='object') {
        if(arrayMember && ['undefined','function','symbol'].includes(typeof value)){units+=4;return;}
        throw new Error('program_state_not_json');
      }
      if(ancestors.has(value))throw new Error('program_state_cycle');
      if(typeof value.toJSON==='function')throw new Error('program_state_not_plain_json');
      ancestors.add(value);units+=2;let count=0;
      if(Array.isArray(value))for(const item of value){if(count++)units++;visit(item,true);}
      else for(const key in value)if(Object.prototype.hasOwnProperty.call(value,key)) {
        const item=value[key];
        if(['undefined','function','symbol'].includes(typeof item)){nodes++;continue;}
        if(count++)units++;string(key);units++;visit(item);
      }
      ancestors.delete(value);
    };
    visit(input);return {units,nodes,bytes:units+extraBytes};
  };
  const initial = serialize(state);
  let value = JSON.parse(initial.json), valueJSON = initial.json, valueNodes = initial.nodes, valueBytes = initial.bytes, checkpointCost = 0, revision = 0n, disposed = false, suspended = false, frozen = false;
  // The public commit is synchronous. Credit has already been reserved by the
  // native scene allocator; no queued body is accepted speculatively.
  let credit = stateTransport?.credit ?? 0, creditRequested = 0;
  let commitsEnabled = stateTransport?.enabled !== false;
  const snapshots = new Map(), drainWaiters = [];
  let acknowledgedRevision = 0n;
  const describe = (json, revision, nodes, bytes, previousCost = 0) => {
    // UTF-16 strings plus UTF-8 transfer/decode and the per-node JSON backing.
    // This is transient allocation admission, never a persisted-model limit.
    return {revision, units:json.length, cost:Math.max(bytes*8 + nodes*64, previousCost)};
  };
  const drained = () => snapshots.size ? new Promise(resolve => drainWaiters.push(resolve)) : Promise.resolve();
  const checkpointResult = serialized => serialized ? describe(valueJSON, 'frozen', valueNodes, valueBytes, checkpointCost) : copy(value);
  let hooks = {}, registered = false, generation = 0, operation = null, started = null;
  let checkpointOperation = null, pauseCompleted = false, phase = 'running', failedStage = null;
  let semantic = null, semanticValue = null, exportFrame = null, exportTimeline = false, exportVectors = false;
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
    if (disposed || suspended || !commitsEnabled) return false;
    if(stateTransport) {
      const estimate=measure(next), cost=Math.max(estimate.bytes*8+estimate.nodes*64, valueBytes*8+valueNodes*64);
      if(cost>credit) {
        const needed=cost-credit;
        if(needed>creditRequested){creditRequested=needed;stateTransport.requestCredit(needed);}
        report('program_state_backpressure','State not accepted; retry after notebookcapacity.');return false;
      }
    }
    const encoded = serialize(next), json = encoded.json;
    if (json === valueJSON) return false;
    const nextRevision = String(revision + 1n);
    const descriptor = stateTransport ? describe(json, nextRevision, encoded.nodes, encoded.bytes, valueBytes*8+valueNodes*64) : null;
    if (descriptor && descriptor.cost > credit) {
      const needed = descriptor.cost - credit;
      if (needed > creditRequested) { creditRequested = needed; stateTransport.requestCredit(needed); }
      report('program_state_backpressure', 'State not accepted; retry after notebookcapacity.');
      return false;
    }
    const accepted = JSON.parse(json);
    value = accepted; valueJSON = json; valueNodes = encoded.nodes; valueBytes = encoded.bytes; revision++;
    if (descriptor) {
      credit -= descriptor.cost; snapshots.set(nextRevision, {json, descriptor});
      stateTransport.onSnapshot(descriptor);
    } else { onCommit(copy(value), nextRevision); }
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
    // An author-owned static representation, not serialization of arbitrary
    // heap/DOM. Native invokes this only in an isolated export executor.
    exportFrame(callback, {timeline = false, vectors = false} = {}) {
      alive();
      if (exportFrame || typeof callback !== 'function' || typeof timeline !== 'boolean' || typeof vectors !== 'boolean') throw error('program_export_invalid');
      exportFrame = callback; exportTimeline = timeline; exportVectors = vectors;
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
    setCommitEnabled(enabled) {
      const wasEnabled = commitsEnabled; commitsEnabled = enabled === true;
      if (!wasEnabled && commitsEnabled) dispatchEvent(new CustomEvent('notebookcapacity'));
    },
    receiveStateWindow: createNotebookStateReceiver((next, expected) => controller.apply(next, expected)),
    get revision() { return String(revision); },
    get suspended() { return suspended; },
    get lifecycleState() { return {phase, failedStage, pauseCompleted}; },
    grantStateCredit(bytes) {
      alive();
      if (!Number.isSafeInteger(bytes) || bytes <= 0) throw error('program_state_credit_invalid');
      credit += bytes; creditRequested = 0;
      dispatchEvent(new CustomEvent('notebookcapacity'));
    },
    readSnapshot({revision, offset = 0}) {
      const json = revision === 'frozen' && frozen ? valueJSON : snapshots.get(revision)?.json;
      if (typeof json !== 'string' || !Number.isSafeInteger(offset) || offset < 0 || offset > json.length)
        throw error('program_state_snapshot_missing');
      // 262144 UTF-16 units fit in the existing 1 MiB resource-read window.
      // Never split a surrogate pair, including between two native pulls.
      let end = Math.min(json.length, offset + 262144);
      if (end < json.length && /[\uD800-\uDBFF]/.test(json[end-1])) end--;
      return json.slice(offset,end);
    },
    acknowledgeSnapshot(revision) {
      if (typeof revision!=='string' || !/^[1-9][0-9]*$/.test(revision)) throw error('program_state_ack_order');
      const sequence=BigInt(revision);
      // The writer already accepted this immutable revision. A lost native
      // reply retries only ACK, never the write and never its capacity grant.
      if (sequence<=acknowledgedRevision) return;
      if (snapshots.keys().next().value !== revision) throw error('program_state_ack_order');
      credit += snapshots.get(revision).descriptor.cost; snapshots.delete(revision);
      acknowledgedRevision=sequence;
      if (!snapshots.size) { for (const resolve of drainWaiters.splice(0)) resolve(); }
      if (creditRequested) { creditRequested = 0; dispatchEvent(new CustomEvent('notebookcapacity')); }
    },
    drainCommits: drained,
    cancelLifecycle() {
      if (!['draining','pausing','checkpointing','resuming'].includes(phase)) return false;
      failedStage = phase; abort(); phase = 'failed'; suspended = true;
      return true;
    },
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
      const encoded = serialize(next), accepted = JSON.parse(encoded.json), json = encoded.json;
      if (valueJSON !== json) {
        value = accepted; valueJSON = json; valueNodes = encoded.nodes; valueBytes = encoded.bytes;
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
    async exportFrame(request) {
      alive();
      if(request?.format==='pdf'&&!exportVectors)return [];
      if (!exportFrame || !['svg','raster','pdf'].includes(request?.format)) throw error('program_export_unavailable');
      if(request.format==='raster'&&(!Number.isFinite(request.pixelRatio)||request.pixelRatio<=0||request.pixelRatio>8))throw error('program_export_extent');
      if(request.time!==undefined&&(!exportTimeline||!Number.isFinite(request.time)||request.time<0))throw error('program_export_timeline_unavailable');
      const input = copy(request.state);
      suspended = true; frozen = false; abort();
      const expected = generation, operationRequest = new AbortController(); operation = operationRequest;
      try {
        const result = await bounded(async () => {
          await hooks.pause?.({signal:operationRequest.signal});
          if (operationRequest.signal.aborted) throw error('program_superseded');
          return await exportFrame({format:request.format,state:copy(input),pixelRatio:request.pixelRatio,time:request.time,signal:operationRequest.signal});
        }, operationRequest.signal, 'program_export');
        alive();
        if (expected !== generation) throw error('program_superseded');
        if(request.format==='pdf') {
          if(!Array.isArray(result)||result.length>16||JSON.stringify(result).length>524288)throw error('program_export_limit');
          for(const layer of result) {
            const r=layer?.frame;
            if(typeof layer?.svg!=='string'||!r||!['x','y','width','height'].every(k=>Number.isFinite(r[k]))
              ||r.x<0||r.y<0||r.width<=0||r.height<=0)throw error('program_export_vector_invalid');
          }
          return copy(result);
        }
        if(request.format==='svg') {
          if(typeof result!=='string'||result.length>524288)throw error('program_export_limit');
          return result;
        }
        if(result!==null)throw error('program_export_raster_invalid');
        // Null acknowledges that the author has rendered and stopped at this cut.
        // Pixels stay in the existing WebKit snapshot path, never in postMessage.
        return null;
      } catch(reason) { operationRequest.abort(); throw reason; }
      finally { if(operation === operationRequest) operation = null; }
    },
    checkpoint({retry = false, serialized = false} = {}) {
      alive();
      if (suspended && frozen) return Promise.resolve(checkpointResult(serialized));
      if (checkpointOperation && !retry) return checkpointOperation;
      if (phase === 'failed' && !retry) return Promise.reject(error('program_checkpoint_retry_required'));
      // A native timeout may precede the parked browser timer. Explicit retry
      // revokes that generation before restarting only the unfinished stage.
      suspended = true; abort(); phase = 'draining';
      const expected = generation, request = new AbortController(); operation = request;
      const pending = (async () => {
      try {
        await drained();
        const next = await bounded(async () => {
          if (!pauseCompleted) {
            phase = 'pausing';
            await hooks.pause?.({signal:request.signal});
            if (request.signal.aborted) throw error('program_superseded');
            pauseCompleted = true;
          }
          phase = 'checkpointing';
          if (request.signal.aborted) throw error('program_superseded');
          return hooks.checkpoint ? await hooks.checkpoint({signal:request.signal}) : copy(value);
        }, request.signal, 'program_checkpoint');
        alive();
        if (expected !== generation) throw error('program_superseded');
        const encoded = serialize(next), accepted = JSON.parse(encoded.json);
        // Do not wait for rAF here: WebKit may already have parked this
        // viewport. The author has finished its model/DOM update; the existing
        // native snapshot owner establishes the pixel boundary afterwards.
        // No optimistic commit: the native checkpoint owner must admit this
        // value and confirm the existing writer before disposing the surface.
        checkpointCost = Math.max(valueBytes*8+valueNodes*64, encoded.bytes*8+encoded.nodes*64);
        value = accepted; valueJSON = encoded.json; valueNodes = encoded.nodes; valueBytes = encoded.bytes; frozen = true; phase = 'frozen'; failedStage = null; semanticValue = null;
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
        return checkpointResult(serialized);
      } catch (reason) {
        request.abort();
        if (expected === generation && !disposed) { failedStage = phase; phase = 'failed'; announce(reason); }
        throw reason;
      } finally { if (operation === request) operation = null; }
      })();
      checkpointOperation = pending;
      pending.finally(() => { if (checkpointOperation === pending) checkpointOperation = null; }).catch(() => {});
      return pending;
    },
    async resume() {
      alive(); abort(); semanticValue = null;
      if (!suspended) return true;
      const expected = generation, request = new AbortController(); operation = request;
      phase = 'resuming';
      try {
        await bounded(() => hooks.resume?.({signal:request.signal}), request.signal, 'program_resume');
        alive();
        if (expected !== generation) throw error('program_superseded');
        suspended = false; frozen = false; pauseCompleted = false; phase = 'running'; failedStage = null; return true;
      } catch (reason) { request.abort(); if (expected === generation && !disposed) { phase = 'failed'; failedStage = 'resuming'; announce(reason); } throw reason; }
      finally { if (operation === request) operation = null; }
    },
    dispose() {
      if (disposed) return Promise.resolve();
      disposed = true; suspended = true; phase = 'disposed'; semanticValue = null; semantic = null; exportFrame = null; abort();
      // Invoke synchronously before a native owner removes the browsing context.
      let result;
      try { result = hooks.dispose?.(); } catch (reason) { announce(reason); return Promise.reject(reason); }
      const pending = bounded(() => result, null, 'program_dispose');
      pending.catch(announce); return pending;
    }
  });
  return controller;
}

// Both native program surfaces and the document shell use this bounded
// presentation receiver. Unlike authored commits, an obsolete external frame
// may be replaced; no partial model becomes visible before the last window.
function createNotebookStateReceiver(accept) {
  let pending = null;
  return async ({transfer, offset = 0, units = 0, text = '', revision = '', cancel = false}) => {
    if (cancel) { if (pending?.transfer === transfer) pending = null; return false; }
    if (typeof transfer !== 'string' || !transfer || typeof text !== 'string' || text.length > 262144
      || !Number.isSafeInteger(units) || units < 1 || !Number.isSafeInteger(offset) || offset < 0
      || !text.length || text.length > units - offset) throw new Error('program_state_window');
    if (offset === 0) pending = {transfer, units, revision, offset:0, chunks:[]};
    if (!pending || pending.transfer !== transfer) return false;
    if (pending.offset !== offset || pending.units !== units || pending.revision !== revision)
      throw new Error('program_state_window_order');
    pending.chunks.push(text); pending.offset += text.length;
    if (pending.offset !== units) return true;
    const complete = pending; pending = null;
    return await accept(JSON.parse(complete.chunks.join('')), revision);
  };
}
