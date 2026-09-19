import { marked } from "marked";
import { documentExport } from "./document-tex.js";
import type { DocumentDocument } from "./domain.js";

type Preparation = { action: {operations:Array<{values:Record<string, unknown>}>}; markdownOperations:number[] };
type Request = { kind:"action"; preparation:Preparation } | { kind:"documentTeX"; document:DocumentDocument; programPointScale?:number };

function notebookMarkup(request: Request): unknown {
  if (request.kind === "documentTeX") return documentExport(request.document, request.programPointScale);
  if (request.kind !== "action") throw new Error("invalid_markup_request");
  const {action,markdownOperations} = request.preparation;
  for (const index of markdownOperations) {
    const values=action.operations[index]?.values;
    if (!values || typeof values.source !== "string") throw new Error("invalid_markup_source");
    values.html = marked.parse(values.source,{async:false,gfm:true});
  }
  for (const operation of action.operations) {
    if (typeof operation.values.javaScript === "string") {
      // Compile only. This closed trusted context never runs embedded programs.
      new Function(operation.values.javaScript);
    }
  }
  return action;
}
Object.defineProperty(globalThis,"notebookMarkup",{value:notebookMarkup});
