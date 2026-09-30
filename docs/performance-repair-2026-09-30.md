# Ремонт причинных задержек — 30 сентября 2026

Реализация [ревью D01–D16](performance-review-2026-09-30.md) от `c140b804`.
**0.3.155 (225)** установлена на Mac и физическом iPad; точный source, установка
и области проверки сохранены в [verification](verification.md). Строгие задержки
первого показа и полная приёмка остаются открытыми.

Основное изменение — локальная работа принадлежит владельцу принятого содержимого,
а запись, установка изображения, интерактивность и завершение перехода имеют разные
условия. Writer сохраняет причинный порядок без ожидания окна; представление
удерживает согласованный материал до установки следующей версии.

## Реализованные изменения

| ID | Владелец и результат | Удалённый путь |
|---|---|---|
| **D01** | `InkCanvasView`: paint identity отделена от derived buffers. Принятая подложка страницы и spatial-тайлов обновляется по области старого/нового содержимого; неизменённые resident lists сохраняются. Borrowed подложка копируется перед изменением. | Полная перерисовка принятой композиции из-за обычной generation/замены эквивалентного mesh; повторный поиск, сортировка и подпись contributors каждого тайла в каждом кадре. |
| **D02** | `NotebookSelectionPresentation` готовит patch выбранных IDs; canvas объединяет его с принятой композицией. Local meshes сохраняют identity при переносе; чернила, authored hosts и рамка устанавливаются общей транзакцией. | Сборка и подготовка полного ink plan на каждой новой позе выделения. |
| **D03** | Frozen delete с read set принимается FIFO независимо от drawable. `NotebookSelectionPresentation.acceptedAwaitingPresentation` завершает передачу на canonical cursor не ниже принятого. После acceptance preview не может откатить удаление. | `awaitFirstInstallation()` в подготовке durable-команды, install waiter/timeout и несовместимая ошибка `deleting && !installed`. |
| **D04** | `NotebookSurfaceHistoryOwner` хранит ограниченную историю и сразу резервирует точный inverse и место в FIFO. Последующие Undo/Redo используют projected heads и зависят от своей предыдущей команды/подготовки исходника. | Общие flush/scene refresh в завершении каждого authored Undo/Redo; разрозненное управление history tasks в AppModel. |
| **D05** | `NotebookPageSource` удостоверяет body, полный digest и store identity одного WAL cut. `NotebookPageWindow` сравнивает digest до decode; AppModel удерживает capability вместе со страницей. `NotebookDiskRefresh` использует отдельный bounded background reader. | Безусловное повторное чтение body с последующим сравнением; ожидание foreground page read за уже исполняющимся фоновым проходом. |
| **D06** | `DocumentWebView` устанавливает готовую бумагу до shell/JavaScript. `DocumentPagePresentationOwner` различает paper, interaction и composite capture readiness; native host сохраняет точный raster при отказе Web shell. | Установка бумаги только после `evaluateFrame`; использование общей canonical readiness для готовности бумаги. |
| **D07** | Worker готовит typed `DocumentPreparedLayout`; source владеет reading index, regions, anchors и page slots. `DocumentPrintLineIndex` строит UTF-16 индекс один раз на файл и ищет строки бинарно. | Per-page split/сканирование исходных файлов, внутренний dictionary roundtrip layout и повторные каталоги. Парсер внешних browser receipts сохранён. |
| **D08** | Immutable document source владеет одной package/descriptor task на путь и публикует разрешившиеся пути по отдельности. `DocumentProgramOwner` удерживает ещё не разрешённые старые instances; renderer и export используют принятый package. | Whole-batch descriptor barrier и повторные package/source reads в runtime и двух export consumers. Глобального package cache нет. |
| **D09** | `DocumentBlockRuntime` готовит package/state до короткого constructor allowance у `SceneRenderResources`. Promotion меняет priority той же pending request; после grant применяется актуальная роль. Allowance освобождается после native construction. | Cancel/reacquire при смене роли и обход общей constructor admission документными программами. |
| **D10** | `PageAgentPreparationOwner` учитывает точный native viewport: видимые sources, принятая цель поворота, прочее current content, speculation. Новые idle-neighbor hosts монтируются после первого показанного cut; явная цель жеста допускается сразу. | Равный приоритет всего содержимого current page и безусловная конкуренция новых соседних hosts с первым кадром. |
| **D11** | `PageTurnMaterialOwner` удерживает native/slot material по source, локальной геометрии, cuts, scale и provider version. Правка обновляет затронутый материал; reorder/translation меняют малый каталог. | Перерастеризация всех слоёв страницы при локальной правке и ожидание всего static cohort перед подготовкой отдельных готовых slots. |
| **D12** | `PreparedAgentElementPreparationOwner` владеет versioned pending/error cut: native view и curl показывают один материал. Pending сохраняет один ключ при queued → granted; ошибка/retry/source replacement меняют или отзывают его. | Запрет поворота из-за never-ready программы; повторная растеризация статуса при constructor grant; отдельная SwiftUI/ImageRenderer-картинка с последующим копированием. |
| **D13** | `IPadPageTurnController.Operation` удерживает document source/layout lease и пару hosts до terminal outcome. После него `DocumentPagePresentationOwner` сопоставляет actual landing с successor через reading anchor той же render session. | `contentStamp → cancelMotion` и преждевременный отзыв hosts/readiness при изменении документа во время принятого поворота. |
| **D14** | `NotebookInputGate` и native contact различают физически опущенное перо и ещё завершающуюся публикацию. После lift история завершает оценки через существующий finisher; реальный контакт по-прежнему защищён. | Молчаливый отказ Undo после физического lift только из-за pending estimates; смешение contact и publication lifetime. |
| **D15** | `InkElementErasureMap` хранит persistent target/cut trees. Локальная правка копирует только затронутые пути; прежние sources удерживают прежние roots, consumers раскрывают cuts выбранной цели. | Копирование общего Dictionary-of-arrays и сортировка всей erasure metadata при локальном принятии. |
| **D16** | `NotebookInkReadSet` после indexed AABB broadphase проверяет фактический исходный paint support общей геометрией. Source capture и SQL writer используют одно правило; неизменённые witnesses сохраняют доказательство. | Конфликт из-за одного пересечения прямоугольников и отдельная приближённая геометрия проверки. |

## Законченные срезы и их границы

1. **Принятие, история, чтение — D03–D05, D14.** Immutable command/read set
   входит в writer раньше показа; presentation независимо завершает visible cut.
   История резервирует последовательность accepted действий, а новый физический
   контакт остаётся границей допуска. Failure завершает наблюдателей, сохраняя
   durable tail для retry. Source-editor preparation не ставит зависимый inverse
   перед собственной записью. Независимый background read не занимает foreground
   reader; source witness, membership/deletion и история продолжают проверяться.

2. **Локальная геометрия — D01, D02, D15, D16.** Цена изменения зависит от
   затронутых объектов/области. Selection patch привязан к принятому source;
   full replacement, иной crop или scale качества всё ещё требуют новой подготовки.
   D16 проверяет исходный paint support до последующих cuts: новое стирание внутри
   уже стёртого места остаётся зависимостью, поскольку Undo может его раскрыть.

3. **Документ от исходника до native host — D06–D09.** Render session сохраняет
   immutable source; он владеет typed layout и path producers. Бумага может быть
   установлена при ещё недоступном Web interaction, но composite capture не получает
   ложную готовность. Разрешившийся package не ждёт соседних packages; независимые
   instances сохраняют собственное состояние и фокус.

4. **Материал страницы и переход — D10–D13.** Страница удерживает свои материалы,
   операция — принятую пару и source lease. Pending/error является настоящим
   установленным содержимым, поэтому показанная бумага не зависит от JS readiness.
   Successor документа применяется после исхода жеста с exact operation/source
   guards; ошибка сопоставления имеет определённый retry, а старый cut сохраняется.

Дополнение после первого прогона 225: status raster теперь строится CoreGraphics/
CoreText worker вне MainActor, с reservation **до** выделения буфера. Старый raster
удерживается immutable borrow до окончания worker; отмена освобождает allocation
после его завершения. Один pending материал переживает grant/input change. Вместе
с этим отложен лишний idle-neighbor mount. При следующей проверке обнаружен запрос
приватного имени системного шрифта; он заменён на `CTFontCreateUIFontForLanguage`
и bold trait для «Повторить». Pending/error и queued-input сценарии после правки
прошли на физическом iPad.

Проверка переходов выявила ещё три причины. Повторный writer retry терял observer
сохранения: history owner теперь меняет boundary только при смене blocked-состояния.
Новый пустой лист повторно выделял полный raster и texture: он заимствует бумагу
того же размера/масштаба у владельца материала. Metal heap estimate недооценивал
фактическую private allocation: расчёт использует существующее округление до
VM-страницы, сохраняя actual-size guards и прежние лимиты.

При принятии одинакового durable page body новые runtime roots не вызывали
Observation-событие. Установленный лист оставался на старом источнике, а readiness
проверяла новый. `NotebookPagePreparationWindow.Entry` публикует точную версию
чернил/graphics и принятый документ; существующий reader получает их вместе.

Повторное снятие 24 программ вызывал общий `materialRevision` поверх проверки
конкретного владельца материала: полный source/provider/ink basis уже совпал,
но временная смена native provider оставила увеличенный счётчик. Удалены оба
post-await veto и нечитавшаяся revision в операции. Актуальность проверяет
владелец снимка; операция сохраняет проверки жизни, readiness и принадлежности.
Availability-only событие будит подготовку без изменения версии содержимого.

Curl публиковал уже scheduled successor только после OS receipt предыдущего
кадра: 17,938→31,384 мс, с разрывом показа16,673 мс. Удалены запрет публикации,
парковка clock и зависимый допуск drawable. Три учтённых drawable ограничивают
работу; первый reveal сохраняет transaction до реального показа, смену режима
завершает CA owner. Landing по-прежнему требует точного endpoint OS receipt.

Один CPU-профиль физического cold24 выявил синхронный `CIContext.init` на пути
монтажа бумаги: 36 samples MainActor в `SheetCurlGPU.init`, включая загрузку
Metal-архивов и SHA-256. Контекст используют компоновщик снимка и обложка;
движение interior page имеет отдельный Metal pipeline. [PID, часы, UUID и stack](audit-evidence/2026-09-30/performance-repair-225/cold-cpu-diagnosis.json)
сверены. Профильные времена включают наблюдение и не являются latency acceptance.

Подготовка Core Image и реальный bitmap→BGRA warm принадлежат одному producer
`SheetCurlGPU` вне MainActor. Компоновщик заимствует созданный контекст через
отменяемое ожидание; cover-ready публикуется после GPU completion warm-up.
Внутренний лист не ждёт cover-ready. Cover owner сохраняет endpoint до готовности,
подписчик сверяет свой lifetime и освобождается при отмене/отсоединении.
Ещё 10 samples относятся к `preparedPaper → ImageRenderer`: бумага теперь рисуется
на уже учтённом буфере `CompositionPixels`, с общей vector grid geometry для
native view и worker. Второй bitmap и SwiftUI raster pass удалены.

Plain document landing снимал fallback после native PDF, затем отзывал resident
frame до более позднего DOM receipt. `staticTurnMaterial` теперь проверяет точную
готовую бумагу; interactivity/capture admission остаётся отдельным условием.
Passive picture также получает интегральный pixel extent по обеим осям: прежний
fractional UIKit extent мог округлить одну ось вниз и запретить повторный borrow.

Завершена оставшаяся граница D06: generation-owned native job готовит и
устанавливает PDF независимо от незавершённого JS predecessor. Serial shell sender
заимствует результат этого же source producer. Общий waiter owner различает native
paper и canonical interaction; current/raster preparation ждёт native cut, live
handoff — interaction. Curl принимает точный source/page, native geometry и полный
установленный набор slots. Links/input/live registry сохраняют DOM requirement.
Отмена снимает адресный reader; поздний JS callback удерживает свой physical borrow
до фактического завершения и не отзывает новый native job.

При возврате к программе retained raster и статус остаются над новым WebKit до
точного first-paint receipt. Interaction-ready больше не снимает этот мост;
WebKit рисует под ним, поэтому ожидание собственного первого кадра не блокирует
исполнение. Отмена/смена source освобождают материал у прежнего preparation owner.
Проверка удерживает реальный WK paint callback и проверяет оба исхода передачи.

У всех сохранённых материалов есть source/version, владелец и terminal release.
Source replacement не принимает поздний результат чужой task; retirement отменяет
producers/subscribers, а GPU/worker borrows живут до своего fence. Бюджеты и causal
CAS сохранены. Актуальные контракты: [interaction ownership](interaction-ownership.md),
[performance](performance.md), [ink conflicts](page-ink-conflict-contract.md),
[allocation](scene-allocation-contract.md).

## Фактическая проверка

Результат каждого прогона относится к его source inventory. Подробные receipts
сохраняют отрицательные результаты; поздние изменения не делают их PASS.

| Проверка | Результат и граница |
|---|---|
| Core 100k / sparse support / UTF-16 / source digest | Persistent roots, paint order, writer read-set controls, authored UTF-16 offsets и page-body capability **PASS**. Core2258 содержит1 XCTest и3 Swift Testing метода (4 cases); digest2333 проверен отдельно. |
| Physical 0035 | **16 native PASS**, включая100k Undo/Redo, retained paint/damage, FIFO history и лассо; UI mixed PASS, UI24 FAIL. |
| Physical 0142 | **10 iPad +3 Mac PASS**: UI24, provider/cancel/cover/paper/crop, реальные Mac программы/экспорт. |
| Physical 0159 | **6 iPad +4 Mac PASS**: native PDF до held DOM, source replacement при удержанном старом sender, отмена и local runtime cut. |
| Physical 0240 | **5 iPad +1 Mac PASS**: retained slot до настоящего WK paint, never-ready статус, документ при held DOM, mixed cut и UI24. Curl этого прогона содержал позднее отклонённый эксперимент. |
| Final 0251 | **3 iPad +1 Mac PASS**, source `1df1f16c…`: первый малый изгиб, отмена pending capture, UI24 с первым нажатием/pinch/forward/reverse/state и повторный Mac zoom. Эксперимент curl удалён. |
| [Строгие0146](audit-evidence/2026-09-30/performance-repair-225/metrics-0146.json) | **5 FAIL**: dot24,324мс при цели20; SVG first314,918 и24programs396,156мс при цели150; Native24 landing497,910/484,675мс при цели450; Warm firstOS25,735–39,449мс при цели16,667. Reverse24 пиксели также FAIL. |
| [Native24 повтор0213](audit-evidence/2026-09-30/performance-repair-225/native24-0213.json) | Все24 возвращённые state/pixels **PASS**; landing452,745/515,296мс **FAIL**. Не отменяет прежний pixel failure. |

Удаление successor OS barrier подтверждено: следующий curl предъявляется до receipt
предыдущего. [CPU0220](audit-evidence/2026-09-30/performance-repair-225/warm-present-cpu-0220.json)
сопоставил длинный MainActor present с worker `CAMetalLayer.nextDrawable` и IOSurface
allocation на том же layer. CPU samples устанавливают перекрытие; точный lock waiter
остаётся гипотезой. Эксперимент сериализации acquisition после CA commit снизил
median present8,974→0,042мс, но ухудшил firstOS33,86→40,22мс и changing gaps.
[Отрицательный0243](audit-evidence/2026-09-30/performance-repair-225/warm-owner-phase-0243.json)
сохранён; эксперимент целиком удалён из225. Initialdrop и первая display opportunity
остаются открытыми; их адресное исследование продолжено в отдельном рабочем checkout.

UI0228 ошибочно отправлял `Application.pinch` внутрь программы6 вместо проверенного
центра бумаги; её счётчик изменялся ещё до первого нажатия. [Фактические контакты](audit-evidence/2026-09-30/performance-repair-225/ui24-0228-pinch-target.json)
и видео установили этот механизм. Тот же сценарий использует `Window.pinch`, чей
frame участвует в проверке центра; все24 требования сохранены и прошли0240/0251.

CPU0108 установил CIContext/grid work и реальные WebKit process/network/IPC stages
перед app policy. После ready приложение публикует native cut примерно за3,5мс.
Причина всей задержки return→policy не доказана;24 constructors также не объясняют
SVG-путь с двумя executor. Изоляция WebKit и constructor allowance сохраняются.

Native installation, GPU completion, OS presentation и diagnostic readback измеряются
отдельно. Стоимость наблюдения не вычитается. Hardware Pencil delivery, каждый
промежуточный mixed OS frame и полная CPU/GPU/memory приёмка остаются открытыми.
Итоговая доставка и выбранная проверка фиксируются в [verification](verification.md).


## Продолжение31–33 — первый полезный показ

Два изменения следуют из физической причинной проверки. До исправления лимит
«два конструктора» заканчивался внутри фабрики: в одном незавершённом UI cycle
успевали четыре WK-конструктора. `SceneWebConstructionAdmission` удерживает их
допуск до CA commit opportunity и `afterUpdateComplete`; очередная пара оставляет
время native installation и обработке событий. Навигация/JS имеют собственные
границы. Все фабрики документов, программ, SVG, чата, терминала и voice проходят
этого владельца. Отмена до конструктора возвращает допуск сразу; созданный view
сохраняет его до UI completion. Проверенный cold24 даёт максимум2 между completed
UI updates. Это ограничение CPU burst, а не доказательство бюджета firstOS.

CPU-профиль обнаружил пять полных Main-thread compiler wait stacks при монтаже:
два page curl shaders и три ink pipelines. Общие `SheetCurlGPU` и
`InkRasterRenderer` теперь готовят immutable GPU programs один раз в worker;
view и export заимствуют результат. Cold contact принимается до готовности,
пустая бумага сохраняет свою readiness. [Повторный профиль](audit-evidence/2026-09-30/first-presentation-scheduling/post-repair-cpu.json)
показал0 Main compiler samples и6 worker compiler stacks тех же владельцев.
В отдельном cold SVG largest CA commit уменьшился99,534→26,195мс. Стоимость
компиляции сохранилась в worker; оставшиеся UIKit/SwiftUI и WebKit стадии всё ещё
определяют первый вывод. Профиль и отдельные cold runs не устанавливают строгую
latency acceptance.

При проверке обратного перелистывания дополнительно установлен source handoff:
accepted model checkpoint ожидал необязательный passive picture. Отказ снимка
оставлял ушедшие browsers до достижения32 live owners. Уход теперь принимает
`ModelCheckpoint(source,basis)` и возвращает browser независимо от cache admission;
операция удерживает свой immutable cut. Принятый source/basis сразу переходят
в preparation owner и переживают запоздалую SwiftUI projection. Физический pressure
regression выявил старое значение в новом runtime при уже новом значении в SQLite;
после этого изменения уход и возврат показывают точный сохранённый момент.
Writer refusal сохраняет живое несохранённое состояние для retry.

Очередь из соседнего resource repair объединена в том же владельце:
32 ограничивает pending background preparation. Принятая current/visible/input
команда удерживает FIFO до grant либо source withdrawal и не выделяет backing,
пока ждёт. Background queue refusal, caller timeout и действительная allocation
failure имеют разные причины. Promotion сохраняет request и публикует реальную
смену доступности. Пять admission regressions и UI24 с первым нажатием, pinch,
forward/reverse и сохранённым состоянием прошли физически.

Оставшиеся интервалы измеряются у источников событий; JSON и screenshot/readback
создаются после остановки измерения. [Исходные часы и результаты](audit-evidence/2026-09-30/first-presentation-scheduling/diagnostic-runs.json)
сохраняют точные source и область каждого прогона.
В git оставлены стадии, причинные edges и выбранные стеки; полные event reports
сохранены в исходных receipt directories по `rawReport.path/sha256`.

| Интервал | Владелец и установленная граница |
|---|---|
| Cold store requested→began→ended→resumed | Startup store producer: в post-repair profile очередь0,174мс, работа40,726мс; возврат actor около0,03мс. Source installation и presence write имеют отдельные часы. |
| Первые CA commits | UIKit/SwiftUI mount/layout/AttributeGraph; compiler waits выведены из Main. Profiled commit30,334мс содержит generic metadata и display-list work. В другом commit есть synchronous dyld notification от Instruments: эту цену наблюдения нельзя приписывать приложению. |
| WK native constructor | Фабрика и WebKit: первый constructor в post-profile33,952мс. Последующие допуски чередуются с UI completion. |
| Navigation requested→policy→started→runtime ready | WebKit launch/IPC и delivery на Main; дальнейшее разложение этого совместного интервала остаётся открытым. Он не доказывает отдельную длительность WebKit process launch. |
| Dot GPU-ready→OS | В исходном native cut GPU4,677мс, OS20,395мс совпадает с UIKit predicted target20,394мс. Дополнительная app-clock парковка не обнаружена. Hardware Pencil delivery этим harness не измеряется. |
| Curl GPU→CA→OS | [Metal System Trace](audit-evidence/2026-09-30/first-presentation-scheduling/curl-system-boundary.json): первый GPU5,887мс, present5,518→11,740мс, CA-after12,169мс. Seq0 discarded до следующего present; seq2 shown30,065мс совпадает с точным display-swap30,065мс. Successor уже публикуется до predecessor OS. Причина initial discard внутри системного пути пока не установлена. |

Эксперимент с постоянно раскрытым curl container не исправил first discard и
нарушил regrab/cancel. Его изменения полностью удалены;
[отрицательный результат](audit-evidence/2026-09-30/first-presentation-scheduling/rejected-visible-container-experiment.json)
сохранён. Нет подтверждённого основания добавлять новый layer/present barrier.
Строгие бюджеты первого штриха, cold source и curl остаются открытыми; final
receipt и доставка226 фиксируются в [verification](verification.md).


Финальный unprofiled cold24: first native418,636мс, все программы937,754мс,
largest CA commit31,124мс, максимум2 constructors/UI completion. В том же процессе
последующий dot показан18,675мс, curl34,600мс; эти warm observations сохраняют
свой scope и не заменяют серию cold/hardware повторений. Source reports лежат
рядом с исходными измерениями. Корреляция CPU trace с CA source clocks в
`post-repair-cpu.json` выведена из25 constructor samples; её uncertainty0,250мс
указана явно, поскольку Instruments не экспортировал clock table.

[UI target repair](audit-evidence/2026-09-30/first-presentation-scheduling/pinch-harness-target.json):
Window pinch однажды доставил оба fingers около(442,417) внутрь control6,
хотя frame centre был(417,597). Видео подтвердило1 после жеста. Проверка теперь
обращается к существующему `page-turn-surface`; все24 остаются неизменёнными после
pinch и отвечают на первый tap, close/reopen/forward/reverse сохраняют состояние.
Утверждения не ослаблены, новая AX поверхность и private injection не добавлены.
Public XCTest pinch остаётся best effort; один frame centre не доказывает delivery.
