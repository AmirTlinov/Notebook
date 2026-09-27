# Причинный аудит Notebook — 27 сентября 2026

## Вывод

Главная проблема — несоответствие масштаба пользовательского действия масштабу
работы и ожиданий, которые оно запускает. Локальный жест ждёт изготовления
снимков; готовая бумага — программ; адресный переход — общего завершения работы;
изменение порядка — пересоздания неизменных страниц. Уже принятый материал не
везде имеет один подготовленный кадр, который могут заимствовать письмо,
смешанное выделение и перелистывание.

Это несколько конкретных причин с общими границами ответственности. Обычная
камера, простой pen-tail, адресный Undo/Redo и ограниченная подготовка сцены уже
существенно исправлены. Возвращать диагноз «всё приложение каждый раз полностью
перерисовывается» неверно. Остались дорогие исключения, чрезмерные условия
готовности и несовпадающие единицы идентичности, отмены и времени жизни.

## База и достоверность

Анализировался чистый `main` на **`0b237f6df17357a964a09e43c66e94901cf77fb8`**;
`origin/main` проверен непосредственно и совпадал. Инвентарь source inputs:
`eda4f8b4b6c0f51c440bf441ed13c5b5d31d3dfb400bb3bb8bda9ed3996bba05`.
Прочитаны AGENTS.md, PHILOSOPHY.md и профильные контракты.
Ссылки на строки кода закреплены за этой ревизией; последующий ремонт описан
[отдельно](causal-repair-2026-09-27.md).

Отдельная ветка `codex/native-page-capture` (`7e0be0b9`) находится в другом
worktree. Её неподлитые изменения не относятся к этому диагнозу. Другие worktree
не изменялись.

На Mac и подключённом физическом iPad обнаружена **0.3.143 (213)**. Mac binary
UUID `E1A8D14E-3AFC-39FD-A1C8-2951C883A45C` совпал с build receipt; iPad bundle
`com.amirtlinov.notebook.preview` имеет тот же номер установленного выпуска.
Исходники выпуска — `cf52f90127122fdd90c6307e857bbf50e47b290ebb17cc2132d7afbb93d03f71`,
они отличаются от анализируемого main. Значит, установленная рабочая пара не
является текущим main. Данные и идентичности не затрагивались.

| Свидетельство | Проверка применимости | Установленный результат |
|---|---|---|
| [document-oracle-194](audit-evidence/2026-09-27/document-oracle-194.json) | Все source inputs совпадают с main | Правильный источник установлен за **1390,771 мс**, предел 1000 мс, FAIL. Снимок 151,611 мс и attachment 111,521 мс сделаны после измерения |
| [merge-curl-ink-192](audit-evidence/2026-09-27/merge-curl-ink-192.json) | Весь код продукта совпадает; отличается только тест холодного документа | Все 10 первых изгибов **70,840–109,891 мс** при пределе 16,67 мс; есть непоказанные progress receipts и нарушение cadence. 9 выбранных проверок PASS, 1 FAIL |
| Тот же 192, перо | То же соответствие | Последний видимый Redo 56,324 мс; среди 100000 действий Undo/Redo 20,888/23,025 мс без полной подготовки истории/mesh |
| [selection-native-185-191](audit-evidence/2026-09-27/selection-native-185-191.json) | Presentation/SelectedGraphicHost и другие файлы после этого менялись | Исторический сигнал для выбора сценария. Числа задержки и визуальный дефект не объявляются текущим измерением |
| [physical-cold-phases-159](audit-evidence/2026-09-27/physical-cold-phases-159.json) | Более старые исходники | В том опыте доминировала native print preparation; это направление следующего замера, а не точная атрибуция 194 |

192 и 194 — существующие проверки на USB iPad в private optimized scope, а не
новый запуск этой задачи и не полная приёмка установленной пары. Их frozen
manifests сверены по файлам. В receipts поле `sourceSHA256` обозначает hash файла
manifest; hash инвентаря внутри него другой. [Сводка сравнения](audit-evidence/2026-09-27/causal-audit-baseline.json).

В этом аудите код продукта не изменялся, новые сборки, установки, Simulator и
прогоны тестов не выполнялись. Сначала проверены исполняемые цепочки и
применимость уже имеющихся отрицательных результатов. Где источник доказывает
лишнюю работу, но не её длительность, это обозначено отдельно.

## Владельцы и живые пути

| Поведение | Путь от действия до видимого результата |
|---|---|
| Открытие/камера | `SpatialWorkspaceView` принимает намерение → `NotebookAppModel` принимает presence → scene preparation/composition → `SceneNativeCameraProjection`, native planes и cover → показ |
| Страница/перелистывание | `NotebookPagePreparation` + `NotebookSceneReader` → `PageSurface` и paint receipts → `IPadPageTurnController` разрешает переход → `IPadSheetCurlController` держит контакт/пару → `SheetCurlMetalView` → landing → выбранная страница |
| Перо/ластик | `PencilCanvasView` / `SpatialInkCanvas` → `NotebookDrawingToolController` и input gate → `InkCanvasView` с принятым материалом и active tail → accepted write через AppModel → один persistence FIFO |
| Смешанный выбор | lasso/read-set → `NotebookSelectionSession` → `NotebookSelectionPresentation` + native selected graphics + ink plane → атомарная команда и история → общий показ |
| Документ | адресный источник → `DocumentRenderSession` / `DocumentPagePreparation` → один canonical typesetter → PDF/геометрия → `DocumentPagePresentationOwner` → paper и программные slots |
| Живая программа | `DocumentProgramOwner` → один WebKit runtime на экземпляр → state/checkpoint → durable write → passive/live representation. Код документа и program state имеют разные жизненные циклы |
| Сохранение/агент | AppModel принимает команду → `NotebookPersistenceQueue` → `NotebookStore` transaction → addressed publication → Core delivery/cloud. `NotebookSceneReader` читает отдельно через WAL |

Три субагента параллельно исследовали страницы/камеру, ввод/выбор и документы;
вторая волна отдельно проверила persistence/sync. Lead сверил существенные
цепочки, source witnesses и соседние условия. Ниже выводы объединены по причинам,
а не по каталогам или числу найденных проблем.

## Приоритетные находки

### F01 · P1 · Первый изгиб ждёт изготовления двух изображений

1. **Проявление.** Даже тёплое перелистывание начинает изгиб с задержкой; неизменный обратный переход платит повторно.
2. **Цепочка.** [IPadSheetCurlController.begin/captureCurrentSource/capturePair](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/iPad/IPadSheetCurlController.swift#L124) → два `drawHierarchy(afterScreenUpdates: true)` на main, строки 233–252 → [SheetCurlMetalView.preparePages](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/SheetCurlRenderer.swift#L229) → две private Metal texture и CI upload → первый render. `finish` освобождает пару.
3. **Лишняя работа.** Layout/flush UIKit, два CPU image, allocation/upload стоят между принятым жестом и видимым изгибом. Main queue hop не удаляет эту зависимость. Изменение readiness при flush выбрасывает уже выполненный capture. Cover имеет родственный timer/capture путь: [CoverOpeningSurface](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/CoverOpeningSurface.swift#L509).
4. **Основание.** Путь установлен по исходникам; 192 доказывает текущий FAIL первого изгиба. Доля именно capture во всех 70–110 мс на этой версии не измерена; остальные ожидания GPU/OS cadence остаются отдельным вопросом.
5. **Решение.** Существующий владелец физической страницы публикует неизменяемый подготовленный кадр после установки его материалов. Ink отдаёт lease неизменной версии accepted GPU backing; последующий append не меняет texture удерживаемого кадра, а получает successor; paper/graphics используют подготовленные материалы; WebKit — принятый локальный snapshot/status своего slot, без доступа к внутренним GPU-ресурсам WebKit. Один compositor страницы собирает эти вклады. Ключ: page UUID, ink/material/program pixel revisions, crop/density и installation generation. Curl заимствует и удерживает две готовые версии; новый материал готовит successor. Динамический WebKit может менять пиксели без state commit: program owner обязан согласовать frozen/live cut и snapshot, поэтому точный локальный захват slot иногда всё ещё требует ожидания. Удалить pair hierarchy capture/readback/reupload и capture retries после переключения владельца; cover получает readiness событие вместо polling.
6. **Почему/риски.** Из критического пути исчезает изготовление источника анимации. Не строить второй renderer содержимого: compositor только соединяет уже принятые вклады. Сейчас общего экспортируемого GPU-кадра нет, его lease API — часть ремонта. Удерживать только конечное окно страниц, учитывать bytes в `SceneRenderResources`, освобождать после последнего CPU lease и последнего GPU use. Нельзя показывать старую версию как свежую; переход на следующий live cut только в согласованной границе. Предварительный `drawHierarchy` может быть временным экспериментом, но не конечным вторым путём: после свежего штриха он возвращает ту же задержку.
7. **Проверка.** Физический forward/reverse, штрих→свайп, cancel, быстрые повторы, agent/program update в движении. На admission нет двух полностраничных hierarchy capture/reupload; точность начала и landing сохранена. Отдельный случай — анимация программы без state commits и её exact local capture. Повторить существующие first-bend и OS cadence thresholds. Отдельно профилировать оставшийся разрыв, не обещать 120 Hz только по удалению capture.

### F02 · P1 · Холодные чернила декодируются из SwiftUI до фоновой подготовки

1. **Проявление.** Первый показ содержательной страницы и готовность к первому штриху могут остановить UI; возврат после вытеснения повторяет холодную работу.
2. **Цепочка.** [PageSurface.body:69–70](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/PageSurface.swift#L69) → [pageOrderedInk](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookPageOrderedInk.swift#L68) → elementErasures → [NotebookElementErasing](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookElementErasing.swift#L482) → erasure cache miss → `page.inkDrawing()` → синхронный decode под lock и обход drawing actions. Detached decode в [PencilCanvasView](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/iPad/PencilCanvasView.swift#L402) наступает позже. Upstream page preparation сохраняет encoded source и не прогревает эту проекцию.
3. **Лишняя работа.** Ленивый cache miss полного архива чернил выполняется на UI actor ради eraser/ordered metadata ещё до монтирования canvas. Наличие фоновой подготовки canvas не защищает этот более ранний путь.
4. **Основание.** Цепочку независимо сверили ink, page и lead. Длительность на текущем физическом dense page не измерена; это установленная блокирующая работа, не присвоенное ей число из старого теста.
5. **Решение.** `NotebookPagePreparation` подготавливает одну immutable ink projection и eraser directory на read worker до публикации готового page material. Ключ — ink source identity; admitted lifetime — finite page window. Accepted append/undo обновляет адресную проекцию у существующего ink publication owner. `PageSurface` только заимствует её; удалить синхронный decode/cache-miss путь из body. До domain admission должен существовать готовый immutable root; иначе существующий input owner сохраняет измеренный контакт до готовности базы. Нельзя перенести lazy decode в первый lift: `acceptInkMutation` → `prepareInkChange` также должен заимствовать подготовленный root.
6. **Почему/риски.** Decode выполняется один раз вне UI, а не раньше «фонового» decode. Это перенос работы, не обещание нулевого общего времени cold load. Не держать одновременно несколько decoded архивов и копий индекса; учитывать память и отменять подготовку удалённого спроса.
7. **Проверка.** Холодное открытие страницы с большой историей и немедленный Pencil; main-thread decode count = 0, один подготовленный source. Затем erase/undo, выход за окно/возврат и отменённая подготовка. Dense workload нужен, поскольку меняется индекс/подготовка истории.

### F03 · P1 · После преобразования чернил письмо теряет дешёвый retained путь

1. **Проявление.** Обычная страница пишет быстро, но после перемещения исходных raw-чернил последующие штрихи и стирание могут стать существенно тяжелее.
2. **Цепочка.** Source-anchored преобразованные тела включают `orderedGeometry`. [InkCanvasView:1264–1266](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/InkCanvasView.swift#L1264) исключает такую страницу из retained-page fast path. Каждый active frame идёт в [encodeOrderedFrame:1695](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/InkCanvasView.swift#L1695): все видимые raw chunks/bodies → новые ordered attachments → [encodeOrdered](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/InkOrderedComposition.swift#L144).
3. **Лишняя работа.** Повторяются сбор полного видимого paint event list и GPU-композиция принятого материала; body делает fold/clear всей render target. Mesh не декодируется заново — это другой уровень стоимости, который прежний «no full mesh rebuild» тест не покрывает.
4. **Основание.** Условие и цикл действуют в текущем input route. Точная деградация после move требует одного сравнительного physical trace одинакового рисунка до/после; нельзя распространить хороший raw Redo192 на ordered plane.
5. **Решение.** Расширить retained accepted composition внутри того же `InkCanvasView` на ordered plan. Версия включает accepted raw/body revisions, порядок, suppression/cuts, crop/camera/LOD. Перо рисует только active tail поверх принятой композиции; принятие контакта обновляет затронутую область. Ластик обновляет затронутые ordered bodies/masks, сохраняя paint order. Нынешние scratch attachments memoryless: это повторные pass objects/encode, не доказанный рост постоянной GPU памяти. Дать им bounded frame-slot/pass lease по размеру/формату/MSAA; reuse и retirement допускаются после GPU use. Само удержание attachments не устраняет ordered replay. Удалить полный ordered replay из неизменного pen-frame пути.
6. **Почему/риски.** Из pen-frame исчезает повторная композиция неизменных ordered bodies; оставшийся `prepareCommittedBuffers` ещё может обходить visible metadata и оценивается отдельно. Нельзя flatten все слои так, чтобы позднее стирание нарушало авторский порядок; при сложном eraser нужна адресная recomposition затронутого cut, не ложный fast path. Этот backing затем может предоставлять кадр F01.
7. **Проверка.** Один рисунок: письмо → mixed move → непрерывное письмо → erase → undo/redo. Счётчик recomposition принятого фона не растёт на каждом pen sample. Проверить пересечения, поздний ластик и плотную историю; физически сравнить GPU/frame gaps до/после.

### F04 · P1 · Порядок страниц ошибочно управляет временем жизни страниц

1. **Проявление.** Создание последнего листа или внешняя перестановка вызывает лишнюю подготовку существующих листов; быстрый уже принятый reverse/jump может быть сброшен.
2. **Цепочка.** [SpatialWorkspaceView:1844](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/iPad/SpatialWorkspaceView.swift#L1844) передаёт whole page-order root как `sequenceRevision`. [selectNotebookPage:1788](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookAppModel.swift#L1788) сохраняет подготовленные адреса при append, но [IPadPageTurnController:342,376–405](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/iPad/IPadPageTurnController.swift#L342) считает это owner change, очищает intent и вызывает `replaceOwnerPages` → уничтожение hosts в строках 520–542.
3. **Ошибка.** Меняется каталог, а пересоздаются неизменные UUID-страницы, их ink/graphics trees и readiness. `requestedIndex` обнуляется до принятия нового порядка.
4. **Основание.** Reset доказан исходниками; потерю конкретного быстрого жеста нужно воспроизвести с реальным root. [Тест queued trailing creation](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Tests/PageTurnSelectionTests.swift#L767) использует постоянный `fixture-order` и не проверяет этот переход.
5. **Решение.** Разделить notebook identity, page UUID/material и order witness. Resident hosts ключевать UUID; новый order только переназначает slots конечного окна. Provisional trailing page получает стабильную creation identity. Принятый переход хранит target UUID либо step+origin witness и переадресуется по новому порядку. Удалить blanket notebook replacement при любом root change; retire только удалённые/вытесненные страницы.
6. **Почему/риски.** Append перестаёт сбрасывать GPU/UI lifetime и намерение. Старые callbacks всё ещё проверяют order witness. При удалении source/target во время curl удержать принятую картинку до безопасной границы и выбрать surviving UUID; нельзя просто игнорировать reorder.
7. **Проверка.** Реальный AppModel append → немедленный reverse/первый штрих; неизменные hosts тождественны, создание ровно одно. Затем reorder/delete от агента в удерживаемом и отпущенном жесте; окно остаётся ограниченным.

### F05 · P2 · Открытие обложки публикует содержимое на каждом sample

1. **Проявление.** Open/close и pinch через обложку тяжелее обычного pan/zoom, особенно рядом с насыщенными предметами.
2. **Цепочка.** `openProgress` → [NotebookAppModel.applyPresence:2385](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookAppModel.swift#L2385) с `publishes: true` → [mountedScene/ItemPlaneRevision](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/iPad/SpatialWorkspaceView.swift#L237), строки 841–850 → [SceneCameraPlane.update:351](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/SceneCameraPlane.swift#L351), замена root/layout → refresh resident page roots. Cover также повторно назначает root.
3. **Лишняя работа.** На частоте camera samples создаётся запрос ограниченной сцены, выполняются SwiftUI diff/layout и конфигурация неизменных страниц. Это bounded scene, не весь архив; compatible raster jobs уже coalesce.
4. **Основание.** Непрерывная invalidation установлена; её долю в физических frame gaps ещё нужно измерить счётчиками root/layout. Обычная камера в подготовленном окне уже использует native projection.
5. **Решение.** Провести cover progress/shadow через существующий `SceneNativeCameraProjection`. SwiftUI публикует смену semantic mode/focus, дискретный interaction threshold и материал; убрать непрерывный progress из content revision. Один native owner принимает start/end/cancel и проецирует pose. Cover material revision вычисляется при публикации материала, а не повторным сканированием resident ink из body.
6. **Почему/риски.** Камера и обложка движутся одной native транзакцией без layout неизменного содержимого. Hit testing/accessibility меняются на нужной смысловой границе; старый SwiftUI config не должен перезаписать новый native pose.
7. **Проверка.** Cold/warm open, close/reopen, reverse pinch: content publication count соответствует изменению содержимого/порогов, pose — каждому sample. Физически проверить кадры, отсутствие flash и расхождения hit targets.

### F06 · P2 · Новый pinch теряется во время workspace settlement

1. **Проявление.** Быстрое исправляющее движение во время открытия/закрытия может ничего не сделать; приходится повторять жест.
2. **Цепочка.** [handleBoardMagnification:1167–1174](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/iPad/SpatialWorkspaceView.swift#L1167) возвращается на `.began`, если `pending.started`. Snapshot контакта не создаётся; changed/ended затем возвращаются из-за nil. Pan также выключен во время settling.
3. **Ошибка.** Анимация длительностью порядка 0,24–0,42 с становится интервалом исключения ввода. Ограничение защищает от half-open состояния вместо передачи этого состояния новому контакту.
4. **Основание.** Drop прямой по коду. Это workspace/cover, не page curl: повторный захват curl уже поддерживается. Новый device repro нужен для принятия UX-исправления.
5. **Решение.** На новом контакте остановить settlement clock и передать текущие native camera/openProgress, source/target passage и readiness lease в `CameraGestureSnapshot`. Продолжить/развернуть из этой позы; сохранить return bookmark только при landed intent. Удалить blanket rejection после определения partial-passage transfer.
6. **Почему/риски.** Контакт получает текущий физический объект. Нельзя сначала вызвать нормализацию settledPresence и потерять частичный cover/междосочный transform; один владелец должен завершать и старое, и новое движение.
7. **Проверка.** Новый pinch в начале/середине/конце open/close/portal, cancel и release в обе стороны: нет потерянного контакта, скачка, застрявшей обложки и лишнего bookmark.

### F07 · P1 · Доступ к готовому листу зависит от всех его программ

1. **Проявление.** Соседняя страница с исправным PDF не перелистывается из-за зависшего `ready`, checkpoint или ошибки программы. Дальний переход может работать, что делает поведение непредсказуемым.
2. **Цепочка.** [IPadPageTurnController:868–871](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/iPad/IPadPageTurnController.swift#L868): соседние переходы требуют `.snapshot`, дальний jump — `.live`. [DocumentPagePresentationOwner:815–820](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/DocumentPagePresentationOwner.swift#L815) и 1142 запрещают snapshot до `programsReady`; page turn ждёт readiness. Live путь 844–862 уже допускает paper с адресными pending slots.
3. **Блокировка.** Composite readiness объединяет печать и произвольное исполнение программ. Неработающий блок лишает пользователя навигации по остальному документу.
4. **Основание.** Условие подтверждено двумя субагентами и lead; [DocumentProgramOwnerTests:1731](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Tests/DocumentProgramOwnerTests.swift#L1731) прямо закрепляет неготовность соседнего листа при готовом paper.
5. **Решение.** `DocumentPagePresentationOwner` публикует готовность бумаги и отдельный статус каждого slot. Curl frame содержит paper плюс точный ready/pending/error образ slot; готовность взаимодействия проверяет сам program owner. Полный program checkpoint нужен для операции, реально требующей его состояния, а не для доступа к бумаге. Удалить all-program barrier из обычной навигации и сменить соответствующий тестовый контракт.
6. **Почему/риски.** Сбой одного исполнителя локализуется в его прямоугольнике. Сохранить один runtime и checkpoint→durable write перед настоящим release. Старые пиксели иной revision нельзя подписывать как новую программу; pending/error кадр имеет собственную точную identity.
7. **Проверка.** Никогда не готовая/ошибочная программа на соседнем листе: forward/back/cancel работают, текст доступен, slot явно pending/error. Возобновление программы не сдвигает бумагу, не теряет state и не запускает второй runtime.

### F08 · P1 · Причинная версия документа используется как идентичность печати

1. **Проявление.** Правка программы, не влияющей на TeX, повторно готовит бумагу и может отменить перелистывание; восстановление тех же байтов другой причинной версией также промахивается мимо reuse.
2. **Цепочка.** `DocumentRenderSession.source` сравнивает полный Document; [paperToken](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/DocumentWebView.swift#L92) основан на contentStamp; [print cacheKey](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Sources/NotebookTypesetter/NotebookPrintedDocumentStore.swift#L63) сериализует весь Document с clocks. Source change → [DocumentWebView:1377](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/DocumentWebView.swift#L1377) reset → page controller readiness/motion reset.
3. **Лишняя работа/ошибка.** Одна identity обслуживает разные зависимости: причинное редактирование, TeX input, program executable и физический held frame. Поэтому независимое изменение запускает compile и сбрасывает жест.
4. **Основание.** Полный key/reset установлен. Обычное изменение program state на iPad уже отделено от исходника и не обязано компилировать TeX; этот исправленный случай не включён в дефект.
5. **Решение.** В canonical print owner разделить immutable artifact identity (точные зависимости + compiler/recipe), binding к causal revision и executable basis программ. Сначала reuse одинаковых входных байтов между causal revisions; затем recorder фактических TeX reads и negative existence probes с корректной проверкой namespace. `DocumentPagePresentationOwner` совместно с page-turn owner удерживает admitted revision через source/frame lease до безопасного handoff; render session готовит immutable successor независимо от жеста. Удалить full-document stamp как безусловный pixel invalidator.
6. **Почему/риски.** Меняется только реально зависимый результат. Нельзя просто исключить `.js`/`.css`: TeX может читать любой файл, а появление ранее отсутствующего файла менять результат. Пагинация остаётся глобальной, если изменены её реальные входы; source-map receipts должны ссылаться на новую causal basis при reuse PDF.
7. **Проверка.** Во время чтения/curl изменить независимый JS: нет TeX invocation и сброса paper; runtime обновляется по своему контракту. Изменить фактически прочитанный файл, добавить проверявшийся отсутствующий файл, сменить compiler recipe: обязательная корректная перевёрстка. A→B→те же байты A сохраняет точный mapping.

### F09 · P1 · Устаревшая подготовка удерживает последнюю версию

1. **Проявление.** Быстрые изменения исходника или переход на новый документ ждут завершения уже ненужной компиляции; scene SVG/export могут конкурировать с текущим листом.
2. **Цепочка.** [DocumentWebView.prepareAndSendFrame:1786](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/DocumentWebView.swift#L1786) имеет один frameTask. Он ждёт старый `preparedPage` в 1813 и проверяет generation только в 1823. Отмена snapshot preparation не отменяет этого reader; [DocumentPagePreparation:160–174](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/DocumentPagePreparation.swift#L160) сохраняет job при reader. [NotebookTypesetter:106–133](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Sources/NotebookTypesetter/NotebookTypesetter.swift#L106) ставит compile/SVG в одну FIFO; deadline Work начинается до admission.
3. **Блокировка.** Отменена публикация старой версии, но не спрос на её вычисление. Новая версия стоит за ней; queued background operation расходует также execution budget текущего задания.
4. **Основание.** Ownership/cancellation цепочка установлена. Нужен контролируемый slow-source A→B trace для длительности, а не приписывание всего cold194 этой гонке.
5. **Решение.** Разделить отменяемую подписку source preparation и уже отправленный физический WebKit tail. При смене demand снять старый reader; последнему reader отменять native job. В том же единственном compiler owner ввести bounded demand scheduler: current input выше speculative/export, obsolete queued jobs удаляются; активная работа отменяется только без владельцев. Queue wait и execution deadline считать отдельно. Удалить ожидание старого source из single sender loop.
6. **Почему/риски.** Latest demand перестаёт ждать работу без потребителей. Не отменять accepted writes, не дублировать VM, не отпускать физический WebKit/GPU tail до его completion. Общий job другого текущего читателя остаётся живым; scheduler должен исключать голодание экспорта.
7. **Проверка.** Медленная A → быстрая B, затем cancel/reopen; B не ждёт ненужного A, A не публикуется поздно. Два читателя A сохраняют один job. Background SVG/export не блокируют queued current page; память/число VM остаются ограниченными.

### F10 · P2 · Первый лист ждёт подготовки невидимых частей документа

1. **Проявление.** Большой многофайловый документ или документ с программами далеко ниже открывается дороже, даже при попадании в print cache.
2. **Цепочка.** [DocumentPagePreparation.loadPrint:179–230](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/DocumentPagePreparation.swift#L179): все input bytes до cache lookup → artifact → SQL materialization всех program packages → повторный SyncTeX decode → navigation/text/links всех PDF pages → layout. [PrintedDocumentStore.load:81–106](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Sources/NotebookTypesetter/NotebookPrintedDocumentStore.swift#L81) уже декодирует SyncTeX и читает/проверяет assets. Page envelope также несёт все программы/initialState, хотя iPad имеет внешнего program owner.
3. **Лишняя работа.** Первый paper зависит от внеэкранных пакетов, полной навигации и повторного projection; cache hit не избавляет от первоначальной загрузки всех исходников.
4. **Основание.** Последовательность source-proven. Вклад в маленький fixture194 не установлен. Старый phase159 указывает прежде всего на native typesetting, поэтому нельзя обещать закрыть 1390 мс только этими изменениями.
5. **Решение.** Artifact store принимает lazy input factory и вызывает её при miss; валидированный immutable artifact удерживает один decoded projection. `DocumentProgramOwner` получает package по admitted live/neighbor demand вне paper readiness. Навигационные/accessibility данные готовить по спросу страниц; передавать page-local descriptors, убрать лишний initialState в external-program envelope. Целый экспорт по-прежнему запрашивает весь нужный набор явно.
6. **Почему/риски.** Из first-paper path исчезает работа, не нужная для этого результата. Не убирать проверку целостности cache и не отрезать доступность: текст/links должны быть готовы к своему первому использованию. Глобальные TeX/pagination passes могут оставаться необходимыми.
7. **Проверка.** Открыть первую страницу cache-hit документа с множеством дальних программ/файлов: нет staging дальних пакетов, один SyncTeX decode, правильный paper. Затем сразу перейти далеко, воспользоваться ссылкой/VoiceOver и экспортировать: все производные данные корректны.

Дополнительный кандидат внутри cold print: [NotebookTypesetter:123–126](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Sources/NotebookTypesetter/NotebookTypesetter.swift#L123)
через 15 секунд уничтожает reusable runtime, включая immutable archive index,
format/fonts. Guest arena уже освобождается после отдельного native job.
Следует сравнить cache-miss cold/warm/после idle, затем удерживать ограниченные
immutable ресурсы до реального memory pressure у того же owner и удалить
безусловный timer. Размер выигрыша пока не установлен; это не основание менять
число обязательных TeX passes или считать cold-opening цель достигнутой.

### F11 · P1 · Каждая поза смешанного выбора проходит последовательный полный цикл

1. **Проявление.** Первая и последующие позы raw+authored selection отстают от пальца; быстрый reverse/cancel проходит другим путём и требует проверки целого кадра.
2. **Цепочка.** [NotebookSelectionPresentation.prepareIfPossible:156–264](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookSelectionPresentation.swift#L156) строит ordered candidate → [InkCanvasView.prepareFrame:1953](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/InkCanvasView.swift#L1953) ждёт предыдущие GPU и presentation completion → следующий display-link drawable, строки 2028–2037 → полная композиция → GPU completion, 2077–2085 → CA installation. Следующая поза снова ждёт drainage. Cancel использует `SourceRestoration.restore` и обычный renderFrame; тот также запрещает следующий spatial/material frame при незавершённых GPU/CA submissions (1225–1226), а `spatialStagingID` рассчитан на одного кандидата.
3. **Блокировка.** Latest pose coalesces, но его подготовка сериализована за завершением предыдущего физического цикла. Это не доказательство повторной tessellation каждого штриха: геометрия частично переиспользуется.
4. **Основание.** Очередность подтверждена lead по текущему коду. 191 не измеряет текущую Presentation; нынешняя атомарность cancel и доля GPU/CA ожиданий остаются точными вопросами следующего physical trace.
5. **Решение.** `NotebookSelectionPresentation` сохраняет semantic source/read-set/pose на lifetime выбора и заимствует resident geometry у renderer, передаёт latest pose единому frame-clock owner существующего canvas. Тот допускает ограниченное число immutable кадров в обработке, coalesces неотправленные позы и устанавливает raw/authored/controls на одном scheduled cut. Move, cancel и canonical handoff используют один owner. Заменить оба global drain gates и единственный staged candidate ограниченным frame-slot lifecycle; удалить per-move `prepareFrame(.ordered)` orchestration. Подготовить clips при готовности выбора, без второй geometry cache. Начальный законченный срез может сохранить полную композицию, но убрать межкадровую CPU/GPU/CA сериализацию; R1/F03 предварительно уменьшает стоимость accepted composition; pipelining проверяется отдельно.
6. **Почему/риски.** Подготовка следующего кадра не требует предыдущего CA completion. Просто удалить await нельзя: controls не должны убегать от ink. Ограничить in-flight память, сохранять painter order и source generation, явно завершать failed/abandoned cuts; восстановление при resource rejection не должно частично изменить raw state.
7. **Проверка.** Физически raw+authored drag/reverse/cancel до и после первого install, move→commit→undo/redo, второй палец, agent replacement и отказ ресурса. Записать touch/drawable/scheduled/completed/presented вместе с изображениями; GPU completion не заменяет показ целой позы.

### F12 · P2 · Подсветка одного агентского штриха повторно разбирает весь ink

1. **Проявление.** После добавления агентом штриха на насыщенный лист краткая подсветка может мешать письму/камере.
2. **Цепочка.** `CollaborationResults` и `NotebookAgentFeedbackChange` передают stroke ID/region → [NotebookAgentFeedbackOverlay.body](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookAgentFeedbackOverlay.swift#L9) → `NotebookAttentionProjection.agentFeedback` → [@MainActor NotebookAgentFeedbackInk.path:32–51](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookAgentFeedbackInk.swift#L32).
3. **Лишняя работа.** `PageInkDrawing.decode(page.drawingData)` обходит retained source и повторно декодирует весь архив; новый root может сначала сериализоваться. Затем обход active actions, tessellation всех более поздних erasers и CPU path subtraction, даже когда они не пересекают нужный штрих. Spatial вариант сканирует resident journal.
4. **Основание.** Живой путь подтверждён. Material вычисляется снаружи TimelineView: это body invalidation, а не утверждение о 30 повторениях в секунду. Время конкретного эпизода не измерено.
5. **Решение.** Feedback owner удерживает mask эпизода, подготовленную вне main из canonical indexed ink и тех же geometry/cut owners. Read-set: выбранное действие/visibility, suppression и пересекающие поздние cuts. Camera только проецирует готовый материал; обновлять при изменении read-set, отпускать в конце эпизода. Удалить archive roundtrip и полный CPU path helper из live overlay.
6. **Почему/риски.** Подсветка одного действия не разбирает всё письмо. Она должна совпадать с реально оставшимися пикселями, включая authored source anchors; второй упрощённый renderer штриха даст неправильный highlight.
7. **Проверка.** Agent append на dense page с поздними erasures одновременно с письмом/панорамированием: нет encode/decode/boolean path loop на main, mask совпадает с видимым материалом и освобождается.

### F13 · P2 · Несвязанная правка аннулирует выбор и результат lasso

1. **Проявление.** Lasso, завершённое одновременно с агентским append в другом месте, молча не принимается; уже выбранный raw stroke перестаёт допускать move. На доске зависимость может охватывать другой surface.
2. **Цепочка.** [NotebookSelectionClipboard:70](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookSelectionClipboard.swift#L70) даёт whole page/journal revision → [finishElementSelection:580–583](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookDrawingToolController.swift#L580) молча возвращается при отличии. Contact gate уже снят после запуска async finish ([NotebookToolInputContact:80–87](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/iPad/NotebookToolInputContact.swift#L80)). [selectedGraphicMembers/selectionEditSourceIsCurrent](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookAppModel.swift#L3259), строки 3264,3324, используют ту же широкую проверку.
3. **Ошибка.** Зависимость выбора шире использованного материала/контура. Guard сохраняет корректность консервативно, но отбрасывает пользовательское намерение после независимой правки.
4. **Основание.** Ветки установлены по коду. Конкретный внешний вид controls и частоту гонки надо проверить на устройстве; публикация во время удерживаемого контакта здесь не утверждается.
5. **Решение.** Core владеет immutable read-set выбранных action IDs/body/visibility, поздних релевантных cuts, authored ancestors/placement. Для lasso дополнительно валидировать множество кандидатов контура либо явно принять семантику captured snapshot. Writer проверяет тот же read-set атомарно при conversion. Независимый append сохраняет выбор; изменение выбранного материала вызывает явный reject/recompute под той же selection identity с завершением callback. Удалить whole-journal guard после введения полной адресной проверки.
6. **Почему/риски.** Совместная работа не требует тишины всей страницы. Просто убрать revision guard нельзя: стёртые/заменённые пиксели могут вернуться. Нужна одна выбранная семантика snapshot/recompute, без повторного проигрывания контакта.
7. **Проверка.** Lasso + outside-contour append на листе/другой обложке → move сохраняется; новый intersecting ink, erasure выбранного и изменение ancestor → корректный атомарный reject/recompute; accepted local predecessor учитывается.

### F14 · P1 · Адресный результат ждёт тишины всего AppModel

1. **Проявление.** Холодное открытие страницы/документа, ссылка или расширение видимой сцены повторяет подготовку, пока агент меняет другой объект/метаданные.
2. **Цепочка.** [prepareNotebookPage:142–159](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookAppModel.swift#L142): writer fence → WAL read → адресный `isCurrent` → дополнительный global `collaborationReadEpoch`. Epoch меняют целые dictionaries workspace/pages/documents/state и collaboration metadata. Document opening, scene installation и reference resolution используют похожую общую проверку.
3. **Лишняя работа.** Уже корректный адресный результат отбрасывается по независимому событию. Page body переиспользуется, но queue cuts, membership/history/projection повторяются; документ повторно читается/декодируется. [Page address test](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Tests/NotebookPageAddressTests.swift#L226) доказывает body reuse, но допускает retry.
4. **Основание.** Цепочку независимо проверили page, persistence и lead. Возможность retry установлена; длительность/starvation под непрерывными независимыми изменениями требует gated-read проверки.
5. **Решение.** Existing preparation owner несёт read-set: workspace identity, target UUID, membership/order/lifecycle witness, source/state stamps, native-history frontier и per-target generation принятых локальных изменений. Проверять его при коротком writer boundary и установке; request ID/cancellation хранить отдельно. Для scene — фактические coverage/pins и generations владельцев. Удалить global epoch/cursor как условие адресной публикации, сохранив при необходимости диагностический счётчик.
6. **Почему/риски.** Чужие изменения не запрещают прогресс. Нельзя ограничиться SQL stamps: pending accepted local edit ещё может быть в FIFO. Удаление, reparent, order change и новый локальный source должны по-прежнему отвергать старый результат.
7. **Проверка.** Задержать read, много раз изменить другой объект/context, отпустить: первый актуальный результат устанавливается без retry. Затем изменить target/source/order/draft или удалить его — результат отвергается. Физически cold open + agent edits elsewhere, затем targeted edit.

### F15 · P1 · Переход по ссылке ждёт постороннюю работу и программы

1. **Проявление.** Reference/page jump задерживается при подготовке сообщения, сервисном startup или checkpoint удерживаемой посторонней программы. Ошибка её hook может сорвать правильный переход.
2. **Цепочка.** [finishNavigationInput:5507–5531](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookAppModel.swift#L5507) → `finishPendingInteraction(.acceptedInput)` → [finishPendingPersistence:6236–6271](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookAppModel.swift#L6236), joins startup/chat/context/collaboration → `checkpointPrograms(resume: true)` без document scope. [DocumentRenderRegistry](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/DocumentRenderRegistry.swift#L112) выбирает всех retained owners данного resources; `DocumentProgramOwner.checkpointAll` и затем последовательный `resumeAll`.
3. **Блокировка.** Навигация ждёт frozen chat context images и посторонних программ, включая blur/checkpoint/resume hooks. Обычный Send/Create ждёт локальный durable outbox, **не сеть**; interactive steer может ждать peer reply с retries ([NotebookChatController:781](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookChatController.swift#L781)). `loadState.ready` наступает раньше окончания startup services, но navigation joins весь startupTask.
4. **Основание.** Проверен именно explicit reference/location route, не каждый соседний finger curl. Hooks определяют фактическое время. Checkpoint программ внутри owner конкурентный; resume последовательный — эти стадии нельзя смешивать в объяснении.
5. **Решение.** Navigation scope задаёт уходящего physical input/source owner, destination и captured receipts уже принятых локальных команд. Завершить его contact/editor transaction и нужный write cut; checkpoint только программы, действительно передающей focus/ownership. Разделить реализацию accepted-input и whole-app quiescence: chat preparation/remote receipt, независимые metadata и поздний service startup не входят в первую. Глобальный join оставить background/shutdown; resource retirement сам завершает свой program checkpoint. Удалить global program boundary из локального перехода.
6. **Почему/риски.** Ожидание соответствует переносимому состоянию. Accepted messages/writes не отменяются; scoped cut не обгоняет уже принятых FIFO predecessors, устраняются joins к чужой будущей работе. Контекст Send остаётся frozen. Уходящий WebKit editor/IME и selected-frame tail должны быть включены в scope. Сокращение timeout или parallel resume без удаления чужих зависимостей не устраняет причину.
7. **Проверка.** Задержать checkpoint посторонней программы, Send image preparation и отдельно steer reply: локальная ссылка работает. Уход с действительно изменённой focused программы сохраняет её state ровно один раз. Background/quit всё ещё дожидается всех нужных writes/checkpoints.

### F16 · P2 · Контакт на другом устройстве блокирует независимые изображения

1. **Проявление.** Пока peer пишет на другой доске, локальные вновь открытые элементы могут оставаться неподготовленными. Уже имеющиеся ink/rasters продолжают работать.
2. **Цепочка.** `NotebookInputActivity.targets` адресны, но [receivePeerTransient:4875–4885](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookAppModel.swift#L4875) сворачивает их в `peerInputIsActive`. Global permits page/scene preparation, строки 1121–1134, запрещает raster demand в [PreparedAgentElementView:203,425](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/PreparedAgentElementView.swift#L203), composition и changed-index publication.
3. **Ошибка.** На admission теряется информация о пересечении владельцев. **SQL body read страницы не блокируется этим Boolean**: у `prepareNotebookPage` есть другая private address/window проверка. Задерживается подготовка/установка изображения.
4. **Основание.** Условие и callers проверены. Нужен paired-device сценарий для частоты/видимой тяжести. Защита материала самого удалённого контакта необходима.
5. **Решение.** Сохранять session/sequence lifetime peer activity; запрашивать overlap по targets, ancestry и source identities через существующую Core conflict semantics. Immutable preparation независимых материалов разрешена; установка ждёт только пересекающегося активного контакта и повторно валидирует source. Удалить global Boolean из demanded raster/scene admission; для необязательного prewarm он может оставаться policy.
6. **Почему/риски.** Разные поверхности действительно независимы. Сравнения только page UUID недостаточно при reparent/ancestor change. Disconnect/new-session должны отзывать устаревший barrier; нельзя дать локальному demanded work безусловно перезаписать remote source.
7. **Проверка.** Physical pair: удерживать контакт на A, локально открыть uncached элемент на B — он показывается. На том же target сохранить материал контакта до accepted tail; повторить reparent и disconnect/reconnect.

### F17 · P2 · Холодное чтение документа остаётся внутри очереди записи

1. **Проявление.** Открытие большого документа, даже уже отменённое, задерживает следующие durable writes и зависящие от них действия.
2. **Цепочка.** [enqueueDocumentOpeningRead:2069–2081](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookAppModel.swift#L2069) отправляет весь [readOpenedDocument](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookSceneState.swift#L19) в persistence command: addressed source/state reconstruction, JSON decode/validation, drafts и bounded history. Single pending opening ограничивает число задач, но cancellation отзывает только публикацию.
3. **Лишняя блокировка.** Read-only CPU/SQL работа занимает native writer, хотя page/scene reads уже имеют отдельный `NotebookSceneReader` с WAL session. Это один документ, не полный workspace/history.
4. **Основание.** Реальный enqueue и store read проверены lead. Стоимость зависит от документа; её нельзя считать установленной причиной малого TeX fixture194.
5. **Решение.** После короткого immutable accepted-write fence выполнять read/decode на существующем SceneReader. Один latest demand, source preparation keyed document/source identity; отмена снимает reader на разрешённых decode boundaries. F14 проверяет addressed basis и per-target accepted generation перед установкой. Удалить полное document read из writer command.
6. **Почему/риски.** CPU read не удерживает принятую запись. Не запускать неограниченные параллельные decoders; reader должен учитывать спрос. Перенос без F14 admission witness установит устаревший source/draft.
7. **Проверка.** Задержать document reader после fence, принять stroke/write — durable completion наступает до освобождения reader. Cancel A→open B→release A: показан только B. Target edit/new draft во время read не теряется.

### F18 · P2 · Cloud export удерживает writer до конца полного обхода

1. **Проявление.** Первая облачная выгрузка большого пространства или большой import/inverse delta задерживает durable save/undo и навигационные fences. Это не полный обход на каждом pen sample.
2. **Цепочка.** [NotebookCloudSync.pump](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Applications/Shared/NotebookCloudSync.swift#L253) → общий persistence writer → [prepareCloudUpload:112–185](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Sources/NotebookCore/NotebookCloudStorage.swift#L112), одна `commandTransaction`. Cursor 0 вызывает [cloudSnapshot](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Sources/NotebookCore/NotebookCloudSnapshot.swift#L6) по всем current records/removed history/manifest parts; затем целиком обходятся blob/program/ink/inverse/page-order dependencies.
3. **Блокировка.** SQL LIMIT и network chunks ограничивают память/сеть, но loops не отпускают transaction и FIFO. Следующая native write не может начаться между этими порциями. Blob assembly уже вынесена из writer — её не требуется «выносить» повторно.
4. **Основание.** Единица scheduling установлена по коду и независимо проверена. Продолжительность на устройстве/размер, после которого она заметна, пока не измерены; не связывать её без evidence с cold194.
5. **Решение.** Cloud owner хранит resumable preparation: immutable committed cut, scan cursor/dependency frontier, pinned hashes, состояние preparing/ready. Read planning выполняется вне writer; bounded outbox batches принимаются тем же writer с уступкой между ними. Ready публикуется после полного dependency closure. Удалить monolithic traversal. ACK/cursor advancement требует ready и полного подтверждения: текущая проверка пустой outbox ([208–212](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Sources/NotebookCore/NotebookCloudStorage.swift#L208)) одна недостаточна при порционной подготовке.
6. **Почему/риски.** Native writes получают очередь между порциями, целостность доставки сохраняется. Ограничить WAL snapshot lifetime, удерживать blobs от GC, корректно возобновлять после crash/account switch. Persisted scan cursor не сохраняет WAL snapshot после crash: продолжать можно из durable immutable snapshot parts/identities; при утрате cut неопубликованную подготовку отозвать и построить заново, без смешения версий и продвижения cloud cursor. Нельзя вторым writer нарушить порядок или отправить incomplete delivery; одна oversized dependency требует byte/work policy, не только LIMIT строк.
7. **Проверка.** Synthetic bootstrap + stroke/undo: writes исполняются между batches; итоговые manifests/ink/inverses равны единому cut. Kill/restart, account switch и ACK последней готовой порции до конца planning не продвигают cursor преждевременно. Physical latency измерять у save/navigation, отдельно от throughput cloud.

## Связи, порядок ремонта и критерии завершения

Ремонт должен сохранить одного владельца записи, один compiler и один runtime
программы. Общие исправления — точный read-set и передаваемый immutable frame —
не повод собирать новый универсальный AppModel. Domain owner принимает состояние;
prepared material и frame lease лишь представляют его конкретную версию.

Предлагаемая последовательность состоит из законченных пользовательских срезов, закреплённых в [проекте ремонта GUI-306](https://linear.app/main-cluster/issue/GUI-306).
Порядок работ не означает, что все они имеют техническую зависимость друг от друга.

| Срез | Законченный результат и границы | Зависимости и достаточная проверка |
|---|---|---|
| R1. Писать сразу после открытия и преобразования ink — GUI-295 | F02/F03/F12: подготовленный ink source, retained ordered accepted composition, feedback из того же материала. Удалены body decode и overlay roundtrip | Самостоятельный срез. Cold Pencil, pen→move→pen→erase→undo/redo на physical iPad; affected dense-history test и GPU/frame trace |
| R2. Целый смешанный выбор — GUI-226 | F11/F13: один clock/cut для raw, authored и controls; адресный selection read-set, move/cancel/handoff. Не терять выбор от чужого append | Использует R1 material lifetime. Physical first drag, reverse, cancel, rapid undo/redo и agent conflict; визуальные кадры и реальные presentation spans |
| R3. Открывать нужное содержимое при совместной работе — GUI-315 | F14/F17: addressed admission/install witness и document read на WAL worker. Нет global epoch retry и full read внутри writer | Самостоятельная подготовка, согласовать F02 source API. Gated-read independent/targeted edits, cancel A→B, native write во время read; physical cold open + agent |
| R4. Сразу гнуть лист и принимать следующий жест — GUI-298 | F01/F04/F05/F06: page UUID lifetime, lease готового кадра, native cover progress, передача settlement контакту. Удалены pair capture и per-sample root/layout | Использует R1/R2 frame boundary и R3 адресную установку. Сначала закончить notebook route; общий lease используется документом в R5. Реальный append→reverse, свежий stroke→turn, cancel/regrab, cold/warm cover; прежние timing thresholds |
| R5. Читать последний исходник и лист с неисправной программой — GUI-200 | F07–F10: paper/slot readiness, точные print dependencies, latest-demand cancellation, demand-local preparation; затем адресное измерение оставшегося native cold cost | Использует R3 source witness и R4 frame lease. Согласовать с GUI-310/311, не создавать второй program/file pipeline. Cold194 ≤ прежних 1000 мс, A→B, independent JS, never-ready slot, far navigation/accessibility/export |
| R6. Локальный переход при чужой активности — GUI-316 | F15/F16: scoped input/accepted-write/program handoff и peer-target overlap. Удалены глобальные joins из local navigation | После R3 и R5, сохраняет R2 input tail. Held unrelated checkpoint/Send/steer, physical A/B peer input; dirty focused program и shutdown сохраняют state |
| R7. Сохранять во время cloud bootstrap — GUI-317 | F18: persisted resumable export preparation, bounded writer batches, complete/ready ACK contract | Технически независим; выполняется после R6, чтобы проверять весь save→navigation маршрут. Closure equivalence, crash/account/earlyACK и physical write latency |
| R8. Принять интегрированную пару — GUI-190, координатор GUI-306 | Один источник всех предыдущих срезов, matched Mac+iPad update с сохранением containers/identity/keys | После R1–R7. Сначала affected regressions и сценарии, затем отдельная полная physical acceptance: OS frame/CPU/GPU/memory, 10 повторений и 30 минут совместной работы по текущему контракту |

Существующие пороги проекта сохраняются: physical Pencil ≤20 мс, первый изгиб
≤16,67 мс и 120 Гц cadence, inverse/selection ≤100 мс, cold document ≤1000 мс.
Проверяется соответствующий конкретному действию oracle, не произвольный быстрый
внутренний receipt.

У каждого среза критерий завершения включает удаление заменённого пути, scoped
проверки на неизменных исходниках, conventional commit/push и точное различение
saved, delivery и displayed. Промежуточные проверки нужны для конкретной
неопределённости. Полная приёмка не запускается после каждой локальной правки.
GUI-202 остаётся отдельной исторической задачей Mac/Simulator и не подменяет R8;
Simulator в этот проект проверки не выбран.

Для R4 нельзя одновременно обещать удалить snapshots и оставить неизвестный
источник WebKit pixels: локальная подготовка program snapshot остаётся у program
owner, снимается именно полностраничный UIKit readback на старте жеста. Для R5
нельзя обещать требуемое cold время до измерения native print phases. Для R6
нельзя «разблокировать» UI, отпустив accepted writes или dirty focused state.
Для R7 нельзя разрезать transaction, оставив прежнее правило ACK пустой outbox.

## Существенные неопределённости и границы покрытия

- После исключения capture остаётся объяснить OS cadence/непоказанные progress frames192. Нужен trace scheduled→GPU→OS-presented на том же source, а не CADisplayLink как FPS.
- Нужна текущая физическая проверка смешанного cancel: исходники caller изменились после191. Source-proven сериализация не доказывает сохранение старого визуального рассогласования.
- Native cold print остаётся измеренным превышением бюджета. Точная разбивка текущей194, cold/warm/после15с, память runtime и стоимость обязательных passes ещё не измерены.
- Не установлена длительность cold ink decode, ordered recomposition, global epoch churn, cloud writer occupancy и feedback на реальном пользовательском объёме. У каждой находки указана короткая различающая проверка; они не требуют общего многонедельного профилирования.
- Возможен lock convoy: [PageInkDrawing.Source.data/drawing](https://github.com/AmirTlinov/Notebook/blob/0b237f6df17357a964a09e43c66e94901cf77fb8/Sources/NotebookCore/PageInkDrawing.swift#L17) используют один lock во время полного encode/decode. Background scene equality может вызвать `data()`, а main input — `drawing()`. Сам overlap не воспроизведён; R1 должен оставлять долгий encode вне mutex чтения готового immutable root.
- Проверены главный iPad interaction route, shared owners, document/program lifecycle, writer/WAL/peer/cloud scheduling и граница агентских изменений. Mac input/IME/VoiceOver, внешние clipboard workflows, pressure/estimated Pencil samples под стрессом, длительные memory-pressure/thermal сессии, filesystem/fsync и live SQLite query plans, транспорт при длительной потере пакетов, все account-switch/extension teardown и произвольная логика пользовательских программ глубоко не профилировались.
- Наличие очереди, await, большого файла или защитного guard само по себе не считалось дефектом. Не обнаружено универсального disk write на каждую точку, полного replay истории на обычный Undo, полного scene rebuild при каждом обычном camera sample или необходимости второго SQL writer.

Результат этого задания — проверенный причинный диагноз и проект ремонта.
Ремонт и новая физическая приёмка остаются последующей работой.
