# GUI-305: доказательства аудита 25.09.2026

[Основной отчёт](/Users/amir/Documents/projects/Notebook/docs/audit-2026-09-25.md).
База кода: `29c6a1e7900b0b95f8754bc6d7bf19da228f4424`; поздний параллельный
chat/Codex diff отдельно прочитан и отражён вместе с SHA в
[source-manifest.json](/Users/amir/Documents/projects/Notebook/docs/audit-evidence/2026-09-25/source-manifest.json).

Это **исторические диагностические пробы**, не добавленный acceptance suite.
Часть probes намеренно утверждает наличие дефекта на этом срезе: после исправления
их надо пересмотреть, а не сохранять ошибку ради «зелёного» результата.
Не применять их как patch приложения и не запускать с пользовательской базой.
Бинарники, сгенерированные большие fixtures, библиотеки и копия изменённого
нормализатора остаются только во временных каталогах; в Git их нет.

## Условия и точные границы

- macOS arm64, оптимизированный Swift 6.4; актуальные Core/Codex скомпилированы
  отдельно через `swiftc`, без SPM/Xcode/приложения/симулятора. Core создаёт каждый
  `NotebookStore(root:)` явно в новой временной директории и удаляет только её.
- `core.swift` исполняет настоящий Core. `sqlite3_progress_handler` считает каждую
  VM-инструкцию и добавляет overhead: timing не является latency приложения.
  100k fixture — ID и canonical nodes порядка страниц, не 100k PageDocument.
- `file-upload.swift` исполняет настоящие staging/readback API. Суммы BLOB bytes
  вычислены из точных SQL-аргументов алгоритма, не измеряют физическую запись SSD.
- `sidecar.swift` использует настоящие Sidecar, PersistenceQueue, Core и смежные
  Mac-контроллеры; native Codex executor — fake из текущего test fixture с учётом
  attach/detach/interrupt. Ни Codex App Server, ни модель, ни реальная задача не
  запускались. Лимит девяти состояний AppServer проверен кодом, не live-сессией.
- `lasso.swift` — extract алгоритма с distance counter и модель Contact COW;
  adversarial зубчатая линия допустима, но не представляет каждый человеческий
  жест. В двух прогонах 4096 точек заняли 138/163ms, 8192 — 538/697ms. В файле
  результата сохранён второй прогон; visits детерминированы, times нет.
- `markup-queue.swift` — точный actor очереди с fake 100ms normalizer. Результат
  доказывает отсутствие cancellation propagation, не фактические 32s XPC delay.
- `chat-render.cjs` исполняет текущую функцию chat-shell с DOM/Markdown/MathJax
  counting doubles. Это число повторных операций и потеря DOM identity, не FPS.
- `program.cjs` исполняет текущий JS bridge: transient error, timeout, recovery,
  большой state. Native Retry caller разобран в отчёте, iPad не запускался.
- `public-transport.mjs` собирает текущий MCP bundle в временную `.app`-оболочку
  с metadata и запускает checked-in CLI. Проверяется tools/list; нет Mac process,
  IPC socket или workspace. Exact acceptance bundle ID выбран намеренно, чтобы
  дойти до второго, независимого inventory mismatch.
- `cloud-order.py` — exact SQL в `:memory:` с заранее заполненной очередью;
  progress callback каждые 1000 VM. В production children добавляются постепенно;
  это не полное измерение Cloud export. `cloud-order-result.json` — первый вывод.
- `quickjs-ab.sh` использует CQuickJS проекта и production параметры canonical
  typesetter: 64MiB heap, 1MiB stack, 2s budget, 24MiB result limit. Меняет один
  restore-loop только в временной копии. Сравнивает весь result через Node deep
  equality, не только длину. Не вызывает TeX compile. `markup-result.txt` — первый
  A/B, `quickjs-recipe-result.txt` — повтор самодостаточного рецепта. Повтор на
  16000 formulas тоже прерван на строке 9480; измеренный CPU всего probe, включая
  bootstrap, 2,98s против первых 2,02s. Это не точная пользовательская задержка.

## Воспроизведение

Нужны штатные local Swift/Clang, Python3, Node и уже установленные зависимости
MCP из lockfile. Скрипты не устанавливают пакеты и не меняют приложение.
Запускать на указанном Git-срезе либо заново проверить changed sources.

```sh
cd /Users/amir/Documents/projects/Notebook
E=docs/audit-evidence/2026-09-25

# Current Core + real Sidecar owner, isolated fixtures; no Xcode runner.
bash "$E/reproduce-swift.sh" "$PWD"

# Small independent source-level probes.
node "$E/chat-render.cjs" "$PWD"
node "$E/program.cjs" "$PWD"
node "$E/public-transport.mjs" "$PWD"
python3 "$E/cloud-order.py"

# Native canonical-normalizer A/B. Creates its C driver and fixtures in /tmp.
bash "$E/quickjs-ab.sh" "$PWD"

# Existing focused checks actually executed during the audit.
MCP/node_modules/.bin/tsx --test \
  MCP/test/sidecar-bundle.test.ts MCP/test/portable-document.test.ts
node --test Relay/relay.test.mjs
```

Swift-рецепт объединяет использованные команды компиляции; составляющие его
пробы выполнялись отдельно. Сохранены именно эти наблюдения, а не выдуманный
вывод последующего общего запуска. При упаковке `core.swift` изменён только
путь временного fixture: он больше не требует существования внешнего каталога.
Sidecar/Codex после поздних параллельных изменений пересобраны и повторены;
первое наблюдение — `sidecar-result.txt`, повтор — `sidecar-latest-result.txt`.

## Результат выбранных проверок

- MCP **5 PASS, 0 FAIL, 0 SKIP** — `mcp-focused-tests.txt`.
- Relay **4 PASS, 0 FAIL, 0 SKIP**, только local loopback — `relay-tests.txt`.
- Source compile Core/Codex и real Sidecar probe — успешно; **это не app build**.
- Defect probes воспроизвели условия из основного отчёта. Их наличие не даёт
  оснований отмечать production bugs как исправленные.

Пользовательские данные и установки не трогались. Physical iPad/Mac UI acceptance,
system frames, application CPU/GPU/RSS и длительная совместная работа отсутствуют.
