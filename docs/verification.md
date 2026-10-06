# Текущее состояние проверки Notebook

**6 октября 2026.** Установлены iPad/runtime **252 / 0.3.182** и plugin **0.2.4**,
срез `2db74771151f`. Последующие проверки используют изолированную native-test
идентичность; название каталога `253` не означает установку новой пары.
Каждое свидетельство относится к указанным в нём исходникам и сценарию.

## Установленная пара

Самостоятельные Mac-окна, ввод и установщик удалены из исходников; старые bundles
и MCP helpers удалены после штатного завершения. Подписанный runtime работает
из кеша плагина и остаётся владельцем данных после закрытия MCP-клиента.
SIGTERM завершил сохранение за **114,511 мс**; обычный MCP-запуск восстановил владельца.

Сохранены прежнее пространство, каталог iPad, активная SQLite, идентичности и
доверие пары; после запуска iPad подтверждён authenticated `awdl0`.
Исторические архивы и ключи не переносились. Установка 252 фактически выполнена,
но её квитанция осталась `incomplete`: прежний установщик сравнивал абсолютный
путь перемещённого системой контейнера. Успешная установка и данные проверены
отдельно; повторной установки не было. Новый установщик сравнивает логическое
пространство и app-group IDs: **23 адресные проверки PASS**, независимое ревью принято.
[Подписи, readback, исходная квитанция и точный scope](audit-evidence/2026-10-06/plugin-cutover-252/results.json).

Установленный MCP читает ресурс рабочей панели. Полный сценарий в настоящей
панели Codex ещё ожидается; проверочная карточка подтверждает возможности хоста.

## Проверенные исправления

В `01c8a645` **5 native-сценариев физического iPad PASS**, без пропусков и runtime
warnings. Подготовленный кадр переживает удержание контакта и новый Pencil;
неподтверждённые tiles повторно показываются при mount. Обложка сохраняет плотность
при глубоком зуме, переносе и стирании. UIKit-меню ждёт фактического dismiss,
уход родителя снимает дочерний sheet; поздний clipboard callback не заменяет новое меню.
[Пять сценариев и хэши проверенных владельцев](audit-evidence/2026-10-06/mounted-lifecycle-repair/results.json).

Исправлен «Назад»: оконный observer меняет intent при новом касании сцены,
сохраняя учёт контактов popover/sheet до отпускания. Пять сценариев прошли,
включая исходный системный journey: выбор → перемещение → удаление → Undo/Redo →
перелистывание → Back → холодное открытие. Три системных снимка просмотрены.
Первый wrapper отклонил набор из-за одного UIKit warning в новом тестовом fixture;
после перехода fixture на UIViewRepresentable адресный повтор **1 PASS / 0 warnings**.
Производственные байты между прогонами одинаковы, исходный отказ сохранён.
Независимое ревью принято. Opt-in диагностика Pencil связывает конкретный UI update,
CA flush и OS receipt; её контракт прошёл, аппаратный замер ещё ожидается.
[Точные исходники, исходный warning, повтор и снимки](audit-evidence/2026-10-06/presented-contact-boundary/results.json).

Быстрые цепочки лассо ещё исправляются. Подготовка резервировала 192 МиБ из
общего бюджета 256 МиБ и блокировала следующий жест. Независимое ревью нового
решения обнаружило полный обход содержания на MainActor и зависимость маленького
выделения от размера всей доски. Оба P1 устраняются адресным захватом источников
до интеграции; прежние локальные PASS не закрывают эти причины.

## Remediation 104

Приняты **NB27, NB31, NB05 — 3 из 104**. Статус и зависимости —
[Linear, GUI-306](https://linear.app/main-cluster/issue/GUI-306).

Срез observation/accepted-write/workspace: **127 Core/Codex/ScriptHost функций,
167 исполнений; 54 native Mac; 27 panel Node — PASS**, без пропусков; native runtime
warnings отсутствуют. Core-свидетельство связано с итоговым срезом точным совпадением
всех 797 входов SwiftPM; native source `9ec8381009e7` неизменен во время проверки.
Проверены COUNT/sort до первой строки, сохранение accepted COMMIT при отмене чтения,
общий decode/output budget, fixed writer prefix, два drop с Undo, source-retaining
workspace Retry и поздний page worker после отзыва derived admission. Production
panel DOM/Session/Surface/pinned WASM проверены жестами в отдельном Chrome host;
installed Codex и физический iPad этого среза ещё ожидают проверки.
[Точные scopes, hashes и результаты](audit-evidence/2026-10-06/observations-and-workspace-cuts/results.json).
Scoped owner frontiers, полный admission остальных producer путей и новая модель
Undo остаются в Linear; весь реестр 104 позиций этим срезом не закрыт.

Search / DocumentFile references, source `3a449fef242e`: **21 Core-функция /
27 исполнений PASS**, без пропусков. Literal angles, bounded HTML, graphic labels,
index-only DB28→29 rebuild, старые handles и immutable historical pinned sources.
DB29 остаётся изолированным до согласованного cutover; wire44/manifest26 сохранены.
[Точный scope и результаты](audit-evidence/2026-10-06/search-source-semantics/results.json).

NB10 baseline `b46361ab`: writer для 1 KiB / 1 MiB / 4 MiB —
**20,96 / 184,13 / 640,95 мс**, `updateSearchIndex` — **5,57 / 128,20 / 542,99 мс**.
Planner ещё не изменён; текущие allowances требуют замера при его изменении.
[Атрибуция](audit-evidence/2026-10-06/search-source-semantics/attribution-README.md).

Политика NB11: вся авторская история бессрочно; очистка доказанно бесхозных данных
и производных кешей. Состав устройств: этот Mac и iPad Елизаветы. Immutable Undo
transition, остальные native producer admission и полная приёмка остаются открыты.

## Условия завершения

| Срез | Подтверждено | Осталось |
| --- | --- | --- |
| [C1 / GUI-475](https://linear.app/main-cluster/issue/GUI-475) | Общие Swift координаты, camera trajectory, move/resize, pressure и incremental ink; native/WASM parity. Настоящий Codex: WASM, WebGPU, Retina readback, изолированный HTML и Unicode input. | Полный рабочий сценарий iPad/панель/агент, IME/focus, взаимодействие с программой, offline cold start и контракт ввода 20 мс. |
| [C2 / GUI-388](https://linear.app/main-cluster/issue/GUI-388) | Общая поверхность начата. | Массовый перенос ждёт C1; прежние растровая сборка и опрос 1,5 с удаляются вместе с адресными scene updates. |
| [C3 / GUI-389](https://linear.app/main-cluster/issue/GUI-389) | Нативные документы/программы имеют адресные проверки. | Жизненный цикл, редактирование и сохранение на обеих общих поверхностях. |
| [C4 / GUI-476](https://linear.app/main-cluster/issue/GUI-476) | Runtime установлен внутри плагина; самостоятельное Mac-приложение удалено, пространство и доверие сохранены. | Реальная панель, чат, файлы, терминал, голос и восстановление неопределённых команд. |
| [C5 / GUI-477](https://linear.app/main-cluster/issue/GUI-477) | Действующий причинный формат и прямой канал сохранены. | Автовыбор маршрута, долговременная серверная доставка, перенос актуальных очередей CloudKit и общий выпуск. |

**GUI-190 — полная приёмка открыта.** Нужны десять повторений сценариев, 30 минут
совместной работы и системные frame/CPU/GPU/memory измерения одной пары. CADisplayLink
не измеряет FPS; сборка, установка и адресные PASS не заменяют эту приёмку.
Обновление сохраняет контент, контейнеры, идентичности и ключи; несовместимый helper
не открывает workspace. `saved`, `receivedByIPad` и `shownOnIPad` проверяются отдельно.
GUI-196, GUI-197, GUI-183 и длительная GUI-250 остаются открыты; GUI-240 закрыта решением Амира.

## Открытые измерения

- **Pencil/eraser, ≤ 20 мс по контракту.** Реальный trace 247: 5830 batches, без
  потерянных событий/сэмплов и ошибок записи; handler p95 ≤ 0,25 мс, actual→OS
  pen/eraser p95 **57,82/57,42 мс**, 139 unresolved lift batches. GPU занимает
  около 1 мс; нужна связь выбранной UI-фазы, CA commit и OS receipt этого кадра.
  Новая диагностика прошла ревью, scheduling сохранён. Накладные расходы trace
  не откалиброваны. [Реальный Pencil и доставка 247](audit-evidence/2026-10-05/surface-consolidation/delivery-247.json).
- **Undo обложки, 100 мс.** Первый 252 native-прогон: **114,956 мс** и неверное первое
  изображение. После ремонта изображения два диагностических прохода дали
  **90,566 / 95,681 мс** до CA commit, inverse SQL **31,7–31,9 мс**. Функционального
  ускорения ещё нет; устойчивый предел и аппаратный показ открыты.
  [Разделение Undo и UIKit lifetime](audit-evidence/2026-10-06/menu-and-ink-diagnostic/results.json).
- **Панель, зум/DPR.** В 240 материал после 50→95% появлялся за 228 мс, после 100→350% —
  за 1672 мс. DOM/rAF и native manifest clocks не измеряют OS display time;
  реальная панель, переход между экранами и idle work требуют повторной проверки.
  [Исходный active consumer](audit-evidence/2026-10-01/codex-zoom-latency/results.json).
- **Cold documents/SVG/programs, Native24, first curl.** Строгие бюджеты,
  cold-process p95/p99, первый discard и ready-time WebKit IPC открыты.
  [Source clocks 240](audit-evidence/2026-10-01/cold-owner-240/cold-metrics.json),
  [одиночные замеры 246](audit-evidence/2026-10-05/print-binding/results.json).
- **Промежуточный mixed cut.** Итоговый снимок не доказывает все OS-кадры.
  В inverse-journey2009 GPU cut и receipt 23,023 мс содержали штрих, которого не
  показал drawHierarchy(false); independent display oracle остаётся открытым.
- **Системные frame/CPU/GPU/memory.** Текущая пара ещё не принята; прежние
  Time Profiler 2042 и logging-only 60s не дали пригодных измерений.

## Свидетельства предыдущих срезов

Таблица сохраняет исходный scope. Результаты разных версий не суммируются в приёмку текущей пары.

| Срез | Результат и свидетельство |
| --- | --- |
| Runtime 252 | 4 native Mac + 89 release + 111 verifier PASS; 8 подписанных lifecycle/integrity сценариев PASS. [Receipt](audit-evidence/2026-10-06/plugin-runtime-lifecycle/results.json). |
| Первый iPad 252 | 4 PASS / 5 FAIL: раннее лассо, Undo/первый кадр и cancellation. 100 000 объектов, текст, cold launch и чужая замена PASS. [Исходные отказы](audit-evidence/2026-10-06/plugin-cutover-252/results.json). |
| Ремонт 252 | [Первичная диагностика](audit-evidence/2026-10-06/scene-lifecycle-diagnostic/results.json), [Undo/menu](audit-evidence/2026-10-06/menu-and-ink-diagnostic/results.json), [mounted lifecycle](audit-evidence/2026-10-06/mounted-lifecycle-repair/results.json). Ошибки GPU fixtures lifetime/unit transform исправлены. |
| GUI-481 | 8 native + 4 системных жеста PASS, снимки просмотрены, зазор меню 14 pt. [Исходный срез](audit-evidence/2026-10-05/object-actions-481/results.json); [повтор на владельцах 252](audit-evidence/2026-10-06/object-actions-481/results.json) — 1 PASS. |
| Runtime 251/250 | [Обычные файлы TypeScript](audit-evidence/2026-10-06/plugin-typescript-layout/results.json), [manifest](audit-evidence/2026-10-06/plugin-package-format/results.json), [Codex recovery](audit-evidence/2026-10-06/plugin-runtime-codex-recovery/results.json), [сохранение](audit-evidence/2026-10-06/plugin-runtime-250/results.json). Первоначальные отказы сохранены. |
| Core remediation | 19 Core-функций / 20 исполнений, 110 verifier, 82 release PASS. 100k lookup p50/p95 0,041/0,105 мс; cold build/query 1337 мс. [Scope](audit-evidence/2026-10-06/remediation-foundation/results.json). |
| Принятые записи/Clipboard | 29 Core-функций / 30 исполнений + 36 native Mac PASS; точный Retry, cold-root aliases, bounded bodies, atomic scene, lossless clipboard. NB05 принята. [Scope](audit-evidence/2026-10-06/accepted-writes-and-clipboard/results.json). |
| Runtime 249/обложки | 8 native Mac + 28 MCP PASS; пара 249 была собрана, переход установлен в 252. [Scope](audit-evidence/2026-10-06/plugin-runtime-249/results.json). |
| Объекты 248 | 10 native + 4 жеста iPad и Mac clipboard/Undo PASS; 100k адресный lookup проверен отдельно. [Scope](audit-evidence/2026-10-05/object-interaction/results.json). |
| Общая поверхность | [Native/WASM, 17 Core и 100k](audit-evidence/2026-10-05/surface-consolidation/results.json), [браузерный GPU](audit-evidence/2026-10-05/surface-consolidation/browser-gpu.json), [настоящий Codex](audit-evidence/2026-10-05/surface-consolidation/codex-host.json), [build stage](audit-evidence/2026-10-05/surface-consolidation/build-stage.json). |
| Часы/trace 247 | Оба неудачных варианта UIUpdateLink удалены: [отклонённый кандидат](audit-evidence/2026-10-05/surface-consolidation/ipad-clock-candidate.json), [восстановленный путь](audit-evidence/2026-10-05/surface-consolidation/ipad-restored.json). Monitor: [7 iPad + 1 Mac PASS](audit-evidence/2026-10-05/surface-consolidation/pencil-monitor.json). |
| Печать 246/244/243 | Scope алгоритмов и одиночных UI-замеров: [binding 246](audit-evidence/2026-10-05/print-binding/results.json), [admission 244](audit-evidence/2026-10-05/print-admission/results.json), [cache 243](audit-evidence/2026-10-05/print-performance/results.json). Общий cold-open прирост не установлен. |
| Документы 242/241 | [Checkpoint lifetime 242](audit-evidence/2026-10-05/document-lifecycle/results.json), [baseline 241](audit-evidence/2026-10-05/document-lifecycle/baseline.json), [document owners 241](audit-evidence/2026-10-05/architecture-documents/results.json), [адресные материалы](audit-evidence/2026-10-05/architecture-materials/comparison.json), [installed IPC](audit-evidence/2026-10-05/architecture-materials/installed.json). |

Доставки прежних пар: [246](audit-evidence/2026-10-05/print-binding/delivery.json),
[244](audit-evidence/2026-10-05/print-admission/delivery.json),
[243](audit-evidence/2026-10-05/print-performance/delivery.json),
[242](audit-evidence/2026-10-05/document-lifecycle/delivery.json),
[241](audit-evidence/2026-10-05/architecture-documents/delivery.json).
Подробный журнал 241–252 остаётся [в Git](https://github.com/AmirTlinov/Notebook/blob/01c8a645/docs/verification.md),
215–240 — [в прежней ревизии](https://github.com/AmirTlinov/Notebook/blob/1ee54dc9e4444fee3aa9fec4a4a435636d11aa03/docs/verification.md).
Текущие задачи и зависимости ведутся в Linear; контракт ввода —
[interaction ownership](interaction-ownership.md).
