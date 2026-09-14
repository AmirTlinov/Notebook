(() => {
  "use strict";
  const invoke = globalThis.__nbHost;
  delete globalThis.__nbHost;
  let active = 0;
  const queue = [];
  function failure(value) {
    if (value && typeof value === "object" && typeof value.code === "string") {
      const error = new Error(value.message || value.code);
      Object.assign(error, value);
      error.name = value.code;
      return error;
    }
    return value;
  }
  function drain() {
    while (active < 4 && queue.length) {
      const {name,args,resolve,reject} = queue.shift();
      active++;
      Promise.resolve().then(() => invoke(name,args)).then(resolve,value => reject(failure(value))).finally(() => { active--; drain(); });
    }
  }
  function host(name,args) {
    if (queue.length >= 1024) return Promise.reject({code:"sdk_queue_limit",message:"At most 1024 queued SDK calls."});
    return new Promise((resolve,reject) => { queue.push({name,args,resolve,reject}); drain(); });
  }
  const read = name => (args = {}) => host(name, args);
  const effect = name => (key, args = {}) => host(name, { ...args, key });
  const nb = Object.freeze({
    help: topic => host("help", topic === undefined ? {} : {topic}),
    observe: read("observe"), read: read("read"), readMany: read("readMany"),
    board: read("board"), notebook: read("notebook"), page: read("page"), document: read("document"),
    context: read("context"), attention: read("attention"), code: read("code"),
    search: read("search"), reference: read("reference"), referenceStatus: read("referenceStatus"),
    action: read("action"), render: read("render"), pageMap: read("pageMap"),
    pageImage: read("pageImage"), regions: read("regions"), place: read("place"),
    exportStatus: read("exportStatus"), presentation: read("presentation"), wait: read("wait"), id: key => host("id", { key }),
    transaction: (key, action) => host("transaction", { key, action }),
    undo: effect("undo"), point: effect("point"), present: effect("present"), cancelPresentation: effect("cancelPresentation"), export: effect("export"),
  });
  Object.defineProperty(globalThis, "nb", { value: nb });
  Object.defineProperty(globalThis, "emit", { value: value => host("emit", { value }) });
  Object.defineProperty(globalThis, "emitImage", { value: artifact => host("emitImage", { artifact }) });
})();
