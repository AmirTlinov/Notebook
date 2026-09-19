/** Browser program API, separate from the QuickJS nb command API. */
type NotebookJSON = null | boolean | number | string | NotebookJSON[] | {[key: string]: NotebookJSON};
interface NotebookProgramLifecycle {
  pause?(context: {signal: AbortSignal}): void | Promise<void>;
  checkpoint?(context: {signal: AbortSignal}): NotebookJSON | Promise<NotebookJSON>;
  resume?(context: {signal: AbortSignal}): void | Promise<void>;
  dispose?(): void | Promise<void>;
}
declare const notebook: {
  readonly version: 'NotebookProgram/1';
  readonly state: NotebookJSON;
  /** Local admission only, not a durable-save receipt. False while suspended/disposed or unchanged. */
  commit(value: NotebookJSON): boolean;
  ready<T>(completion: PromiseLike<T> | T): Promise<T>;
  lifecycle(hooks: NotebookProgramLifecycle): void;
};
