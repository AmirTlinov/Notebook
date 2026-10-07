import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { closeSync, constants, fstatSync, openSync, readSync } from 'node:fs';

const placeholder = '__NOTEBOOK_PANEL_COHORT__';
const identityID = 'notebook-panel-identity';
const identityElements = html => html.match(/<[a-z][^>]*\bid\s*=\s*["']notebook-panel-identity["'][^>]*>/gi) ?? [];
export const panelBundleByteLimit = 32 * 1024 * 1024;
const versionPattern = /^\d{1,9}\.\d{1,9}\.\d{1,9}$/;
const identityMarker = (version, cohort) => `<script id="${identityID}" type="application/json">${JSON.stringify({version, cohort})}</script>`;
const fingerprint = (version, html) => createHash('sha256').update('notebook-panel-cohort-v1\0').update(version).update('\0').update(html).digest('hex');

/** One producer binds the frozen browser payload and immutable plugin release. */
export function sealPanelBundle(html, version) {
  assert(typeof html === 'string' && html.includes('<head>') && identityElements(html).length === 0, 'Panel needs one unsealed HTML head.');
  assert(typeof version === 'string' && versionPattern.test(version), 'Panel needs the immutable plugin version.');
  const marked = html.replace('<head>', `<head>${identityMarker(version, placeholder)}`);
  const cohort = fingerprint(version, marked);
  const panel=verifyPanelBundle({version, cohort, resourceURI:`ui://notebook/${cohort}/workspace.html`,
    html:marked.replace(identityMarker(version, placeholder), identityMarker(version, cohort))});
  return panel;
}

export function verifyPanelBundle(value) {
  assert(value && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).sort().join(',') === 'cohort,html,resourceURI,version', 'Invalid panel bundle schema.');
  const {version, cohort, resourceURI, html} = value;
  assert(typeof version === 'string' && versionPattern.test(version)
    && typeof cohort === 'string' && /^[a-f0-9]{64}$/.test(cohort)
    && resourceURI === `ui://notebook/${cohort}/workspace.html`
    && typeof html === 'string' && Buffer.byteLength(html) <= panelBundleByteLimit, 'Invalid panel bundle identity.');
  const marker = identityMarker(version, cohort);
  assert(html.includes(marker) && identityElements(html).length === 1, 'Panel identity marker is missing or repeated.');
  assert(fingerprint(version, html.replace(marker, identityMarker(version, placeholder))) === cohort, 'Panel bytes do not match their cohort.');
  assert(Buffer.byteLength(JSON.stringify({version,cohort,resourceURI,html})) <= panelBundleByteLimit, 'Panel bundle exceeds its artifact budget.');
  return Object.freeze({version, cohort, resourceURI, html});
}

/** The signed artifact is read once at server registration, never per gesture. */
export function readPanelBundle(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const info = fstatSync(fd);
    assert(info.isFile() && info.size > 0 && info.size <= panelBundleByteLimit, 'Panel bundle exceeds its read budget.');
    const bytes = Buffer.alloc(info.size + 1);
    let count = 0;
    while (count < bytes.length) {
      const read = readSync(fd, bytes, count, bytes.length - count, null);
      if (!read) break;
      count += read;
    }
    assert(count === info.size, 'Panel bundle changed during its read.');
    return verifyPanelBundle(JSON.parse(new TextDecoder('utf-8', {fatal:true}).decode(bytes.subarray(0, count))));
  } finally { closeSync(fd); }
}
