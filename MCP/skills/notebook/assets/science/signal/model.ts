/** Sample indices are authoritative. Seconds and views are derived, never new data. */
export const sampleRate = 1000, count = 100_000, binSize = 100, seed = 20260919;
export const impulseIndex = 61_337;
export const spans = [.05, .2, 1, 4] as const;
export type Selection = {center: number; span: number; sample: number | null};
export function selection(value: unknown): Selection {
  const input = value as Partial<Selection> | null;
  const span = spans.includes(input?.span as typeof spans[number]) ? input!.span! : 4;
  const center = typeof input?.center === 'number' && Number.isFinite(input.center) ? input.center : 50;
  const sample = typeof input?.sample === "number" && Number.isInteger(input.sample) && input.sample >= 0 && input.sample < count ? input.sample : null;
  return {sample, center: Math.max(span / 2, Math.min(count / sampleRate - span / 2, center)), span};
}
export function sampleWindow(state: Selection) {
  const length = Math.round(state.span * sampleRate);
  const start = Math.max(0, Math.min(count - length, Math.round(state.center * sampleRate - length / 2)));
  return {start, length, end: start + length, from: start / sampleRate, to: (start + length - 1) / sampleRate};
}
export function generateSamples() {
  const samples = new Float32Array(count); let random = seed;
  for (let i = 0; i < count; i++) {
    random ^= random << 13; random ^= random >>> 17; random ^= random << 5;
    const t = i / sampleRate, noise = .08 * (2 * (random >>> 0) / 4294967296 - 1);
    samples[i] = Math.exp(-t / 55) * (Math.sin(2 * Math.PI * 2 * t) + .3 * Math.sin(2 * Math.PI * 7 * t)) + noise;
  }
  for (let i = 0; i < 3; i++) samples[impulseIndex + i] = samples[impulseIndex + i]! + [1.4, 2.5, 1.4][i]!;
  return samples;
}
export function envelope(samples: Float32Array, size = binSize) {
  const result = new Float32Array(Math.ceil(samples.length / size) * 2);
  for (let b = 0; b < result.length / 2; b++) {
    let low = Infinity, high = -Infinity;
    for (let i = b * size; i < Math.min(samples.length, (b + 1) * size); i++) {low = Math.min(low, samples[i]!); high = Math.max(high, samples[i]!);}
    result[b * 2] = low; result[b * 2 + 1] = high;
  }
  return result;
}
