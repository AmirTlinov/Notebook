# Текущее состояние проверки Notebook

**7 октября 2026.** Установлены iPad/runtime **253 / 0.3.183** и plugin **0.2.5**,
срез `1a1f3f25190c`. Изолированные native-проверки используют отдельную test-идентичность.
Каждое свидетельство относится к указанным в нём исходникам и сценарию.

Восемь native Mac проверок recovery-пары прошли без предупреждений,
исходники до/после совпадают. Установка завершилась `installed/complete`;
подписанный кеш и работающий владелец проверены. [Сборка](audit-evidence/2026-10-06/plugin-recovery-253/results.json),
[установка и readback](audit-evidence/2026-10-06/plugin-recovery-253/installation.json).

Переносимый подпункт NB13: повторный вход из `toJSON`/getter больше не позволяет
отменённому checkpoint установить frozen. На исходном JS три регрессии FAIL;
с исправлением **34 Node tests PASS**, строгий MCP TypeScript и diff-check PASS.
Основной admission-before-copy и native WebKit/physical проверка остаются открыты;
native owner/credit/writer не менялись. Независимое ревью принято: 34/34, tsc и
diff повторены; отдельные 64 варианта повторного входа и credit/ACK probes PASS.
[Контрпримеры и точный scope](audit-evidence/2026-10-06/checkpoint-generation-nb13/results.json).

## Установленная пара

Самостоятельные Mac-окна, ввод и установщик удалены из исходников; старые bundles
и MCP helpers удалены после штатного завершения. Подписанный runtime работает
из кеша плагина и остаётся владельцем данных после закрытия MCP-клиента.
В первой проверке 252 SIGTERM завершил сохранение за **114,511 мс**;
обычный MCP-запуск восстановил владельца.

Сохранены прежнее пространство, каталог iPad, активная SQLite, идентичности и
доверие пары; после запуска iPad подтверждён authenticated `awdl0`.
Исторические архивы и ключи не переносились. Установка 252 фактически выполнена,
но её квитанция осталась `incomplete`: прежний установщик сравнивал абсолютный
путь перемещённого системой контейнера. Успешная установка и данные проверены
отдельно; повторной установки не было. Новый установщик сравнивает логическое
пространство и app-group IDs: **23 адресные проверки PASS**, независимое ревью принято.
[Подписи, readback, исходная квитанция и точный scope](audit-evidence/2026-10-06/plugin-cutover-252/results.json).

В runtime252 `CurrentViewPreviewWriter.PreviewError.sourceChanged` попал в accepted
FIFO как ошибка хранения и удерживал устаревший closure. После прямого разрешения
Амира PID74380 завершён принудительно: SIGTERM не освободил очередь; сохранность её
несохранённого RAM-tail не подтверждена. Предложение вмешательства отладчиком остановлено
автоматической проверкой до обращения к живому процессу.

В установленной 253 свежий MCP-клиент успешно прочитал ресурс панели, `notebook_open`,
заголовок пространства, observation без изображения и статус адаптера Codex. Совпали
восемь прежних полей содержания; каталог/SQLite metadata iPad сохранились при установке.
Динамическая подпись PID41679 совпадает со сборкой. После запуска iPad подтверждён
authenticated `awdl0`; повторные подключения и POSIX60 ещё требуют проверки устойчивости.
7 октября текущий MCP подключён к 253, реальная DOM-панель Codex доступна.
Пользователь сообщил задержки и размытие; рабочая UX-приёмка остаётся открытой. Первичный image smoke до запуска iPad получил
`current_scene_unknown`; его результат сохранён как отказ. После запуска физического
iPad тот же installed smoke прошёл: изображение `ready`, адаптер `connected`.

## Проверенные исправления

Панель Codex теперь уведомляет кнопки о завершении навигации сразу; прежняя
задержка до следующего опроса 1,5 с удалена. Выбор следующего инструмента сохраняется
во время записи, горячие клавиши работают после фокуса toolbar, Enter/Space сохраняют
нативное нажатие кнопки. Инструменты получили единые SVG-значки и адаптивную компоновку.
**48 адресных Node-проверок и TypeScript PASS**, независимое ревью принято.
Точная HTML/CSS-компоновка просмотрена в IAB при 320/540/900 px. Это предварительная
визуальная проверка; обновлённая панель ещё требует установки и проверки в Codex.

7 октября подготовлена управляемая остановка установленного runtime: полный
device/signature/storage preflight, audit-token SIGTERM и захват прежнего writer
lease без ручной паузы. Lease удерживается до проверки установленного кеша;
неизвестный owner, PID reuse, отказ сохранения и повторные запуски дают адресный
исход. **38 изолированных Python проверок PASS**, независимое статическое ревью
принято. Kernel identity прочитана у собственного Python listener; SIGTERM
проверен через fake libproc. Новая пара ещё требует exact-source verification,
сборки и установки; существующая 254 не изменялась.
[Scope, хэши и результаты](audit-evidence/2026-10-07/runtime-handoff/results.json).

Подготовлен единый владелец публикации: каталог Codex переключается только на целый
проверенный пакет; новая authored-версия сама по себе его не меняет. **7 Node + 27 Python
PASS**, строгая проверка TypeScript PASS. Изолированный официальный CLI подтвердил
перенос marketplace без переустановки плагина и потери кеша; проверены неопределённый
исход удаления, повтор миграции и освобождение OS-блокировки. Независимое ревью принято.
Живой источник переключён на immutable-пакеты: версия 0.2.5, runtime 253, кеш и PID41679
сохранены. Свежий установленный MCP прошёл open/header/observe/runtime; подключение текущего
чата к 253 восстановлено 7 октября. Следующая пара
ещё не установлена. [Проверки](audit-evidence/2026-10-06/plugin-publication/results.json),
[живая миграция](audit-evidence/2026-10-06/plugin-publication/migration.json).

Устаревший источник и отзыв подготовки теперь дают адресный отказ публикации,
освобождая её место в FIFO. После начала I/O сохраняются точные PNG/receipt и
региональный fingerprint; Retry завершает ту же публикацию без новой валидации
источника. **8 native Mac PASS / 0 warnings**: отказ и последующая запись,
реальная ошибка второго файла с повтором, cancellation камеры/ввода/shutdown и
возобновление metadata refresh. Core и очередь записи сохранены, независимое ревью
принято. [Исходники и результаты](audit-evidence/2026-10-06/preview-publication-retry/results.json).

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

В срезе `ac9d2da3` **12 оптимизированных native-сценариев iPad PASS / 0 warnings**:
ранние Move/Delete и следующий Pencil принимаются до завершения первой подготовки,
сохраняют причинные адреса и порядок Undo. Резерв учитывает адресный материал;
лимиты 192/256 МиБ сохранены. На 100 000 контактах один холодный callback лассо
занял 0,196 мс, Move/Delete — 0,125 мс; это измерения контроллера, аппаратный показ
остаётся открытым. 24 проверки Core покрывают компактность, чужую замену, маски и
нагрузки в 100 000 объектов; ещё 20 проверяют точность JSON/координат. Отдельное
сравнение Debug-сборок подтвердило устранение jetsam: освобождение временных объектов
после декодирования каждого значения снизило память при подготовке 200 017 записей
с 3,68 ГБ до 483 МБ. Массовое восстановление причинного состояния и полное чтение
страницы требуют отдельного ускорения. Исправление ещё не доставлено
в установленную 253. [Исходные отказы, сравнение и окончательные результаты](audit-evidence/2026-10-06/lasso-admission/results.json).

## Облачный кандидат границы ввода панели

На базе `ccd2d510` исправлены конкурирующие действия в удержанном жесте панели:
Undo/Delete и открытие редактора не отзывают его владельца; потеря pointer capture
отменяет только незавершённый контакт. Нормальный release, повторное использование
pointer ID, исходные measured samples и уже принятая запись сохранены.
Независимое ревью обнаружило и закрыло две дополнительные причины: очистку preview
при отклонённом Delete и вложенное открытие редактора через Enter.

**44 адресные CPU-проверки и TypeScript/script-services PASS**, без пропущенных
тестов выбранного набора. DOM/геометрия/GPU — ограниченные fixtures; реальный
InkInput проверяется отдельно внутри этого же набора. В полном четырёхфайловом
наборе ещё **8 отказов окружения**: Unix sockets запрещены (`EPERM`). Это не PASS
всего MCP. Настоящая панель Codex, IME/offline, физический iPad и полная приёмка
не проверены этим кандидатом; установленная пара 252 не обновлялась.
[Точные исходники, команды, RED→GREEN и границы](audit-evidence/2026-10-06/panel-contact-ownership/results.json).

## Переносимый срез DP19: публикация чата

Отдельный срез подготовлен поверх `7274f6c1`: transcript delta принимается без
ожидания MathJax. Один producer готовит активную batch в скрытом подключённом
контейнере той же ширины. До typesetting фиксируются точные source nodes/UTF-16
ranges; готовый результат синхронно заменяет только найденные TeX spans.
Prose, links и disclosure nodes сохраняют идентичность, selection и focus;
последующее streaming использует исходные координаты известных math spans.
Старые source bodies и пересекающиеся ranges не принимаются. MathJax records
освобождаются до переноса output; failed jobs оставляют plain text и не удерживают
очередь. Прежняя блокирующая очередь и whole-body math replacement удалены.
**20 Node regressions и полный строгий MCP TypeScript PASS** на Linux.
Проверки используют настоящий DOM Range/Selection; три также проверяют bundled
MathJax4.1.3, включая assistive MathML, rejected-job cleanup и сохранение SVG.
Baseline renderer даёт ожидаемый FAIL на финальном regression.
Два прохода независимого ревью выявили lifecycle/selection/focus замечания;
они исправлены. Третье ревью принято в границах кода и переносимых проверок:
20/20 повторены независимо; отдельные math/selection probes также прошли. Native visual fixture явно ждёт math
readiness. WebKit/font metrics, физические жесты, сборка и установка не выполнялись;
GUI-498/DP19 ещё не имеет физической приёмки.
[Точные исходники, результаты и ограничения](audit-evidence/2026-10-06/chat-math-publication-dp19/results.json).

Переносимый срез NB30 связывает весь Codex/Node payload с manifest из закреплённых
официальных архивов. Подмены bytes/type/mode, symlink, частичный cache, поддельный
marker/receipt и неверная фактическая версия отклоняются. Content-addressed stage
атомарно публикуется одним preparer и проходит через существующие build/verification
receipts; старый flat cache и действующий254 не менялись. **95 release/admission +
95 selection/receipt Python PASS** в Linux, включая реальные конкурентные fixture
процессы. Подписи Apple и версии проверялись только тестовыми fixtures: настоящие
codesign, Xcode sandbox, signed pair и установка **не исполнены**. Полный aggregate
здесь не пройден: Swift отсутствует, Unix sockets запрещены средой.
На официальном payload 439 213 968 байт измерены только Linux I/O: cold из локальных
архивов 5,838 с; reuse 0,569–0,657 с с полным SHA-проходом, без копирования/распаковки.
Это не сравнение с прежним кешем и не Mac performance gate. Первое независимое
ревью выявило гонки подмены каталогов/уже проверенных файлов, hardlink alias и
зависимость нового Xcode-пути от Python3.11 API. Исправлены anchored-дескрипторами,
проверкой всех fingerprints до/после операции, nlink=1 и потоковым SHA; добавлены
7 регрессий. Повторное независимое ревью принято в переносимой области: обе серии
95/95 проверены независимо; дополнительные race/extra-entry/Python API probes PASS. [Границы и результаты](audit-evidence/2026-10-06/codex-runtime-pins-nb30/results.json).

## Объединённая переносимая проверка

Поверх `96e00928` совместно проверены панель и PR #1–#4. Найденная при
интеграционном ревью ошибка NB30 исправлена: диагностический stderr больше не
подменяет stdout версии. Обе трубы ограничены общим лимитом и timeout; exact
version и ненулевой exit остаются отказом. Три новые регрессии включают настоящий
hash-matching fixture с предупреждением при prepare/reuse/bundle. Исправлена
устаревшая команда подготовки runtime. Независимый повтор: 29 packaging tests
и дополнительные stream/boundary probes PASS.

Общий результат: **54 chat/program + 44 panel CPU + 104 release/resource +
117 verifier PASS**, строгий TypeScript и script-services PASS. В более широком
пятифайловом Node-прогоне 94 PASS и 4 отказа AF_UNIX (`EPERM`); он не объявляется
полным PASS. Native Xcode/WebKit, signing, физический iPad и установка не
выполнялись. Незакоммиченный Swift-кандидат в этот срез не включён.
[Точные исходники, исходный отказ и повторные проверки](audit-evidence/2026-10-06/main-consolidation/results.json).

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
| Portable integration | PR #1–#3 совместно: 54 Node + 101 release/resource + 117 verifier PASS, strict MCP TypeScript PASS. Исправлена только host discovery в fabricated-runner tests; отдельный base suite 113 PASS. Production Swift prerequisite сохранён. Local integration tree не опубликован; native/physical/install gates открыты. [Точные исходники и результаты](audit-evidence/2026-10-06/verification-fixture-discovery/results.json). |
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
