/** Browser program API, separate from the QuickJS nb command API. */
type NotebookJSON = null | boolean | number | string | NotebookJSON[] | {[key: string]: NotebookJSON};
interface NotebookProgramLifecycle {
  pause?(context: {signal: AbortSignal}): void | Promise<void>;
  checkpoint?(context: {signal: AbortSignal}): NotebookJSON | Promise<NotebookJSON>;
  resume?(context: {signal: AbortSignal}): void | Promise<void>;
  dispose?(): void | Promise<void>;
}
/** Untrusted author data. Anchor is a point in the current viewport, normalized 0…1.
 * Return only the current selected object; null means no selected visible object. */
interface NotebookSemanticSelection {
  objectID: string;
  label: string;
  anchor: {x: number; y: number};
  values: {label: string; value: number; unit: string}[];
  model: NotebookJSON;
}
declare const notebook: {
  readonly version: 'NotebookProgram/1';
  readonly state: NotebookJSON;
  /** Local admission only, not a durable-save receipt. False while suspended/disposed or unchanged. */
  commit(value: NotebookJSON): boolean;
  ready<T>(completion: PromiseLike<T> | T): Promise<T>;
  /** Called synchronously after pause/checkpoint, before the native frozen raster.
   * At most 4096 UTF-16 units; never return a Promise or mutate the scene here. */
  semantic(selection: () => NotebookSemanticSelection | null): void;
  /** Render the exact supplied saved state. Raster: redraw Canvas/WebGL at pixelRatio,
   * await workers/media and return null only once the stopped frame is ready.
   * SVG: return a self-contained passive vector image.
   * PDF with vectors:true: return nonoverlapping SVG replacement rectangles in
   * local CSS pixels. Rectangles must fit the block and replace, not cover, raster.
   * Include any opaque background needed; remaining regions stay raster.
   * Runs only in an isolated export executor, after pause; commits are disabled.
   * Missing or failed author export is an error, not a raster disguised as SVG. */
  exportFrame(render: (request: {format: 'svg' | 'raster' | 'pdf'; state: NotebookJSON; pixelRatio?: number; time?: number; signal: AbortSignal}) => string | null | NotebookVectorLayer[] | Promise<string | null | NotebookVectorLayer[]>, options?: {timeline?: boolean; vectors?: boolean}): void;
  lifecycle(hooks: NotebookProgramLifecycle): void;
};

interface NotebookVectorLayer { svg: string; frame: {x: number; y: number; width: number; height: number}; }
