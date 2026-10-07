export type PanelIdentity = Readonly<{version:string;cohort:string}>;
export type PanelBundle = PanelIdentity & Readonly<{resourceURI:string;html:string}>;
export const panelBundleByteLimit:number;
export function sealPanelBundle(html:string, version:string):PanelBundle;
export function verifyPanelBundle(value:unknown):PanelBundle;
export function readPanelBundle(path:string|URL):PanelBundle;
