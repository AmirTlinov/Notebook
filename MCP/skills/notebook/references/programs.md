# TypeScript, библиотеки и файловая программа

`prepare.mjs program` с `entry` проверяет TS и собирает обычный browser module.
Без `entry` он по-прежнему принимает уже готовые `files`, `html`, `css`,
`javaScript`. Это author-side CLI, не расширение возможностей QuickJS `nb`.

## Подготовка

Рядом с исходниками создай `build.json`:

```json
{"directory":".","entry":"main.ts","html":"view.html","workers":{"solver":"solver.ts"},"assets":["data.csv"]}
```

Поля `html`, `workers`, `assets`, `tsconfig` необязательны. `html` — body-фрагмент,
не второй документ. JS/TS imports, CSS imports и CSS `url()` входят в пакет.
Изображения, шрифты, аудио, видео, WASM, glTF/GLB, CSV и binary imports возвращают
локальный URL; файлы копируются/хешируются потоком, не становятся base64 в JS.
JSON import остаётся обычным модулем. Неиспользуемые файлы не включаются.
Явные `assets` сохраняют свой относительный путь, включая соседние файлы glTF.

```ts
import './style.css';
import picture from './picture.svg';
const image = new Image();
image.src = picture;
document.body.append(image);
const worker = new Worker(new URL('./worker-solver.js', import.meta.url), {type:'module'});
notebook.ready(image.decode());
notebook.lifecycle({dispose: () => worker.terminate()});
```

Ключ `workers.solver` задаёт выход `worker-solver.js`; workers объявляются явно,
не угадываются по строкам. Они проверяются с WebWorker types отдельно от DOM.
Используй общий lifecycle для паузы/checkpoint/dispose своей модели; один лишь
`dispose` в этом минимальном фрагменте не реализует lifecycle вычислительной сцены.
Браузерный `notebook` описан в [notebook-browser.d.ts](notebook-browser.d.ts).

```sh
node ~/.codex/skills/notebook/scripts/prepare.mjs program build.json prepared.json
node ~/.codex/skills/notebook/scripts/program-preview.mjs prepared.json
```

Вторая команда печатает случайный URL на `127.0.0.1` и держит preview до Ctrl+C.
Он обслуживает **только подготовленный package namespace**, не project directory.
Модули/worker/media требуют HTTP в обычном браузере; опубликованному Notebook
этот сервер не нужен. CSP запрещает внешнюю сеть и распространяется на workers.
Preview не подключается к Notebook и не сохраняет state на диск.

## Версии, зависимости и ошибки

Toolchain — имеющиеся pinned TypeScript **7.0.2 CLI** и esbuild **0.28.2** в MCP.
Сборка не запускает npm, package scripts и сетевую установку. Проект может
использовать любую совместимую browser library, не whitelist; её обычные
`node_modules` и `package-lock.json` должны уже присутствовать. У использованного
пакета должны совпасть version и запись integrity в lock. Дополнительно в
`notebook-build.json` записываются SHA фактически использованных исходников;
это не повторная проверка npm tarball по integrity. Node/server-only модули
не превращаются автоматически в browser APIs.

`tsconfig` явно указывает авторский config; inherited options разрешаются CLI.
Target ES2022, ESM, browser, strict/noEmit и наборы DOM/WebWorker принадлежат
этому маршруту, а не QuickJS compiler. Type errors возвращают JSON с `stage`,
`file`, `line`, `column`, `message`; неудача не записывает prepared.json и не
затрагивает старый пакет/документ.

В пакете есть linked source maps с исходниками. Preview печатает runtime и ready
ошибки в stderr; если stack содержит позицию bundle, диагностика показывает
авторский файл/строку. Для исключения без stack или карты остаётся явная generated
позиция, не выдуманная строка TS. Готовность не ставится после runtime error.

`window.notebookPreview` содержит `runtime: local-browser`, API, package hash,
build key и SHA текущего bridge. Это не версия установленного приложения.
Для сравнения прочитай SHA `WebResources/notebook-program.js` нужной installed
сборки; `NOTEBOOK_PROGRAM_BRIDGE` позволяет явно выбрать именно этот файл.
Preview использует прежний `createNotebookProgram`, но его transport локальный.
Он не доказывает запись, доставку, WK/iPad или аппаратную производительность.

`.notebook/program-builds/` — производный локальный cache. Повтор проверяет типы
и входные identities, но при совпадении не запускает bundler, не копирует и не
хеширует заново большие assets. Key включает используемые source bytes,
resolved config, compiler/builder/bridge. Изменение источника снимает hit. Новое имя файла в resolver-окружении
требует повторного разрешения graph/bundle; если получен прежний semantic key,
готовый пакет переиспользуется без копирования assets. Так сохранённый рядом
`prepared.json` не заставляет повторно выпускать те же тяжёлые байты. Готовые директории неизменяемы: параллельный build не
удаляет пакет, который сейчас читает importer. Cache можно удалить, когда его
prepared descriptors больше не используются; это не авторские исходники.

## Публикация

```sh
node ~/.codex/skills/notebook/scripts/submit.mjs prepared.json
```

`ready` здесь означает только staging bytes. Скопируй `packageHash` в обычный
animation input (не source bytes):

```json
{"target":{"kind":"page","id":"PAGE_ID"},"title":"Моя TS-модель","programPackage":"PACKAGE_SHA256","offset":{"x":40,"y":80},"width":760,"height":560,"initialState":{"phase":0}}
```

```sh
node ~/.codex/skills/notebook/scripts/prepare.mjs animation input.json publication.json
node ~/.codex/skills/notebook/scripts/submit.mjs publication.json
```

Для документа выбери `target.kind: document` и `afterID`, для доски `board` и
`anchor`. При исправлении существующего элемента не создавай дубликат: прочитай
его свежую `basis`, затем обычной `nb.transaction` сделай `updateElement` либо
`updateBlock` с новым `programPackage` и пустыми inline source/html/css/javaScript.
CAS должен сохранить параллельную человеческую правку; не повторяй конфликт
с новой basis вслепую. State/геометрия не требуют пересборки программы.

Development GUI-242/243 требует совместимой package-aware пары приложений;
установленная release 116 её ещё не содержит. Не выдавай preview или staging
за показ этой версии на текущей установленной паре.
