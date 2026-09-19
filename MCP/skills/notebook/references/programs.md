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

## Плотные данные, Plot и изолированная формула

В той же библиотеке science есть asset-backed `signal` («Не потерять короткое
событие»). Шесть inline examples и 3D-рецепт `gears` не грузят Plot/MathJax.
Для author checkout установи ровно lockfile-зависимости (`cd MCP && npm ci`),
затем передай `{"example":"signal"}` в `prepare.mjs program`. Preview и
двухфазная публикация выше те же; рекомендуемый frame — 760 × 1050, для документа
высота по доступному листу. Невысокий фрагмент прокручивается внутри собственной
focusable области, не перемещая доску. Это явный finger-input owner, а не
фиктивный pointer listener; Pencil/камера остаются у native host.

`assets/science/signal/` — обычные TS/HTML/CSS/data, не новая schema графика:

- 100 000 float32-le отсчётов, 1000 Гц, seed 20260919; статические source bytes
  400 000 B. Генератор `node --import tsx skills/notebook/assets/science/signal/generate.mjs`
  запускается из MCP только при авторском изменении данных, никогда на каждый кадр.
- Canvas получает 8 000 B min–max envelope (100 samples/bin). Если экран уже,
  объединяются экстремумы целых bins; это не точечный sampling. Порядок значений
  внутри 100 мс потерян в обзоре и явно объяснён; исходники сохранены.
- Plot 0.6.17 получает HTTP/asset Range только выбранных 50–4000 точек, не весь
  массив и не 100k DOM marks. Один запрос, отмена устаревшего, последнее окно;
  resize/theme используют уже прочитанный массив. Ошибка диапазона явная, есть retry.
- MathJax 4.1.3, assistive MathML и все локальные SVG glyph modules включены в
  namespace программы вместе с лицензиями. Формула вычислена по тому же массиву,
  не по прореженному обзору. `tex2svgPromise` + `startup.document.reset/updateDocument`
  устанавливают собственные стили; родительский document-shell не используется.
- Сохраняется только `{center,span}`. Lifecycle останавливает ввод/запрос,
  checkpoint забирает последнюю явную selection, resume не создаёт новый сигнал,
  `notebookstate` применяет внешнее состояние без обратного commit.

Данные синтетические; 3-sample импульс добавлен намеренно, не выдан за реальное
измерение. Для других собственных TS-проектов импортируй нужные browser libraries
обычно и фиксируй их lockfile, а не копируй этот recipe как обязательный renderer.


## Трёхмерный механизм

Прежний `gears` заменён asset-backed Three.js 0.186.0/WebGL 2 рецептом:
`{"example":"gears"}` в `prepare.mjs program`, затем тот же preview/submit.
Старого inline WebGL renderer больше нет. В пакете glTF 2, геометрия 8.4 MB,
две собственные текстуры 2048², статический SVG-план, Three и его лицензия.
Сеть/CDN и отдельный native 3D runtime не нужны.

`assets/science/gears/design.json` задаёт 60/40/24 зуба, модуль 2 мм и 20° угол
давления. `generate.py` создаёт исходную Blender-сцену, glTF, текстуры и poster;
геометрия — 144 332 треугольника. glTF использует метры, учебные подписи — мм.
Рабочие стороны зубьев эвольвентные, корневые переходы упрощены: это не CAD
производственного качества и не симуляция трения. Вращение и поле скоростей
получены из одной модели; раскрытие поднимает только верхнюю опору, не оси.

- Orbit/pinch, клавиатура и выбор видимого колеса используют существующую
  focusable область и native finger owner. Ближайшая непрозрачная деталь
  перекрывает raycast: нельзя выбрать колесо сквозь опору.
- `{phase,reveal,selected,field,camera}` — явный checkpoint; геометрия и heap
  не сериализуются. `input/idler/output` — стабильные IDs деталей.
- Статический кадр рисуется до startup ready и при checkpoint даже при
  offscreen-подготовке. Непрерывные кадры запрашивает только явный Play.
  DPR ограничен 2 и 1600 pixels по длинной стороне; resize не перечитывает glTF.
- Потеря WebGL сохраняет состояние и останавливает Play; восстановление
  пересоздаёт окружение в том же renderer. Dispose освобождает геометрию,
  материалы, текстуры, ImageBitmap и временные instanced buffers окружения.
- Один loading promise, отмена fetch/loader и закрытие поздних decoded bitmap
  не дают удалённой сцене вернуться. Неверная модель/текстура дают локальный
  retry; отсутствие WebGL 2 — явно подписанный статический план, **не 3D**.
  Ready означает готовый UI с результатом или явной ошибкой, не успех модели.

Рекомендуемый frame 760 × 1050; на коротком фрагменте управляющая область
прокручивается локально. Browser preview не является приёмкой native GPU,
доставки или производительности; точная область проверок — `docs/verification.md`.
