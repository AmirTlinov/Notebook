# Текущее состояние проверки Notebook

**8 октября 2026, GUI-535.** Установлена подписанная пара **265 / 0.3.195**,
прямой MCP **0.3.43**. Рабочая поверхность — нативный iPad; Mac headless runtime
читает и меняет то же пространство. Контейнеры, SQLite, identities и keys
сохранены; DB29/wire44/manifest26 остаются текущими, вся авторская история
сохраняется бессрочно.

Выбранные проверки: **61 Core functions / 7 suites, 230 MCP cases, 30 physical
iPad и 14 Mac scenarios PASS**, без skips и native runtime warnings. Core/MCP
проверены до десяти последующих native-only правок. После physical iPad30/30
изменены четыре строки одного Mac-only fixture; его повтор1/1PASS. Точные
исходники, дельты и исходные отказы сохранены
[в evidence](audit-evidence/2026-10-08/history-readiness/results.json).

Повторная real-TLS проверка удерживает настоящий directory read responder до
получения следующего peer frame: **physical iPad1/1 и Mac1/1 PASS** на исходниках
264. Admission выполняется до первого await; teardown сохраняет первый отказ.
Оба успешных сценария подтверждают12roots и возобновление тех же владельцев.

Installed MCP публикует семь инструментов без UI/resources. Подтверждены
account directory двух устройств, selected trusted TLS session, текущие native
presence/presentation и изображение iPad. Совместный history request
`ea51b97e-0c97-4831-995b-fdb34e7d4a74` завершился отказом: системный журнал
зафиксировал потерю маршрута awdl0 и TCP keepalive timeout. Cleanup вернул
native admission в `open`; формат не изменялся.

Live264 request `2121dec9-b34c-4c8b-8335-dd9af7d86ff6` дошёл до чтения истории,
затем завершился `historyCutStale`. Selected TLS `B375A8C0…` остался тем же READY,
revision и accepted prefix совпали до/после; native admission вернулся в `open`.
Первичный отказ peer теряется в terminal resume и пока не восстановлен.
Для265 существующий owner передаёт bounded typed refusal, сохраняет её источник
и этап, завершает чтение без отмены TLS-credit waiter и дренирует отправленные
страницы до peer resume. Публикация report требует успешного двустороннего join.
**2 новых Core-контракта и14 native функций (iPad9/Mac5) PASS**; исходный отказ
одной новой fixture исправлен через штатную очередь и проверен повторно.
Runtime265 не менялся между этими прогонами; изменён только этот test method.
Подписанная265 собрана и установлена из тех же исходников `0c2711be…`/1689.
Первое холодное подключение застало owner в `opening`; повторное подтвердило
готовый Mac runtime, семь direct MCP tools, phase `open` и directory обоих
устройств. После повторного запуска iPad был foreground15:47:11–18UTC,
получил AWDL `No network route`, переключился на Nofield и был приостановлен
в15:47:19.504UTC. Незавершённые TLS sessions освобождены штатно; ожидается
окно с открытым Notebook. Совместный запрос265 ещё не начат, двенадцать roots
не получены. Проверенный срез опубликован в общей `main`, `a6f8b73e`;
GUI-535 остаётся открытой.

**8 октября, GUI-498/NB32:** App Server удерживает pending thread IDs и поколения
состояний; единственный Host получает wake и атомарно забирает актуальные значения.
Поток одного разговора сохраняет terminal/approval другого без polling; disconnect
предшествует свежим состояниям. **29 SwiftPM функций / 34 случая и 1 Mac scenario
PASS**, без failures/skips. После трёх явных `Void?` annotations повторены только
новые 3 метода / 4 случая, без предупреждений. Production NB32 между прогонами
не менялся; Mac Host собран с новым API. Точные scopes и посторонние diagnostics
сохранены [в результате](audit-evidence/2026-10-08/codex-notification-delivery/results.json).
Установленная пара265 сохранена. NB28, DP16 и остальные критерии GUI-498 открыты.

**8 октября, GUI-498/DP17:** после частичной ошибки JavaScript следующая полная
публикация удаляет лишние body-map entries и сохраняет текущий article, focus и
selection. **18 DOM + 3 bundled MathJax cases PASS**, 0 failures/skips; 70 входов
`be1dc303…` неизменны. [Результат](audit-evidence/2026-10-08/chat-publication-retry/results.json)
относится к DOM и локальным engine/assets. Native Coordinator recovery и physical
iPad ещё не приняты; установленная пара265 сохранена.

**8 октября, GUI-498/NB28, DP15, DP17:** общий native cache ограничен 48 МиБ,
одна беседа 16 МиБ; transfer и WebKit удерживают credits до последнего фактического
borrower. Чтение истории сохраняет обе границы окна; старый attach отзывает только
свою попытку. **40 SwiftPM функций / 45 случаев, затем 5 прицельных функций и 6 Mac
scenarios PASS**, без failures/skips. В отдельном96-message прогоне RSS достиг
167788544 B, phys_footprint 135299936 B; после закрытия body counter 0. Это измерение
Swift process projection. iPad production и все test sources **скомпилированы**;
на устройстве выполнено 0 тестов. Проверки actual WK death, reading anchor, callback
credits и bundled MathJax подготовлены; physical acceptance остаётся открытой.
[Результаты, исходные отказы и дельты](audit-evidence/2026-10-08/codex-body-window/results.json).
Установленная пара 265 сохранена; DP16 и полная GUI-498 остаются открытыми.

**9 октября, GUI-494/NB10:** native Save готовит search recipe вне writer;
одна подготовка ≤64 МиБ сохраняет место реальному Pencil reserve192 МиБ.
Cancel/shutdown ждут физический worker; готовый plan входит в общий FIFO после
повторной проверки idle. Source/index/action/draft публикуются атомарно;
Unicode сохраняется буквально через editor, CAS, Undo/Redo.
**48 Core functions / 67 cases и8 native Mac scenarios PASS**, 0 failures/skips,
одинаковые1694 входа `bb9d0a5c…` до/после. Три отдельных Debug-пробы1 KiB/1 MiB/4 MiB
выполнили Save и конкурирующую ink-запись. Для4 MiB preparation665 мс вне writer,
writer1618 мс, ink wait1675 мс: задержка остаётся следующим исправлением NB10.
Это инструментированные однократные пробы при обычной нагрузке рабочего Mac.
Installed265 сохранена; physical iPad и полная приёмка этого слайса открыты.
[Результат, лимиты и исходный compiler refusal](audit-evidence/2026-10-09/native-source-save/results.json).

GUI-541 уже в общей `main`: плагины, marketplace-регистрации, панель, браузерная
отрисовка и Swift WASM адаптер удалены; GUI-539 отменён. Историческая подписанная
пара262 и sandbox repair сборщика описаны
[в отдельном результате](audit-evidence/2026-10-08/plugin-removal/results.json).

Полная приёмка GUI-190 остаётся открыта: десять повторений, 30 минут совместной
работы, системные frame/CPU/GPU/memory и контрактные задержки. `saved`,
`receivedByIPad` и `shownOnIPad` проверяются отдельно.

## Ранее проверенные владельцы

Каждый результат ниже относится к указанным исходникам. Он не устанавливает
приёмку текущей пары. Полный журнал панели и выпусков до261 сохранён
[в Git](https://github.com/AmirTlinov/Notebook/blob/39ea6c7d30c3856be0254628ac52f5a8cf4a2b25/docs/verification.md).
Панельные критерии прежнего плана отменены; задачи нативного ввода, документов,
синхронизации и причинного содержания продолжаются в Linear.

**8 октября, file uploads:** начало новой загрузки сохраняет старые prefix и
полные draft/conflict payloads всех авторов; возраст и terminal job не доказывают
retirement. Убран TTL DELETE, лимит32 отказывает без удаления данных.
**4 Core PASS**, 0 failures/skips, source `b349160c…`/1717 до/после одинаков.
Проверены exact bytes после reopen/resume и максимальный incremental IO:
5592552 bytes / 114 chunks, прочитаны5592552 bytes / 9267 VM steps.
[Scope и причина](audit-evidence/2026-10-08/file-upload-preservation/results.json).
Срез сохраняет format29; installed/physical и полный cleanup остаются открытыми.

**8 октября, GUI-504:** `storageUsage` читает bounded metadata одного committed
SQLite snapshot; readonly admission отвергает missing/old format до изменения БД.
Тела blobs не читаются; история сохранена, physical DB/WAL/SHM — отдельные samples.
**17 Core/ScriptHost functions / 18 cases и 12 SDK cases + TypeScript PASS**,
0 failures/skips; source `c6ddf18e…`/1717 (Core), `cf343108…`/1717 (SDK) неизменен.
Между ними изменены только три Python-файла сборщика; production/tests совпадают.
Проверены 100000 history rows, cancellation, finite nested SQL lease, recovery и
current-format admission. Очистка и installed/physical acceptance ещё открыты.
[Точные исходники, scope и исправленные отказы](audit-evidence/2026-10-08/storage-diagnostics/results.json).

**8 октября, Swift inventory:** machine reports пишутся в отдельный файл каждого
выбранного test product; доступные продукты берутся из SwiftPM description.
Прежний stdout потерял UTF-8 chunk 8192 байта и склеил две Core JSON-строки.
**31 Python PASS**; реальные inventory probes — Core **1643 записи / 1443 функции**,
ScriptHost **54 / 42**, оба exit0, без malformed records. Это discovery из готовой
сборки source `cf343108…`/1717; Swift test execution и Native в этот scope не входят.
[Причина, точные команды и hashes](audit-evidence/2026-10-08/verification-product-stream/results.json).

## Причинное содержание — GUI-507, 7 октября

`CollaborativeContent` собирает adoption по изменённым адресам и восстанавливает
member bodies одним временным проходом. Прежние вложенные scans удалены; версии,
observed frontiers, tombstones и канонический порядок сохраняет тот же owner.
**10 чистых Core-проверок PASS**, без пропусков и предупреждений. 42 причинных
снимка до/после совпали побайтно: конкурентные insert/edit/delete, скрытая голова,
повторы доставки и причинная обратная запись. Устаревший ключ document fixture
`blocks/body/content` заменён на `files/body/content`; исходный owner давал те же
24 отказы этого fixture.

Оптимизированный host/Core probe: три повтора после ремонта, времена — медианы.

| Нагрузка | 1 000 | 4 097 | 100 000 | Peak RSS на 100k |
| --- | ---: | ---: | ---: | ---: |
| Sparse record | 59,96 мс | 264,81 мс | 7,76 с | 994 МиБ |
| Bulk record | 60,93 мс | 283,00 мс | 7,62 с | 1 054 МиБ |
| Merge фигур | 86,96 мс | 387,19 мс | 11,45 с | 1 652 МиБ |
| Merge плоских полей | 4,55 мс | 17,14 мс | 600,24 мс | 176 МиБ |

Исходный merge 4 097 фигур занимал 3,25 с в этом Release probe; все четыре
исходные нагрузки 100k остановлены по лимиту 30 с. 100k фигур создают 1 000 001
поле и проверяют чистого владельца за пределом сохранённого admission 100k полей;
отдельная строка проверяет ровно 100k полей. Адресные проходы линейны; сортировка
непредпочтительных concurrent survivors сохранена. Массовая работа остаётся на
worker существующей FIFO. Исходники неизменны во время каждого замера. Срез
отдельный от 254; аппаратный контракт ввода 20 мс здесь не измерялся.
[Исходники, CPU/RSS, повторы и точный scope](audit-evidence/2026-10-07/causal-content-scaling/results.json).

## Открытые измерения

- **Перемещение выделенного тела, GUI-524.** Физический optimized replay: 120
  запросов позы, один moving body с неизменным видимым соседом. При 1/100000
  чужих тел вне crop scheduled→next advancing pose OS p95 **78,23/608,24 мс**;
  показаны 39/4 точные позы, вытесненные запросы сохранены. Pixel/receipt проверки
  **1 PASS**, без skip/runtime warnings, исходники неизменны. Подготовка отдельно
  **47/5976 мс**, footprint при 100k **776,54 MB** при учтённых **22,81 MB**.
  Кандидат с адресными immutable plan/geometry/index roots: **15 Core PASS,
  4 native iPad PASS**, p95 **63,52/66,51 мс**, backlog при 100k **1,28 мс**
  вместо **196,41 мс**. Тот же harness и все 120 запросов; конечные pixels
  проверены. Подготовка 100k остаётся **6317 мс**, footprint **761,10 MB**.
  После lazy materials/inline rectangle clips (GUI-525): **7 native PASS**,
  p95 **63,15/64,56 мс**, подготовка 100k **1390 мс**, footprint **611,70 MB**,
  учтено **8,41 MB**. Polygon offcrop→new cut→cancel проверен четырьмя exact
  OS receipts и pixels; исходники неизменны. Это одиночные замеры, SQL/model
  сборка чужих тел вне replay. More исправлен через control intent (GUI-527);
  UI v4 **1 PASS**, без skip/runtime warnings: select/move/align/duplicate/delete,
  cold reopen→select→node+connector move; соседний WebKit живой. V2 ожидал
  ручку whole group для отдельных elements, v3 тащил невыбранный узел до
  требуемого pickup hold; исправлены только эти два ожидания сценария.
  Production259 (app0.3.189/plugin0.2.11) установлена; build/source hash chain
  и включение исправлений проверены, код опубликован в `main`.
  [Baseline, фазы и все запросы](audit-evidence/2026-10-07/selection-pose/baseline.json).
  [Адресный кандидат](audit-evidence/2026-10-07/selection-pose/addressed-index.json).
  [Lazy clips, polygon и все запросы](audit-evidence/2026-10-07/selection-pose/lazy-clips.json).
  [Меню и полный page gesture](audit-evidence/2026-10-07/selection-pose/menu-gesture.json).
  GUI-528: captured values переведены на линейный `Sequence`, rank API удалён.
  **3 Core + 1 native PASS на физическом iPad**, 0 skip/runtime warnings;
  исходники неизменны. При 100k подготовка **1389,84 мс** (ранее 1390,06),
  initial install **481,56 мс**,
  p95 **64,71 мс**, footprint **614,01 MB**. Ускорение подготовки не измерено;
  нужен профиль её затрат. Все 120 запросов и exact OS receipts сохранены,
  initial/final pixels корректны. GUI-528 пока вне installed259.
  [Линейный обход, фазы и все запросы](audit-evidence/2026-10-07/selection-pose/linear-values.json).
  GUI-530: единственный совместный CPU/Allocations профиль получил start notification,
  затем отказ `Allocations cannot handle a target type of 'All Processes'`, exit 2.
  Отдельный native XCTest **1 PASS**, 0 skips/runtime warnings; исходники неизменны,
  test bundle удалён, runners закрыты. Общая попытка exit 1: attribution затрат отсутствует.
  Повторной записи не было; следующий маршрут требует адресного процесса и начала
  подготовки после подключения профиля.
  [Отказ профиля и точный scope](audit-evidence/2026-10-07/selection-pose/cold-profile-coverage.json).
- **Pencil/eraser, ≤ 20 мс по контракту.** Настоящий Pencil в установленной 253:
  6880 input batches, без потерь событий/сэмплов и ошибок записи; actual→OS
  pen/eraser p95 **57,39/57,43 мс**, 118 unresolved lift batches. GPU execution
  p95 **0,51/13,62 мс**; стоимость ластика растёт внутри длинного контакта.
  Все 1723 кадра с UI-данными идут в normal-фазе без low-latency/immediate
  presentation. Проверяются участие текущего UIKit update и повторная отрисовка
  области ластика. Накладные расходы trace не откалиброваны; бюджет не принят.
  [Фазы, OS receipts и точный baseline](audit-evidence/2026-10-07/product-quality-baseline/pencil-253.json).
  Candidate `9a907c0b` с последующими исправлениями: физический v3b **10 PASS / 4 FAIL**,
  без runtime warnings; прежний [v2](audit-evidence/2026-10-07/product-quality-baseline/native-candidate.json) — 7/6.
  Синтетический 120 Hz pen/eraser p95
  **32,34/41,15 мс**, GPU deadline misses0; основной хвост ластика приходится
  на первые13 входов. Это не сравнение с настоящим Pencil253.
  Crash одного нового pixel-сценария локализован в недопустимой геометрии fixture;
  исправленный v6 на iPad **1 PASS / 0 FAIL**, 0,798 с, без runtime warnings,
  исходники неизменны между build и завершением. Финальная проверка маршрута
  отклонена из-за отдельной изменённой UI-фикстуры без жестового сценария.
  Ручной повтор v6 завершён без сохранённого input trace; результата latency нет.
  В ручном v9 checkpoint сохранился: одна общая activity, ноль Pencil samples;
  SQLite содержит только 80 исходных штрихов. Доставка ввода на тестовую страницу
  ещё не подтверждена, сравнения задержки нет.
  [Точные области проверки, фазы и отказы](audit-evidence/2026-10-07/product-quality-baseline/native-followup.json).
- **Холодное открытие документа, ≤ 1 с.** Междосочный цикл устранён; бумага и
  установленные слои проверяются до начала раскрытия. GUI-508 ускоряет загрузку
  формата TeX: Mac paired cold median **516,61 → 466,51 мс**, одинаковый PDF,
  два прохода TeX; проверки формата, отмены и восстановления PASS.
  Слайс вошёл в `main` как `f7af0e45`; повторная проверка 7 октября подтвердила
  неизменные pinned-входы и kernel, ASan/UBSan и runtime **1 PASS / 0 FAIL**,
  exact-source stage для Mac/iPad. [Проверка текущего main](audit-evidence/2026-10-07/product-quality-baseline/typesetter-current-main.json).
  После расчёта камеры для предстоящего кадра с завершением по реальному сроку
  физический v8 с уникальными исходниками: **5 PASS / 0 FAIL**, без runtime warnings;
  исходники неизменны. Native input на текущей доске **878,31 мс**, на другой —
  **986,33 мс**, native compiler **648,95 / 741,74 мс**. Оба открытия уложились в 1 с;
  прежний v7 дал **886,41 / 1037,96 мс**. Это одиночные сценарии, устойчивость
  бюджета остаётся открыта. Recorder отдельно подтверждает **57,04 / 61,80 мс**
  до подготовки печатного источника и **3,22 / 1,73 мс** от её конца до бумаги
  (другая/текущая доска). Физический UI v11: **1 PASS / 0 warnings**; холодный лист
  900×600 занимает одну полную сторону viewport с сохранением пропорций, проходит
  повороты и три быстрых reopen, сохраняет увеличение и положение после pinch.
  Системные снимки просмотрены; ошибка orientation/crop в `app.screenshot`
  устранена захватом экрана в тесте. [Жест, геометрия и снимки](audit-evidence/2026-10-07/product-quality-baseline/document-fit-ui.json).
  Эти кандидаты пока не входят в установленную 256.
  [Точный runtime, исходники и фазы v7/v8](audit-evidence/2026-10-07/product-quality-baseline/typesetter-cold.json).
- **Undo обложки, 100 мс.** Первый 252 native-прогон: **114,956 мс** и неверное первое
  изображение. После ремонта изображения два диагностических прохода дали
  **90,566 / 95,681 мс** до CA commit, inverse SQL **31,7–31,9 мс**. Функционального
  ускорения ещё нет; устойчивый предел и аппаратный показ открыты.
  [Разделение Undo и UIKit lifetime](audit-evidence/2026-10-06/menu-and-ink-diagnostic/results.json).
- **Cold documents/SVG/programs, Native24, first curl.** Строгие бюджеты,
  cold-process p95/p99, первый discard и ready-time WebKit IPC открыты.
  [Source clocks 240](audit-evidence/2026-10-01/cold-owner-240/cold-metrics.json),
  [одиночные замеры 246](audit-evidence/2026-10-05/print-binding/results.json).
- **Промежуточный mixed cut.** Итоговый снимок не доказывает все OS-кадры.
  В inverse-journey2009 GPU cut и receipt 23,023 мс содержали штрих, которого не
  показал drawHierarchy(false); independent display oracle остаётся открытым.
- **Системные frame/CPU/GPU/memory.** Текущая пара ещё не принята; прежние
  Time Profiler 2042 и logging-only 60s не дали пригодных измерений.

## 2026-10-06: NB13 immutable frozen-window address

Isolated baseline: main `b5e350288443921086d2487b9d3e08a72be6c802`. The existing
program owner now assigns a stored commit identity to each frozen descriptor.
Late reads cannot alias a new freeze after resume. Failed resume and idempotent
checkpoint retry retain the accepted address; numeric FIFO snapshots/ACK remain
unchanged. The shipped document adapter and all native files are unchanged.

The same 38 program tests fail twice against the baseline producer (36 PASS /
2 FAIL), including through the actual unchanged iframe adapter. The corrected
producer passes 38/38; combined program/chat checks pass58/58 and strict TypeScript
passes. Exact commands, source hashes and limits are in
[audit evidence](audit-evidence/2026-10-06/checkpoint-snapshot-identity/results.json).

This is independent of the still-unpublished native read-settlement proposal.
No producer API migration or memory-admission redesign is included. Native
Swift/WebKit/physical acceptance and installation have not been run here.

## 2026-10-07: remediation integration

13 Root commits joined with main through installed-258 evidence `594b99ee`.
Final checks: Core4 and physical iPad1 PASS; Mac5 PASS. Only a Mac test fixture
changed between those runs; executable Core/iPad inputs are unchanged. Earlier
20 Core functions/23 executions,68 Node and TypeScript retain their original scope.
[Exact sources, intersections and results](audit-evidence/2026-10-07/remediation-integration/results.json).
DB29/wire44/manifest26: search admission changes derived data in one transaction.
Birth/checkpoint WIP, a new integrated signed pair and joint acceptance remain pending.

## 2026-10-08: first received acceptance and the read cut

The existing commit owner advances `read_revision` once after the first accepted
delivery, including a material no-op. Known retries and relay ACKs retain that cut;
rollback and counter exhaustion preserve the marker, peer cursor and revision.
Selected Core checks pass: 10 functions / 11 cases, zero failures or skips,
unchanged source `ffa5ec39410fb1b8f5abe1ee45285c6122b6f9ffaaba38a392c0b0cb1197f8ef` / 1718 files.
[Evidence](audit-evidence/2026-10-08/received-acceptance-read-cut/results.json).
DB29/wire44/manifest26 and the installed pair are unchanged. Physical acceptance remains pending.

## 2026-10-08: accepted history bodies and bounded native replay

Original-body closure binds source-local original/model/result roots to the raw
delivery version, preserves unknown fields and compares every canonical fragment
through the existing streaming encoder. Missing or mismatched proof retains
incomplete coverage. Metadata summaries expose four witness hashes.
Cold ink pays actual codec nodes; cached restoration pays each output allocation.
Native replay uses the existing hash-bound model and immutable original result,
without copying authored receipts. Its allowance stays with the Panel writer.
DC05 removes three unused dependency visitors; live discovery/validators remain.

Selected Core: 54 functions / 99 cases PASS; isolated native IPC: 3 cases PASS;
strict TypeScript and generated declarations PASS. Core source
`6abc100c49baa928714c87a318c8cd9f187e6f80255be301f1f50ff5263d8fb3`, final MCP
`8a66b73e32aec6bf7351aa0e4d313937284c3c98715f0f4f61263e8be205119b` / 1726 files.
Only a TypeScript fixture existence assertion changed after Core; Core production
and tests stayed exact. Source and toolchain match within each run.
[Scope, attempts and known failures](audit-evidence/2026-10-08/history-body-and-native-replay/results.json);
[earlier preflight baseline](audit-evidence/2026-10-08/action-history-preflight/results.json).

The stage-v2 full65k diagnostic passed acceptance, cold replay and exact body read,
then refused at Undo. The original full scenario remains outside the final PASS
scope; clean common main f926 reproduces its earlier failure.
Full Undo needs immutable birth/event publication and exact measurement binding.
DB29/wire44/manifest26 and installed260 are unchanged. Fleet seal, birth proof,
Undo conversion and physical/joint acceptance remain open in GUI-486.

## 2026-10-08: declaration-only native wrappers

GUI-505 DC01/DC02/DC07/DC08: removed private page-save, immediate raster, Redo
and color wrappers; live publication, history, scheduler and Pencil owners remain.
Independent source review READY; 3 files, 0 additions / 52 deletions.
Selected Mac: 2 PASS, 0 failures/skips/runtime warnings. Physical iPad
build-for-testing PASS, signed for the designated device; 3 planned / 0 executed,
not installed. Xcode requires a concrete unlocked device for native inventory.
Both builds have identical source `0cbc76282b8ac8cd6e2bc4bc746386c412e5d6c53020a91c0ca8a445906f9604`
/ 1726 files, unchanged within each route. Installed260 and physical acceptance
remain unchanged. [Scope and pending checks](audit-evidence/2026-10-08/dead-native-owners/results.json).

## 2026-10-08: common receipt and memory owners

NB19/B16 memory admission is integrated into primary main, preserving the prior
native cleanup. The shared pool withdraws queued optional PDF work under pressure,
keeps required promotion and protects pins/physical tails. One Core merge owner
preserves immutable originals, complete Undo cuts, unknown raw fields and signed
zero; incompatible delivery rolls back without acceptance or ACK.

Selected Core: 20 functions / 37 cases PASS. Selected Mac: 19 PASS, zero
failures/skips/runtime warnings. Final source
`18e237019f81543422b379c46034107506b62b8c57a1c9068fc72f2db49b63b8` / 1731 files.
Core's executed component used `96046138ec1bcf082acd7d88e6f6187c04dc4bfd7a2c8b9580e37d18f19b57ce`;
only four callback argument labels in two App files changed afterward. Core inputs
and toolchain stayed exact; final Mac source is unchanged before/after its route.
[Results, source delta and failed attempts](audit-evidence/2026-10-08/common-main-memory-and-receipt-phase/results.json).
Physical iPad execution and raster100k acceptance await device unlock. Process/
WebContent budgets, joint measurements and convergent birth/Undo migration remain
open; DB29/wire44/manifest26 and the installed pair are unchanged.

## 2026-10-08: physical pressure and native handoffs

All 28 selected physical iPad scenarios have a passing route: the first run passed
25; two repaired fixtures then passed; the final geometry repair passed its one
remaining scenario. The first two failed routes and exact assertions are retained.
Fixtures now await cancellation/native input, transfer WebKit into its receiving
host, and use the measured paper aspect. Runtime inputs stayed exact;
only two iPad test files changed. Final source `ff125bf88cc249aa4b2ba24a7cf0420a5e0effba05aad48b894127cc4a2ab3f7`
/ 1731 files. Each route has unchanged sources/toolchain and no runtime warnings.
Raster100k passed; 1.052 s is test duration. [Cases and source intersections](audit-evidence/2026-10-08/common-main-ipad-pressure/results.json).
[Signed preparation and outer runner reseal](audit-evidence/2026-10-08/common-main-ipad-preparation/results.json).
All other checkout commits already belong to common main; this task's worktrees
are archived. Production pair 260 is unchanged. Process/WebContent budgets,
compositor publication cleanup, birth/Undo transition and full joint acceptance
remain open in Linear.

## 2026-10-08: compositor publication and current ink cache

`finishRaster` pins its new entry before synchronous publication observers.
Unused `PageInkRasterCache` and batch/split/transfer reservation APIs are removed;
live resize remains. Existing checks now use real compositor outputs and the
accepted page-ink material cache, preserving exact measured samples.
Mac2 and physical iPad5 passed with no failures, skips or runtime warnings.
Source `c651851853ad4e11826b78c2c536e85fef77ccd2b117f0283a3c8e5563790a5e`
/ 1730 files and toolchains stayed exact in both routes; test identities were
cleaned, production pair 260 is unchanged. [Cases and receipts](audit-evidence/2026-10-08/live-compositor-publication/results.json).
GUI-505's dead paths are removed. Process/WebContent budgets, birth/event Undo,
the coordinated format transition and full joint acceptance remain open.
