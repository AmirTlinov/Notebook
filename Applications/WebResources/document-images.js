(() => {
  'use strict';

  const aborted = () => new DOMException('Document image preparation superseded', 'AbortError');
  const pixels = value => value?.unit === 'px' && Number.isFinite(value.value) && value.value > 0;
  const nonnegativePixels = value => value?.unit === 'px' && Number.isFinite(value.value) && value.value >= 0;
  const keyword = (value, name) => value?.value === name;
  const ordinaryFlows = new Set(['block', 'flow-root', 'list-item']);

  // Resolved getComputedStyle lengths can hide an intrinsic/auto dependency.
  // Typed computed values preserve that distinction; unsupported cases keep
  // the ordinary resource-before-geometry path instead of guessing dimensions.
  const hasFixedGeometry = (image, sourceRoot) => {
    if (!['width', 'height'].every(name => /^[1-9]\d*$/.test(image.getAttribute(name) || ''))
      || typeof image.computedStyleMap !== 'function') return false;
    try {
      const style = image.computedStyleMap();
      if (!pixels(style.get('width')) || !pixels(style.get('height'))) return false;
      for (const property of ['min-width', 'min-height']) {
        const value = style.get(property);
        if (!nonnegativePixels(value) && !keyword(value, 'auto')) return false;
      }
      const maxWidth = style.get('max-width'), maxHeight = style.get('max-height');
      if (!keyword(maxWidth, 'none') && !nonnegativePixels(maxWidth)
        && !(maxWidth?.unit === 'percent' && Number.isFinite(maxWidth.value) && maxWidth.value >= 0 && maxWidth.value <= 100)) return false;
      if (!keyword(maxHeight, 'none') && !nonnegativePixels(maxHeight)) return false;
      // Automatic minimum sizes in flex/grid/table and shrink-to-fit parents
      // may still depend on the replaced content despite two specified axes.
      let parent = image.parentElement;
      while (parent && parent !== sourceRoot) {
        const parentStyle = getComputedStyle(parent);
        if (!ordinaryFlows.has(parentStyle.display) || parentStyle.float !== 'none'
          || ['absolute', 'fixed'].includes(parentStyle.position)) return false;
        parent = parent.parentElement;
      }
      return parent === sourceRoot;
    } catch { return false; }
  };

  const decode = async (image, signal) => {
    if (signal?.aborted) throw aborted();
    try {
      // HTML offers no cancellation handle for an in-flight decode. Keep its
      // real completion in the one owned tail; abort stops further submissions.
      image.loading = 'eager';
      await image.decode();
      if (signal?.aborted) throw aborted();
    } catch (cause) {
      if (signal?.aborted || cause?.name === 'AbortError') throw aborted();
      const error = new Error('document_image_decode_failed');
      error.blockID = image.closest('[data-block-id]')?.dataset.blockId;
      throw error;
    }
  };

  // The source/page owner submits at most four decodes at once. No persistent
  // image cache or extra native runtime is created by this readiness barrier.
  const waitFor = async (images, {signal, isCancelled = () => false} = {}) => {
    let next = 0, failed = false;
    const worker = async () => {
      while (next < images.length && !failed) {
        if (signal?.aborted || isCancelled()) throw aborted();
        const image = images[next++];
        try { await decode(image, signal); } catch (error) { failed = true; throw error; }
      }
    };
    const results = await Promise.allSettled(Array.from({length: Math.min(4, images.length)}, worker));
    const failure = results.find(result => result.status === 'rejected');
    if (failure) throw failure.reason;
    if (signal?.aborted || isCancelled()) throw aborted();
  };

  const waitForGeometry = (root, isCancelled) => waitFor(
    [...root.querySelectorAll('img')].filter(image => !hasFixedGeometry(image, root)), {isCancelled});
  const waitForPixels = (root, signal) => waitFor([...root.querySelectorAll('img')], {signal});
  window.notebookDocumentImages = Object.freeze({hasFixedGeometry, waitForGeometry, waitForPixels});
})();
