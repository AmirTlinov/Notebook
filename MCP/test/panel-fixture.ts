import {sealPanelBundle} from '../panel-bundle.mjs';
import {createServer as createNotebookServer} from '../src/server.js';

export const panelBundle=sealPanelBundle('<!doctype html><html><head></head><body>Notebook panel fixture</body></html>','0.0.1');
export const panelIdentity={version:panelBundle.version,cohort:panelBundle.cohort};
export const withCohort=(args:Record<string,unknown>)=>({...args,uiCohort:panelIdentity.cohort});

/** Isolated protocol fixtures use the same producer without loading product UI. */
export function createServer(socketPath?:string,options:Parameters<typeof createNotebookServer>[1]={}){
  return createNotebookServer(socketPath,{...options,panelBundle:options?.panelBundle??panelBundle});
}
