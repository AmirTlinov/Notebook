# Причинное ревью производительности и UX — 30 сентября 2026

## Срез и метод

Проверен чистый `main` / `origin/main`: `e4948f8e965eb1d27fd5cc4499a56649588bf31a`. Код приложения — `28f11aee`; source inventory — `0a4be7f8f9205fe433877a9680d76cb1ed94615f7d0deb36ec06f1d1f808b14d`. Он совпадает с receipt установленной пары **0.3.154 (224)**. Основной checkout и прежний causal-repair worktree содержали эту ревизию; новой продуктовой ветки нет.

В этой работе продукт не изменялся, сборки и прогоны не запускались. Три субагента проследили чернила/выделение, страницу/переходы, документы/программы; последний также проверил writer/read boundaries. Главный агент проверил существенные цепочки по исходникам и согласовал решения между владельцами. Ссылки и номера строк ниже относятся к анализируемой ревизии; после ремонта смотреть её через git.

**Диагноз:** владельцы уже появились, но размер их работы и смысл их готовности ещё расходятся с пользовательским действием. Локальная дельта инвалидирует весь материал; готовое содержимое ждёт независимого участника; долговременная запись ждёт представления; общий source revision разрушает уже принятое движение. Поэтому приложение может правильно закончить сценарий и всё ещё давать тяжёлый первый отклик, паузы между действиями и непредсказуемые отмены.

Код доказывает выполняемую лишнюю работу и ошибочные зависимости. Её точная доля в оставшихся миллисекундах не измерена. Ни размер файла, ни `await`, ни зелёный тест сами по себе не использованы как доказательство дефекта.

## Известные измерения

| Сценарий и источник | Результат | Что измерено |
|---|---|---|
| 224, cold SVG, 1919; source совпадает | first **496,130 мс**, all **636,387 мс** | Native installation; first >150 мс. Первый физический показ отдельно не измерен |
| 224, 24 программы, 1919; source совпадает | first **409,023 мс**, all **700,479 мс** | Native installation; first >150 мс. Теперь 24 запуска вместо прежних 46 |
| Warm curl, 1900; код curl не менялся в окончательном срезе | first OS **29,290–37,787 мс**, landing **322,527–333,840 мс**; один initial drop на каждом из 10 поворотов | Физический receipt drawable. Первый интервал 16,673 мс, далее преимущественно 8,337 мс |
| 224, функциональный 1913; source совпадает | **5 iPad + 1 Mac PASS** | Первые нажатия, pinch-exit/reopen, forward/reverse, состояние и фокус; не общий PASS производительности |

Receipt: [доставка](audit-evidence/2026-09-29/first-presentation-224/delivery.json), [результаты](audit-evidence/2026-09-29/first-presentation-224/results.json), [точный scope прогонов](verification.md). Прежние cold-document и Native24 FAIL не перепроверялись на 224. Полная системная приёмка остаётся открытой.

## Карта решений

| Действие | Принимает и хранит намерение | Готовит и устанавливает | Завершает/отменяет |
|---|---|---|---|
| Pencil, следующий Undo | `NotebookInputGate`, native contact, domain history | Prepared ink source → `InkCanvasView`; writer сохраняет принятое действие | Finisher контакта; history owner завершает принятую команду |
| Смешанный перенос/удаление | `NotebookSelectionSession`, frozen source/read set | `NotebookSelectionPresentation` + canvas/authored hosts/controls одним cut | Presentation до acceptance владеет rollback; после него — canonical handoff |
| Поворот страницы | `IPadPageTurnController.Operation`, UUID исходной и целевой страниц | `PageTurnMaterialOwner` → curl renderer | Controller удерживает пару до единственного terminal outcome |
| Документ/программа | `DocumentRenderSession` / source snapshot; `DocumentProgramOwner` | `DocumentPagePreparation`, page presentation, runtime, общий resource admission | Сессия/операция освобождает subscribers; runtime — исполнение и фокус |
| Агентское изменение | Durable writer, causal dependencies | Addressed read admission → accepted source → локальная публикация | Writer завершает запись; presentation независимо завершает показ |

## Приоритетные находки

### D01 · P1 · Локальная дельта чернил превращается в повторную обработку принятой композиции

1. **Проявление.** На плотной странице отрыв пера, Undo и завершение подготовки длинного штриха вызывают дополнительную тяжёлую работу. При письме на доске/обложке стоимость каждого кадра растёт с resident geometry и числом тайлов даже при неподвижной камере.
2. **Цепочка.** [InkCanvasView:304](../Applications/Shared/InkCanvasView.swift#L304): изменение `committedBatches` повышает generation → [retained key:514](../Applications/Shared/InkCanvasView.swift#L514) → [renderFrame:1606](../Applications/Shared/InkCanvasView.swift#L1606) очищает retained texture и кодирует весь видимый принятый stream. Замена derived mesh одного штриха [2678](../Applications/Shared/InkCanvasView.swift#L2678) делает то же самое. Spatial branch [1630](../Applications/Shared/InkCanvasView.swift#L1630) для каждого тайла вызывает `visibleChunks` [2021](../Applications/Shared/InkCanvasView.swift#L2021) и `tileSignature` [2058](../Applications/Shared/InkCanvasView.swift#L2058); изменённый тайл рисует старый префикс заново [1707](../Applications/Shared/InkCanvasView.swift#L1707).
3. **Лишняя работа.** На странице локальный accepted change даёт полный видимый repaint. На spatial surface каждый кадр повторно ищет, сортирует и подписывает неизменённые ranges; каждый затронутый тайл повторно рисует прежние чернила. Это обход resident buffers, а не декодирование всей базы. Обычные page pen samples уже используют retained base + active tail.
4. **Основание.** Ветки исполняются при названных изменениях. Тест [PageInkGeometryTests:584](../Applications/Tests/PageInkGeometryTests.swift#L584) защищает active pen, но прямо ожидает полный pass на lift. Spatial 100k test считает другие query/decode counters; эти frame loops туда не входят. Их доля в текущем OS latency неизвестна.
5. **Исправление.** У существующего canvas разделить paint revision и жизнь derived buffers. Хранить принятые tile lists/backing с ключом source/viewport/LOD; camera/source delta обновляет membership один раз. Обычный новый верхний stroke добавляется в accepted backing; Undo/erase/перестановка передают точный damage и повторно рисуют только пересекающие его тела в painter order. Pixel-equivalent mesh replacement сохраняет paint revision. Удалить generation-driven whole repaint как обычный путь локальной дельты и per-frame discovery неизменённых ranges.
6. **Почему/риски.** Работа следует изменённым пикселям и источникам. Alpha, destination erase и порядок могут требовать replay затронутой области: слепой append всех операций некорректен. Backing и lists принадлежат canvas/resource owner, обновляются по accepted delta, освобождаются при retirement после leases/GPU fences; второй глобальный кеш не нужен.
7. **Проверка.** Плотная страница и 100k spatial source: continuous pen → lift → новый контакт, Undo раннего перекрытого stroke, erase, замена mesh длинного stroke. Считать реально посещённые ranges и закодированные accepted bodies; отдельно проверить правильные пиксели и физический отклик.

### D02 · P2 · Каждый mixed move подготавливает весь ordered plan

1. **Проявление.** Перемещение нескольких выбранных объектов на насыщенной странице получает стоимость чужого содержимого.
2. **Цепочка.** [NotebookSelectionPresentation:217](../Applications/Shared/NotebookSelectionPresentation.swift#L217) собирает невыбранные и изменённые тела в полный plan; [234](../Applications/Shared/NotebookSelectionPresentation.swift#L234) вызывает `prepareOrderedPlan`. [InkOrderedGeometry:16](../Applications/Shared/InkOrderedGeometry.swift#L16) проходит каждое тело и готовит wrapper/clip. Установка уже умеет `replacing: ids` [NotebookSelectionPresentation:249](../Applications/Shared/NotebookSelectionPresentation.swift#L249).
3. **Лишняя работа.** Reuse GPU mesh сохраняет буфер, но полный обход, построение контейнеров и проверку clip всё равно выполняются до установки каждой новой позы.
4. **Основание.** Установлен per-pose путь. Новый дефект согласованности cancel не найден: canvas, authored poses и controls ставятся общей транзакцией; queued restoration повторно проверяет source. Это не доказывает целостность всех промежуточных OS frames.
5. **Исправление.** Selection session удерживает геометрию принятого состава и исходную позу; обычное движение меняет transform. Готовить patch выбранных IDs, объединять с текущей композицией у canvas, используя существующий addressed installation. Переподготовка нужна при изменении selected source/clip, смене масштаба качества; завершение освобождает temporary material через его fences. Удалить сборку/подготовку всего plan на move.
6. **Почему/риски.** Стоимость движения зависит от выбора. Patch должен быть привязан к actual source witness и painter order, чтобы чужая одновременная правка не была перезаписана старым полным plan. D01 отдельно устраняет полный repaint уже после подготовки.
7. **Проверка.** Raw ink + shape + text: drag/reverse/cancel при агентской правке другого объекта. Неизменённые geometry buffers сохраняются; материал и рамка принадлежат одной позе; исходный erase остаётся в переносимом материале.

### D03 · P1 · Mixed/raw Delete удерживает общий writer до native/GPU установки

1. **Проявление.** Удаление может задержать последующую независимую запись и чтение новой страницы, если selected host/drawable ещё не готов.
2. **Цепочка.** [NotebookAppModel:3467](../Applications/Shared/NotebookAppModel.swift#L3467) готовит frozen delete, но pending plan ждёт `presentation.awaitFirstInstallation()` [3470](../Applications/Shared/NotebookAppModel.swift#L3470). [enqueueElementCommand:4230](../Applications/Shared/NotebookAppModel.swift#L4230) занимает FIFO; [NotebookPersistenceQueue:309](../Applications/Shared/NotebookPersistenceQueue.swift#L309) ждёт preparation головной записи. Presentation может ждать required host до двух секунд [NotebookSelectionPresentation:89](../Applications/Shared/NotebookSelectionPresentation.swift#L89).
3. **Блокировка.** Независимые записи и read fences ждут physical presentation. Ни GPU result, ни факт установки не участвуют в causal CAS immutable delete: [NotebookElementCommand:105](../Applications/Shared/NotebookElementCommand.swift#L105).
4. **Основание.** Writer и presentation прочитаны совместно. Просто удалить `await` опасно: `didAcceptSource` [331](../Applications/Shared/NotebookSelectionPresentation.swift#L331) отзывает rollback и вызывает `authoredHostUnmounted`; условие `deleting && !installed` [347](../Applications/Shared/NotebookSelectionPresentation.swift#L347) пока считает новый законный порядок ошибкой.
5. **Исправление.** Presentation получает явный `acceptedAwaitingPresentation`. Writer принимает frozen command/read sets независимо от drawable. Presentation удерживает последний согласованный cut/hosts до canonical source cursor ≥ accepted cursor, используя существующую границу [canonicalInstalled:401](../Applications/Shared/NotebookSelectionPresentation.swift#L401). После acceptance private-preview failure завершает preview и согласует актуальный canonical source; rollback остаётся только до acceptance. Удалить GPU await из writer preparation и несовместимое условие post-acceptance failure.
6. **Почему/риски.** Долговременный порядок сохраняется без зависимости всей базы от окна. Нельзя после accepted delete восстановить удалённое semantic content или объявить запись неуспешной из-за исчезнувшего host. Затронутый ввод может ждать согласованного видимого cut у presentation.
7. **Проверка.** Удержать private drawable/host, принять delete и независимую запись. Обе durable команды завершаются; изображение сменяется согласованным successor. CAS conflict сохраняет rollback; cancel после acceptance не воскрешает объект.

### D04 · P1 · Быстрые authored Undo/Redo ждут чужой flush и полный scene refresh

1. **Проявление.** Повторные Undo/Redo authored objects становятся последовательными с несвязанным сохранением и внешней публикацией.
2. **Цепочка.** [performSurfaceHistory:2856](../Applications/Shared/NotebookAppModel.swift#L2856) удерживает следующий history request за предыдущим task; тот ждёт общий `persistence.flush`, collaboration history и `reloadExternalChanges` [2871](../Applications/Shared/NotebookAppModel.swift#L2871). `undoCollaboration`/`redoCollaboration` также запускают refresh [5830](../Applications/Shared/NotebookAppModel.swift#L5830).
3. **Блокировка.** Для следующего inverse нужны accepted result предыдущей команды и актуальный history domain; в join попадают чужой writer tail и общая сцена.
4. **Основание.** Ordinary raw ink Undo проходит ранний synchronous return [2853](../Applications/Shared/NotebookAppModel.swift#L2853); его этой находкой не описываем. Native history ограничена 32 entries / 64 KiB и читает eligibility headers — бесконечная обработка истории здесь не доказана.
5. **Исправление.** History owner получает addressed accepted receipt и обновлённый domain непосредственно от command completion. Следующий inverse зависит от предыдущей domain command. Presentation упорядочивает свои cut receipts отдельно. Удалить global flush/scene reload из завершения каждого accepted history request; полный durability join оставить явной lifecycle границе.
6. **Почему/риски.** Повторная команда не ждёт независимые данные. При rejection предыдущей команды зависимые inverse должны иметь определённый исход; нельзя выбрать действие из устаревшей domain directory или переставить writer commands.
7. **Проверка.** Задержать независимую preparation и scene refresh; два быстрых authored Undo/Redo должны применить правильные inverse по порядку. Отдельно rejected first command и raw ink Undo.

### D05 · P1 · Общий refresh сначала декодирует прежние страницы и занимает foreground reader

1. **Проявление.** Агентское изменение metadata/другой страницы снова нагружает чтение; открытие новой страницы ждёт уже начавшийся background refresh.
2. **Цепочка.** [NotebookDiskRefresh:83](../Applications/Shared/NotebookDiskRefresh.swift#L83) читает сцену и history/contexts/feedback/delivery/index в одном read operation. [NotebookSceneState:200](../Applications/Shared/NotebookSceneState.swift#L200) безусловно вызывает `readNotebookPageWindow`; [NotebookPageWindow:172](../Sources/NotebookCore/NotebookPageWindow.swift#L172) загружает каждый body. Только после этого сравнивает с прежним page. Всё идёт через единственный несуспендируемый [NotebookSceneReader.read:119](../Applications/Shared/NotebookDiskRefresh.swift#L119).
3. **Лишняя работа/ожидание.** До четырёх удержанных страниц заново читаются, records декодируются/собираются и typed body валидируется, даже если затем возвращается старый объект. Число hosts ограничено, размер этих bodies — нет. Адресный пользовательский read не может обойти активный синхронный refresh.
4. **Основание.** Identity reuse устраняет последующие rebuilds, но выполняется после decode. В том же файле уже есть правильный образец [NotebookPagePreparation.read:18](../Applications/Shared/NotebookDiskRefresh.swift#L18): source revision проверяется до load. Длительность reader head-of-line ещё не измерена.
5. **Исправление.** Удерживать accepted `(UUID, body, full pageSourceRevision)` из одного WAL cut; перед body load сравнивать полный stored-source digest. Membership, deletion и history читать заново. Публикацию адресовать affected targets; metadata читать отдельно. Если оставшийся index/metadata проход значим, foreground requested reads получают отдельный ограниченный WAL reader с собственным session/shutdown; background reader не владеет их admission. Удалить reuse после безусловного decode.
6. **Почему/риски.** Посторонняя правка не перечитывает неизменённый body. Одного stamp недостаточно; same-stamp changed bytes должны обновляться. Очередь с приоритетом не прерывает уже исполняющийся synchronous read. Разделение reader не даёт права публиковать результат без source witness и увеличивать число SQL sessions без границы.
7. **Проверка.** 100k page + unrelated agent metadata edit: нет повторного body decode. Same-stamp changed source обновляется; удалённая страница исчезает. Requested cold page во время metadata read сохраняет точную latest-request/source проверку.

### D06 · P1 · Готовая native бумага документа ждёт ответа прозрачного WebKit

1. **Проявление.** PDF-страница уже подготовлена, но холодное открытие продолжает ждать shell/JavaScript.
2. **Цепочка.** [DocumentWebView.prepareAndSendFrame:1862](../Applications/Shared/DocumentWebView.swift#L1862) получает `DocumentPaperRaster`; затем ждёт shell readiness и `evaluateFrame` [1900](../Applications/Shared/DocumentWebView.swift#L1900). Только после ответа устанавливает `printedView` [1904](../Applications/Shared/DocumentWebView.swift#L1904). На iPad программы externally hosted; shell обслуживает ссылки/hit regions.
3. **Блокировка.** Нативные пиксели бумаги поставлены после независимой готовности DOM взаимодействий. Общий `hasCanonicalPixels` [355](../Applications/Shared/DocumentWebView.swift#L355) также смешивает несколько видов готовности.
4. **Основание.** Порядок установки доказан. Прежний cold-document FAIL не является новым измерением этого участка на 224; точная доля shell ожидания неизвестна.
5. **Исправление.** Document page owner различает versioned `paperReady`, `interactionReady`, `compositeCaptureReady`. Устанавливать raster сразу после проверки document/source/page/operation; прежний DOM ввод закрыт до соответствующего interaction receipt. Полный capture ждёт необходимые slots/hit state у своего owner. Удалить единственный paper install из хвоста JS evaluation.
6. **Почему/риски.** Пользователь видит и может использовать native paper независимо от запуска программ. Нельзя активировать ссылки предыдущего source под новой бумагой или выдать раннюю бумагу за полный интерактивный кадр.
7. **Проверка.** Задержанный/неответивший shell: точная бумага показывается, чужие ссылки не активны. Быстрая смена source/page не устанавливает старый raster. После matched receipt правильный фокус и hit regions включаются.

### D07 · P1 · Layout всего печатного документа повторно проходит исходник на MainActor

1. **Проявление.** Большой новый/изменённый TeX-документ задерживает ввод и первый показ после получения print artifact.
2. **Цепочка.** PDF navigation/locations готовятся worker, но [DocumentPagePreparation:278](../Applications/Shared/DocumentPagePreparation.swift#L278) возвращает layout на MainActor. Для каждой пары page/file [sourceOffset:313](../Applications/Shared/DocumentPagePreparation.swift#L313) заново делит весь source на строки ([DocumentPrintLocations:194](../Sources/NotebookCore/DocumentPrintLocations.swift#L194)); каждая страница проходит все interactive regions [322](../Applications/Shared/DocumentPagePreparation.swift#L322). Typed layout сериализуется в `NSDictionary` и разбирается обратно [334](../Applications/Shared/DocumentPagePreparation.swift#L334).
3. **Лишняя работа.** Повторные O(pages × source) line-offset passes, O(pages × slots) фильтрация и internal receipt roundtrip в UI actor. Это холодный/new-print путь: exact artifact reuse его обходит.
4. **Основание.** Циклы и actor граница подтверждены. Для длинного документа физическая длительность этой фазы пока неизвестна; TeX compile из этой находки не следует ускорять уменьшением необходимых passes.
5. **Исправление.** Immutable print preparation строит один UTF-16 line-offset index каждого source, page-indexed slots и validated typed layout на worker. MainActor принимает exact source/operation, резервирует/устанавливает результат и сообщает owner. Layout живёт с print source и leases; смена источника освобождает предыдущий после borrowers. Удалить per-page source split и внутренний dictionary parse; внешние недоверенные browser receipts валидировать по-прежнему.
6. **Почему/риски.** Устраняется повторный проход и CPU пауза ввода. Нужно сохранить UTF-16 offsets, reading anchors, geometry bounds и cancellation/source acceptance; перенос полного квадратичного прохода на worker решает только половину причины.
7. **Проверка.** Длинный один TeX-file с множеством страниц/slots: offsets, links и reading anchors совпадают; число source passes одно на файл, MainActor не выполняет построение layout. Затем физический cold open и immediate input.

### D08 · P1 · Программы документа ждут весь набор descriptors и повторяют package work

1. **Проявление.** Первая готовая программа не запускается, пока подготовлены остальные текущие/retained экземпляры. Несколько экземпляров одного program path повторяют подготовку одинакового пакета.
2. **Цепочка.** [DocumentPagePresentationOwner:1130](../Applications/Shared/DocumentPagePresentationOwner.swift#L1130) ждёт `preparePrograms(immediate, retaining:)` целиком. [DocumentPagePreparation:432](../Applications/Shared/DocumentPagePreparation.swift#L432) последовательно ждёт instance IDs. [DocumentProgramSource:18](../Sources/NotebookCore/DocumentProgramSource.swift#L18) строит parts/manifest для каждого экземпляра; staging/canonical validation происходит в [NotebookProgramPackage:116](../Sources/NotebookCore/NotebookProgramPackage.swift#L116). Затем runtime снова читает package из store [DocumentBlockRuntime:149](../Applications/Shared/DocumentBlockRuntime.swift#L149).
3. **Лишняя работа/ожидание.** Один медленный descriptor задерживает публикацию готовых. Instance identity используется для повторного hashing/staging одинакового source package; уже проверенный package заново читается/валидируется перед запуском.
4. **Основание.** Current source snapshot кеширует готовые instance IDs, поэтому работа не повторяется на каждом кадре. Дефект касается новых экземпляров/source snapshots и batch acceptance; доля в cold-first не измерена.
5. **Исправление.** Source snapshot владеет единственным package producer с ключом normalized path + точные dependency bytes/causal basis. Instance descriptor/state остаются отдельными. Staging выполняется один раз; каждый готовый descriptor публикуется ProgramOwner сразу. Runtime заимствует validated package/capability source owner; удалить повторный store-read и barrier всего набора. Consumers отменяются по instance; producer — по жизни source/последнему subscriber.
6. **Почему/риски.** Первая программа зависит от своего пакета. Нельзя объединять состояние/фокус экземпляров или переиспользовать package только по path без dependency witness. Ограниченное staging сохраняет writer порядок; immutable blobs и package lifetime остаются учтёнными.
7. **Проверка.** Два instance одного path и один медленный другой path: один hash/stage, независимые состояния; первый готовый запускается до медленного. Source replacement/cancel не публикуют прежний descriptor.

### D09 · P1 · Document runtimes обходят общий лимит конструирования WebKit

1. **Проявление.** Холодная страница с множеством document programs может серийно занять MainActor созданием WKWebView; повышение приоритета pending runtime отменяет и создаёт admission заново.
2. **Цепочка.** [acquireDocumentProgramSurface:1061](../Applications/Shared/SceneRenderResources.swift#L1061) передаёт `constructsRuntime:false` и новый UUID. Общий лимит двух constructions [canAdmit:1196](../Applications/Shared/SceneRenderResources.swift#L1196) для него выключен. [DocumentBlockRuntime.start:121](../Applications/Shared/DocumentBlockRuntime.swift#L121) отменяет pending start при смене priority; [142](../Applications/Shared/DocumentBlockRuntime.swift#L142) действительно создаёт WKWebView.
3. **Лишняя работа/ошибка admission.** Две ветки программ расходятся в учёте одной дорогой ресурсоёмкой операции. Pending request теряет очередь и исходную admission identity; уже полученная lease умеет updatePriority, ожидающая — нет.
4. **Основание.** Создание и bypass проверены вместе. Это доказанный document path; холодные 24 Notebook programs из 1919 относятся к другому владельцу, где request preservation уже исправлено.
5. **Исправление.** Использовать общий constructor admission с persistent request UUID, изменяемым priority и сохранёнными deadline/order. Подготовить state/package до короткой construction allowance; освободить её после фактического native init, не ждать author-ready/navigation. После await принимать актуальную роль runtime. Удалить document bypass и cancel/requeue на простом priority change.
6. **Почему/риски.** Notebook и document programs делят один реальный construction budget; очередь не перезапускает полезную работу. Если просто поставить `constructsRuntime:true` перед state/package I/O, два места будут заняты подготовкой вместо создания — порядок тоже должен измениться. Stop/source replacement по-прежнему завершает request и lease.
7. **Проверка.** Dense document + Notebook queue, preview→current/input promotion: один accepted request на runtime, общий construction limit соблюдён, первая программа запускается без ожидания полного набора; cancel освобождает продолжения/ресурсы.

### D10 · P1 · Невидимые raster sources конкурируют с текущим viewport на равном приоритете

1. **Проявление.** При zoom/crop несколько тяжёлых невидимых SVG/passive programs могут занять оба raster исполнителя раньше видимого элемента или принятой turn target.
2. **Цепочка.** [PageElementProjection:51](../Sources/NotebookCore/PageElementProjection.swift#L51) сохраняет все non-graphic элементы. [PageAgentPreparationOwner:111](../Applications/Shared/PageAgentPreparationOwner.swift#L111) готовит offscreen passive sources; visible region главным образом выбирает live роль. [PageRasterPreparation:90](../Applications/Shared/PageRasterPreparation.swift#L90) и сортировка [105](../Applications/Shared/PageRasterPreparation.swift#L105) ранжируют по странице, не по видимости внутри неё; исполнителей два.
3. **Блокировка.** Порядок источников на одной текущей странице определяет первый visible output; неподготовленное невидимое содержимое попадает на критический путь.
4. **Основание.** Demand и queue path подтверждены. Fitted-page 1919 этот cropped сценарий не воспроизводит; им не доказана численная стоимость при zoom.
5. **Исправление.** Page owner публикует addressed viewport demand по UUID/source/geometry. Pending jobs ранжируются: visible current, accepted turn target, остальное/neighbor. Полный curl предъявляет явный full-sheet demand. Один существующий producer получает обновление demand; уже submitted capture сохраняет свой fence. Удалить equal-page-only ranking как решение первого показа.
6. **Почему/риски.** Видимый результат не ждёт offscreen preparation. Нельзя просто пропустить остальную страницу и получить пустые участки curl; полный материал остаётся отдельным необходимым результатом turn owner.
7. **Проверка.** Cropped viewport: два тяжёлых offscreen источника и один маленький visible. Visible первым; быстрый полный turn получает весь материал; возврат использует только source-matched результат.

### D11 · P1 · Локальная правка заново растеризует material всей страницы для curl

1. **Проявление.** После изменения одной фигуры/text/erase следующий turn ждёт повторную подготовку прочего содержимого; на насыщенной странице эта работа мешает UI actor.
2. **Цепочка.** Whole-page [PageTurnMaterialOwner.Key:57](../Applications/Shared/PageTurnMaterialOwner.swift#L57) включает native elements, slots, erasures и order. Любая дельта [prepare:185](../Applications/Shared/PageTurnMaterialOwner.swift#L185) отменяет preparation и обнуляет layers. [prepareLayers:624](../Applications/Shared/PageTurnMaterialOwner.swift#L624) рисует все native/text через синхронный [SceneRasterCompositor:181](../Applications/Shared/SceneRasterCompositor.swift#L181); static slots также заново flatten/upload [PageTurnMaterialOwner:280](../Applications/Shared/PageTurnMaterialOwner.swift#L280).
3. **Лишняя работа.** Неизменённые elements заново проходят ImageRenderer/CPU bitmap/GPU upload. Retained whole-page material помогает повторному turn без изменений, но локальную правку делает whole-page miss.
4. **Основание.** Branch и downstream renderer проверены. Обычный raw pen append не меняет этот key; partial erase инвалидирует после acceptance, а не обязательно на каждом sample. Live program frames имеют отдельную source generation.
5. **Исправление.** В существующем owner держать immutable material по element ID и exact source/layout/erasures/ordered-role/scale. Reconcile заменяет затронутые записи и порядок слоёв; pose-only change сохраняет локальные pixels. Общий composed frame меняется, исходные слои остаются. Accepted turn удерживает старый complete material; successor публикуется после собственной подготовки. Удалить `layers=nil → prepareLayers(all)` как обычный local-edit путь.
6. **Почему/риски.** Работа следует affected sources. Group transform затрагивает descendants, новый scale — необходимое качество; erase/painter order обязаны остаться точными. Материал освобождается owner после leases/GPU, а не через независимый второй кеш.
7. **Проверка.** Dense native/text/SVG page: erase одной фигуры → immediate turn, затем move/Undo group. Неизменённые texture identities сохраняются, переработаны только affected IDs; accepted/cancelled turn не получает частичный successor.

### D12 · P1 · Pending/error программа Notebook запрещает навигацию всей страницы

1. **Проявление.** Бумага доступна, пользователь видит загрузку/ошибку программы, но forward/back не начинается. Never-ready без прежнего raster не имеет успешного выхода в capturable.
2. **Цепочка.** [PreparedAgentElementView:149](../Applications/Shared/PreparedAgentElementView.swift#L149) рисует pending/error как Text/VStack. [PreparedAgentElementPreparation:293](../Applications/Shared/PreparedAgentElementPreparation.swift#L293) регистрирует frame только raster/runtime. [PageTurnMaterialOwner.isCapturable:175](../Applications/Shared/PageTurnMaterialOwner.swift#L175) требует frame всех slots; [IPadPageTurnController.canBeginTurn:663](../Applications/iPad/IPadPageTurnController.swift#L663) требует обе capturable pages.
3. **Ошибка готовности.** Установленное законное состояние слота не признаётся material страницы; готовность авторского исполнения стала условием ухода пользователя.
4. **Основание.** Вся цепочка проверена. Длительность не измерялась; pending/error семантика исходниками подтверждена. В document presentation существует placeholder подход, но Notebook путь его не использует.
5. **Исправление.** Existing slot preparation owner владеет versioned display cut `.runtime/.raster/.pending/.error`, включающим source, geometry и pixels. View, page readiness и curl заимствуют один cut. Interaction-ready программы остаётся отдельным условием. Удалить независимый SwiftUI placeholder и обязательность author-ready для capture/landing.
6. **Почему/риски.** Навигация использует то, что фактически показано. Одного fallback только в curl недостаточно: [PageSurfaceReadiness:25](../Applications/Shared/PagePresentation.swift#L25) и endpoint тоже должны принять placeholder. Нельзя выдавать loading/error за готовую интерактивную программу или менять borrowed turn pair при её позднем запуске.
7. **Проверка.** Never-ready и throwing программа: писать, forward/back/cancel, повторить после Retry. Изображение слота совпадает с видимым состоянием; успешный запуск меняет только его cut, соседняя страница доступна.

### D13 · P1 · Любая правка файла документа отменяет принятый curl

1. **Проявление.** Агент меняет JS/CSS во время поворота — лист возвращается, хотя printed pages не менялись.
2. **Цепочка.** Durable merge вызывает `reloadExternalChanges`; [permitsExternalScenePublication:4688](../Applications/Shared/NotebookAppModel.swift#L4688) допускает публикацию при camera activity с разрешённой scene preparation, а после lift — при свободном вводе. [DocumentDocument.replaceContent:78](../Sources/NotebookCore/DocumentDocument.swift#L78) меняет общий `contentStamp`; [SpatialWorkspaceView:1723](../Applications/iPad/SpatialWorkspaceView.swift#L1723) превращает его в sequence revision. [IPadPageTurnController:476](../Applications/iPad/IPadPageTurnController.swift#L476) определяет `documentSourceChanged`; [516](../Applications/iPad/IPadPageTurnController.swift#L516) сбрасывает transition/readiness и вызывает `cancelMotion(.superseded)`.
3. **Ошибка состояния.** Новизна всего document source одновременно управляет жизнью physical operation. `DocumentPagePresentationOwner.gestureLocked` уже не спасает: верхний контейнер первым очищает PageTurnActivity.
4. **Основание.** Source mutation и controller проверены совместно. Зелёный [testSourceReplacementDuringBorrowKeepsTheAcceptedTurn:14](../Applications/Tests/NotebookPageMotionUXTests.swift#L14) создаёт только SheetCurlController и не проходит через этот document container. Физическая частота дефекта не измерена.
5. **Исправление.** Turn operation удерживает accepted print/layout revision и пару page presentations до terminal outcome. Новый document source — successor, его подготовка независима, установка согласована на завершении/отмене. Program source basis меняется отдельно. При той же пагинации сохраняются hosts; при новой landing разрешается через reading anchor/устойчивую идентичность. Удалить unconditional source-change cancellation.
6. **Почему/риски.** Независимая программная правка не отзывает жест. Просто игнорировать revision нельзя: старый индекс нельзя применить к другой пагинации; удаление документа остаётся explicit cancel, старый runtime не получает право писать новую source version.
7. **Проверка.** Forward/reverse/regrab с агентской JS/CSS правкой; затем TeX repagination под удержанным curl. Стабильная старая пара заканчивается определённым outcome, successor ставится один раз, чужая страница не выбирается.

## Дополнительные точные границы

### D14 · P2 · После физического lift быстрый Undo может молча потеряться

1. **Проявление.** Реальный Pencil отпущен, UIKit ещё обещает force estimates; пользователь сразу нажимает Undo/Redo.
2. **Цепочка.** [PencilCanvasView.touchesEnded:790](../Applications/iPad/PencilCanvasView.swift#L790) устанавливает `activeTouch=nil`, но при pending estimates откладывает finalization. Pencil activity снимается только после `finishAction` [1302](../Applications/iPad/PencilCanvasView.swift#L1302); fallback — [120 мс:672](../Applications/iPad/PencilCanvasView.swift#L672). [performSurfaceHistory:2836](../Applications/Shared/NotebookAppModel.swift#L2836) при `hasActivePencil` молча возвращается.
3. **Ошибка состояния.** Physical contact и released pressure-finalization используют один active флаг; команда не принимается и не ставится за последним штрихом.
4. **Основание.** Условная цепочка доказана. Обычные stub touches имеют пустые estimates и её обходят; частота/длина окна на настоящем Pencil неизвестна. Не каждый lift ждёт 120 мс.
5. **Исправление.** Gate/contact owner различает physically-down и released-finalizing. History принимает команду после lift, вызывает существующий [finishCurrentAction:743](../Applications/iPad/PencilCanvasView.swift#L743), который freeze latest measurements и заканчивает estimates, затем выбирает inverse. Удалить silent post-lift rejection; реально опущенное перо сохраняет исключительность.
6. **Почему/риски.** Принятый Undo выполняется один раз без второго tap/таймера. Поздний force callback не должен менять/воскрешать завершённый или undone stroke; palm contact при настоящем письме не становится history intent.
7. **Проверка.** Pending estimates at lift → immediate Undo → late callback: один accepted action/inverse. Затем физический trace touch-up/pending count/finalization/admission для оценки частоты.

### D15 · P2 · Immutable erasure directory всё ещё копирует историю metadata на локальном acceptance

1. **Проявление.** Много прежних стираний одного объекта или много targets: новый erase/Undo может делать растущую synchronous работу на lift.
2. **Цепочка.** [NotebookAppModel.acceptInkMutation:3060](../Applications/Shared/NotebookAppModel.swift#L3060) синхронно вызывает prepared mutation. [PageDocument:268](../Sources/NotebookCore/PageDocument.swift#L268) обновляет [PageInkErasureDirectory.applying:104](../Sources/NotebookCore/PageInkDrawing.swift#L104): `var next=self`, затем mutation трёх обычных dictionaries и arrays; Undo удаляет и remaps весь target cut list [111](../Sources/NotebookCore/PageInkDrawing.swift#L111).
3. **Лишняя работа.** При удержанной immutable projection Swift COW отделяет metadata dictionaries и изменённые arrays. Persistent action tree не убирает этот copy/scan. Samples при этом разделяются, повторная сериализация всех measurements не доказана.
4. **Основание.** Source ownership и value mutations подтверждены. Стоимость зависит от targets/cuts; текущий физический stall конкретно этой фазе не приписан.
5. **Исправление.** Prepared source остаётся owner: addressed persistent map target→ordered cuts и action→targets; mutation path-copies только affected paths. Из канонической коллекции адресно получать cuts, удалить eagerly duplicated full values projection. Per-target revision служит presentation delta; lifetime прежних snapshots сохраняется.
6. **Почему/риски.** Admission следует affected targets. Нужно сохранить order/Undo identity и exact prior snapshots. Простое вынесение полной копии на worker оставляет history-sized latency принятия.
7. **Проверка.** Большая предыстория cuts одного body и множество targets: один erase/старый Undo не посещают/копируют прочие targets; затем physical erase→Undo/Redo.

### D16 · P2 · Eraser read set может отменить выбор без изменения его пикселей

1. **Проявление.** Выбран широкий разреженный штрих; другой участник стирает соседний объект в пустой части его bounding box — выбор может получить conflict.
2. **Цепочка.** [NotebookInkReadSet:57](../Sources/NotebookCore/NotebookInkReadSet.swift#L57) строит общий AABB. [readSet:224](../Sources/NotebookCore/NotebookInkReadSet.swift#L224) и [matches:71](../Sources/NotebookCore/NotebookInkReadSet.swift#L71) включают все поздние erasers с пересекающими AABB; [SQL validation:192](../Sources/NotebookCore/NotebookInkReadSet.swift#L192) использует тот же envelope без проверки пересечения painted segments/masks.
3. **Ошибка гранулярности.** Консервативное доказательство dependency шире реально затронутого изображения; оно может вызвать лишнюю отмену/повторную подготовку. Независимый pen append уже сохраняет выбор.
4. **Основание.** Предикат подтверждён; физический false-conflict ещё не воспроизведён. Это отдельный UX candidate с точной проверкой, а не объяснение cold-first или доказанная частая задержка.
5. **Исправление.** Сначала подтвердить sparse-stroke пример. Если нужен более точный контракт, selection source/read-set owner хранит compact painted-support dependency; writer применяет тот же exact intersection predicate после indexed broad phase. Поздний eraser, не влияющий на выбранные пиксели, исключается. Удалить AABB-only equality как окончательное решение; bounds сохранить для candidates.
6. **Почему/риски.** Убираются ложные отмены. Сложность exact geometric proof оправдана только реальным сценарием; несовпадение source/SQL predicate может пропустить истинный конфликт. Более простой альтернативный контракт — сознательно оставить консервативный conflict и явно восстановить выбор после адресной перепроверки.
7. **Проверка.** Sparse L-stroke + соседний erase внутри AABB, затем erase самого stroke, visibility Undo и уже существовавший cut. Первый сохраняет выбор, истинное изменение отклоняет/переготовляет атомарно.

## Последовательный ремонт

Каждый пункт даёт законченный пользовательский результат; проверяется после цельной реализации. Один Xcode runner. Внутренние счётчики отвечают только на спорную работу; UI scenario проверяется на физическом iPad. Существующая веха и задачи [GUI-306](https://linear.app/main-cluster/issue/GUI-306) сохраняются, новая параллельная система планирования не нужна.

| Срез | Законченный результат, границы и удаление | Зависимости и проверка | Задача |
|---|---|---|---|
| S1. Lift → history | Gate выражает released-finalizing; history принимает один Undo и ждёт свой domain receipt. Удалены post-lift silent reject и global history flush/refresh join (D14/D04) | Самостоятельный. Pending force callback, два быстрых inverse, чужая writer preparation | GUI-295 / GUI-226 |
| S2. Delete → durable → picture | Presentation явно живёт после acceptance; canonical handoff завершает cut. Writer больше не ждёт private native/GPU install (D03) | Согласовать receipts S1. Held drawable, независимая запись, CAS reject, cancel после commit | GUI-226 / GUI-316 |
| S3. Независимая бумага и навигация | Paper/interaction/capture различимы; slot owner показывает один pending/error cut. Удалены paper-after-JS и author-ready navigation barrier (D06/D12) | До ускорения curl. Never-ready/error/Retry и shell delay; source-matched ввод | GUI-200 / GUI-298 |
| S4. Принятый document turn | Operation удерживает print/layout pair до исхода, successor reconciles в terminal point. Удалена отмена по общему contentStamp (D13) | После S3. JS/CSS update и настоящая repagination во время forward/reverse/regrab | GUI-298 / GUI-200 |
| S5. Адресный read/publication | Source digest проверяется до body load; metadata/background read не владеет requested read. Удалён decode-before-reuse (D05) | Независимый source slice; согласовать accepted receipts S1/S2. Unrelated edit, same-stamp bytes, delete, delayed refresh | GUI-315 |
| S6. Локальная ink/selection дельта | Selected-ID geometry + persistent erasure directory; accepted paint damage и spatial tile lists/backing. Удалены whole-plan move и nonlocal repaint/discovery (D01/D02/D15) | S2/S5 receipts не должны инвалидировать материал. Dense/100k workload, painter order, erase, Undo, mixed cancel | GUI-295 / GUI-226 |
| S7. Адресный curl material | Per-element source layers, изменяются affected IDs; accepted pair удерживает old complete material. Удалён whole-page layer rebuild после local edit (D11) | После S3/S6. One-object edit→turn, group move/Undo, cancel во время successor upload | GUI-298 |
| S8. Print preparation | Worker строит typed layout, line index и page slots; MainActor принимает результат. Удалены per-page source split и internal receipt roundtrip (D07) | S3 source/installation граница. Long TeX offsets/anchors и cold open→input | GUI-200 |
| S9. Document runtime startup | Один package producer, incremental descriptor publication, borrowed package, общий короткий constructor admission и mutable pending priority. Удалены batch barrier, duplicate package read и admission bypass (D08/D09) | После S3/S8; same-package instances, slow peer, preview promotion, stop/replacement | GUI-200 |
| S10. Viewport raster demand | Current visible output выигрывает очередь; accepted curl предъявляет full-sheet demand. Удалено equal-page-only admission (D10) | S3/S7 задают required display material. Cropped heavy offscreen→visible→full turn→return | GUI-298 |
| S11. Реальный false conflict | Подтверждён D16; затем единый geometric dependency либо определённое восстановление выбора | После S6. Broad-phase сохраняется; false и true erase conflicts проходят один source/writer контракт | GUI-226 |

Адресный material должен сразу иметь владельца, точный ключ, consumer leases и retirement. Ни один срез не вводит отдельное хранилище, второй runtime, глобальный кеш или обход writer. Синхронизация доставляет принятые изменения; её correctness/ACK не привязывается к кадру локального окна.

## Две задержки, для которых диагноз ещё не закончен

**Cold WebKit.** В source-matched program run первый navigation занимает `78,942 → policy 324,037 → started 397,174 → ready 405,953 мс`. До первого policy уже были созданы 14 из 24 WKWebView; сумма их synchronous init — около 75,357 мс. Это наблюдаемая MainActor конкуренция, но она не объясняет весь интервал 245 мс. После структурного ремонта нужен один trace вокруг первого navigation/policy: отделить занятость MainActor, очередь WebKit process startup и delegate delivery. D08/D09 относятся к document runtimes; ими нельзя задним числом объяснить весь Notebook run 1919.

**Первый curl OS frame.** Successor был готов на GPU за 13–14 мс до первого OS receipt и предъявлялся почти сразу после него. Нового tick/encode/GPU этот разрыв не ждёт. Первая `drawable.present()` на MainActor [SheetCurlRenderer:1114](../Applications/Shared/SheetCurlRenderer.swift#L1114) занимала 2,126–9,121 мс после GPU readiness. Текущий код соблюдает [CA transaction presentation contract](https://developer.apple.com/documentation/quartzcore/cametallayer/presentswithtransaction); [нулевой presentedTime](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime) не доказывает физический показ. Нужен CPU/CA/Metal trace именно первого present/flush: registration слоя, swap queue или render-server scheduling. Always-async/прозрачный idle frame пока не являются обоснованным ремонтом: terminal clear требует собственного OS fence, чтобы следующий Pencil не попал под прежний curl.

Эти две проверки различают конкретные гипотезы; остальным установленным полным проходам предварительный большой профиль не нужен. Время события записывается у его владельца. Скриншот/readback/декодирование/отчёт измеряются отдельно и не включаются в latency приложения; их стоимость не вычитается постфактум.

## Что уже работает и что остаётся вне вывода

- Page pen active tail, UUID reorder/target deletion, terminal-before-callback, OS-pose regrab, joined resource fences и pinch navigation claim проверены по текущему коду без новой причинной ошибки. Прежний zoom-back после закрытия исправлен в `NotebookZoomPassage.closed`.
- Mixed presentation использует common installation transaction и addressed restoration witness. Финальное правильное изображение не устанавливает целостность каждого промежуточного compositor frame.
- Исторические full captures, global mesh drains и повторные 46 program starts нельзя переносить на 224 как ещё действующие дефекты.
- Hardware Pencil delivery/prediction, thermal/system memory, длительная совместная работа, radio transport stress, Mac IME/accessibility и все промежуточные OS mixed frames в этом ревью глубоко не проверены. Долговременная приёмка остаётся [GUI-190](https://linear.app/main-cluster/issue/GUI-190).

Критерий завершения ремонта: действие имеет один accepted intent и terminal outcome; зависимость относится к его source/операции; локальная дельта вызывает локальную работу; durable acceptance, установленный материал, физический показ и interactive readiness согласованы и измеряются раздельно.
