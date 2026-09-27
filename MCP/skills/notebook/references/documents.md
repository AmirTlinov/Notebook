# Writing LaTeX documents

The document is an addressed file tree. `main.tex` is complete ordinary LaTeX:
it owns the preamble, order, paper dimensions, margins and columns. There are
no Markdown blocks or separately stored preamble.

- `nb.document({id})` reads a directory without file bodies.
- `nb.document({id,fileID})` reads one file and its exact `sourceVersion`.
- `nb.documentStructure({id})` reads a derived section/label/reference index.
  Source positions are one-based lines and zero-based UTF-16 offsets.
- `nb.read({kind:'document',id})` explicitly reads the complete source snapshot.

Use one `nb.transaction(key,{base,summary,operations})` for related changes:
`putDocumentFile`, `patchDocumentFile`, `renameDocumentFile`, `removeDocumentFile`.
Each addresses a stable file ID. `expectedVersion:null` creates a new file;
replacement, rename and removal use the version just read. A patch additionally
requires `range:{location,length}`, exact `expectedText` and replacement `source`.
Offsets match JavaScript string indexing. Never reconstruct a version or silently
refresh it: a concurrent edit to that file must remain visible to the author.

## Prepare from local source

`prepare.mjs document` accepts:

- New document: `target:{kind:'board',id}`, board `anchor`, optional `title`,
  `entrypoint` and `files:[{id?,path,source}]`. `source` or `sourcePath` is a
  shorthand for the entrypoint file; each file can use `sourcePath` relative to
  the input JSON. Device paths are consumed locally and never become document paths.
- A template instead of files: `template:'article'|'report'|'contract'|'instruction'|'book'`.
  The Core template owner creates ordinary freely editable source files.
- Existing document: `target:{kind:'document',id}` and explicit files with
  `expectedVersion`, or `edit:{fileID,expectedVersion,range,expectedText,source}`.
  Other files remain unchanged. Rename references and their target in one transaction.

Binary files use `resource:{path,mimeType,byteCount,parts}` referencing admitted
SHA blobs; their `source` is empty. Relative paths cannot leave the document.

## Add and read a binary resource

For an image or PDF, prepare `{"sourcePath":"chart.png","path":"figures/chart.png"}`:

```sh
node ~/.codex/skills/notebook/scripts/prepare.mjs document-resource input.json request.json
node ~/.codex/skills/notebook/scripts/submit.mjs request.json
```

Preparation hashes the exact local file, up to 16 MiB. The trusted
`notebook_import_document_resource({filePath,path,sha256})` returns
`{status:'ready',sha256,resource}` from the native immutable-blob owner. It does
not create a document, execute a program, or save a content change. Reuse the
same request after a timeout. Pass its `resource` to a normal transaction:

```js
const source=await nb.document({id:args.documentID});
await emit(await nb.transaction('add-chart',{
  base:source.basis,summary:'Иллюстрация',operations:[{
    kind:'putDocumentFile',target:{kind:'document',id:args.documentID},id:'chart',
    values:{path:args.resource.path,resource:args.resource,expectedVersion:null}
  }]
}));
```

For replacement use the current file's `sourceVersion`, not null. Add the
`\includegraphics{figures/chart.png}` source edit in the same transaction when
needed. The entire document remains limited to 16 MiB, including all resources.
No dummy HTML/JavaScript entrypoint or `.notex` repack is required.

To read real bytes explicitly, retain the addressed file version and request a
window. Use 64 KiB chunks when emitting them (each output event is limited to
256 KiB); the native read maximum is 1 MiB:

```js
const file=await nb.document({id:args.documentID,fileID:'chart'});
if(!file.data) throw Error('File missing');
await emit(await nb.document({id:args.documentID,fileID:'chart',bytes:{
  sourceVersion:file.data.sourceVersion,offset:0,maxBytes:65536
}}));
```

The result contains base64, offset, byteCount, totalBytes, eof and the same
sourceVersion. Continue with offset+byteCount and that version. A changed file
fails `file_conflict`; never silently combine chunks from different versions.
Directory and ordinary file reads do not include binary bytes.

## Live illustration

Load `\usepackage{notebook}` in the source and place:

```tex
\begin{figure}
\NotebookInteractive[id=oscillator,width=\linewidth,height=240bp]{programs/oscillator}
\caption{Колебания}\label{fig:oscillator}
\end{figure}
```

Keep program files under the named directory. `program.json` describes relative
`html`, `css`, `javaScript`, `module` and `initialState`; without it, the defaults
are `index.html`, `style.css`, `main.js`. Programs receive `NotebookProgram/1`,
not the agent `nb` API. Their state is separate from source and TeX geometry.
`nb.read({kind:'documentProgram',id,instanceID,programPath})` reads the exact
`sourceBasis`, initial and saved state plus its opaque causal `stateVersion`
without execution. Keep this state version intact; it is not a file CAS token. `setDocumentProgramState`
uses that returned basis and path, never a file version or page geometry.

`nb.documentCheck({id,expectedRevision,pageIndex})` reuses the exact native render request.
Use the document owner revision from the directory/file read basis, not the
reference hash. Pass its `buildID` to `nb.render({...,expectedBuildID})` when
showing the checked result; a different compilation fails `build_changed`.
Only a ready result with the canonical `buildID` certifies compilation;
`pageIndex` chooses the zero-based canonical page (default 0). `programs` lists
instanceID, optional sourceBasis, status ready/failed/not_checked and scope startup.
Only instances on the chosen page are checked: ready requires initialization
evidence, failed reports configuration/startup errors; all others remain not_checked. Startup does not certify gestures or later animation. Before
a compiled map exists the list is empty. Failed startup retains readable PDF
pixels and their exact buildID alongside diagnostics.
`nb.render` and `nb.export` use the existing native presentation/export owners.
An exact source snapshot, successful compilation, saved program state and actual
iPad presentation are different facts; report only the boundary checked.

## Передача

`nb.export('portable',{documentID,format:'package'})` создаёт один `.notex`
ZIP с исходниками, ресурсами и состоянием. Скопируйте файл и вызовите
`node ~/.codex/skills/notebook/scripts/submit.mjs /absolute/path/document.notex`.
Импорт проверяет пути и хеши, создаёт новую копию штатной транзакцией и не запускает
программы. При потере ответа повторите сохранённый CLI request JSON с тем же `id`.
