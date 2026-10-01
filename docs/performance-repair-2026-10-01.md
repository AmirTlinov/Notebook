# Оставшиеся задержки: ремонт 230

База: `f6793c9` / установленная пара 0.3.159 (229). Работа выполнена через
владельцев ввода, страницы, публикации и ресурсов. Субагенты исследовали curl,
первый кадр чернил и программы; интеграция и физические прогоны — одним runner.
Финальный source `2e85dc9f…`: **24 iPad + 2 Mac PASS**, skip/failure=0.
Проверены реальные notebook paper после reverse/eviction, ресурсный retirement,
чистое изменение CSS, mixed cut, first Pencil и системные gestures.
[Финальный scope](audit-evidence/2026-10-01/remaining-latency-230/final-results.json).
Предыдущие source-matched receipts сохранены рядом как история диагностики.
Пара **0.3.160 (230)** установлена на Mac и iPad 1 октября04:37 МСК; helper ready,
trusted identity и сохранённая страница/камера совпадают с229. На реальном экране
сохранённая рукопись1/5. [Доставка](audit-evidence/2026-10-01/remaining-latency-230/delivery.json).

Общая причина — смешение стоимости локального действия с работой соседнего
владельца и смешение разных фактов готовности. Карта контакта пересобирала весь
документ; допуск WebKit выдавал следующую синхронную работу до оценки предыдущей;
публикация движения ожидала OS receipt, а принятый штрих терял собственный reveal.
Сохранённый drawable pool при этом каждый раз терял физическую установку. Ремонт
закрепляет решения за существующими владельцами и удаляет эти зависимости.

## Локальная перерисовка программы обходила весь DOM

1. **Сценарий:** программа обновляет текст/цвет; её следующий контакт ждёт новую
   карту ввода. Любая DOM mutation повторяла `querySelectorAll('*')`, классификацию
   и computed style всех узлов.
2. **Цепочка:** `AgentWebFingerRegions.script` → MutationObserver → microtask →
   `snapshot` → native `fingerRegions` → `AgentWebCoordinator` → iPad input gate.
3. **Работа:** O(весь DOM) ради локального изменения, даже у пассивного текста.
4. **Основание:** живой script 229 и workload 100 000 узлов / 400 изменений;
   новая проверка считает обходы и чтения стилей, отдельно от скорости WebKit.
5. **Исправление:** документ владеет индексом input/link. Структурное изменение
   классифицирует затронутые поддеревья; движение обновляет геометрию кандидатов.
   CSSOM mutators, CSS state/focus/hash и загрузка stylesheet обновляют зависимости.
   Публикация остаётся microtask до paint. `stop` освобождает индекс и subscriptions;
   retirement исполняется только в прежнем load token.
6. **Риск/альтернатива:** произвольный CSS, определяющий touch-action/all,
   сохраняет консервативную полную классификацию при изменении зависимостей.
   Перенос в следующий RAF нарушил бы карту контакта после авторского RAF.
7. **Проверка:** большой пассивный DOM, перемещение, once/abort, CSSOM,
   :has/:dir, фокус и :target, закрытие runtime; реальные native routing points.

## Прямое CSSOM изменение оставляло прежнего владельца контакта

1. **Сценарий:** ранее пассивная программа присваивает rule.style.touchAction;
   вычисленный CSS принимает ввод, а native карта продолжает отдавать его сцене.
2. **Цепочка:** авторский CSSOM setter → индекс документа → native finger regions.
   Accessors WebKit принадлежат CSSStyleProperties; hook только базового
   CSSStyleDeclaration молча пропускал их.
3. **Ошибка:** прямой native setter обходит JS setProperty; без другого DOM/resize
   события карта не обновляется. Старый fixture менял одновременно текст.
4. **Основание:** [WebKit IDL](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/css/CSSStyleRule.idl)
   и физический сценарий без маскирующего текстового изменения.
5. **Исправление:** существующий владелец ищет accessor по prototype chain
   реального declaration: cssText, touchAction, touch-action, all. Retirement
   восстанавливает только собственный сохранившийся hook.
6. **Риск/альтернатива:** неподдерживаемый accessor пропускается; постоянный scan
   по таймеру добавил бы полную работу и задержал смену принадлежности контакта.
7. **Проверка:** нейтральное правило → none/input → all/auto/scene; dashed setter
   и возврат auto. Computed CSS и native hit map проверяются отдельно.

## Следующая поза curl ожидала показа первой

1. **Сценарий:** первое движение/отпущенное перелистывание. Даже после CA commit
   следующая поза сохраняла transactional mode до первого положительного OS receipt.
2. **Цепочка:** `IPadPageTurnController` → `SheetCurlMetalView.publishPageUpdate`
   → CA hierarchy → drawable → OS receipt. `PagePresentationPhase.awaitingOS`
   конкурировал с точной `pageCARevision`.
3. **Работа:** лишняя последовательная зависимость shader-only движения от показа
   прежнего кадра. В 229 CA commit 11,44 мс, первый OS receipt 42,725 мс.
4. **Основание:** source clocks и фактические OS outcomes; новый контроль принимает
   следующую позу после CA commit до доставки первого OS receipt.
5. **Исправление:** удалён `PagePresentationPhase`. Reveal, размер и refront
   публикуются с точным CA cut; последующее движение async. Показанная поза и landing
   по-прежнему принадлежат реальному OS receipt и UUID операции.
6. **Риск/альтернатива:** blanket async нарушил бы первый reveal. Первый OS discard
   и ожидание внутри nextDrawable этим изменением полностью не устранены.
7. **Проверка:** held/released movement, regrab, cancellation, complete pair без
   flat primer; отдельно timestamps acquisition, GPU, CA и OS, без readback в timing.

## Повторное скрытие output теряло первые кадры следующего curl

1. **Сценарий:** следующее перелистывание после завершённого. Пул уже существует,
   но первые bent drawables снова discard, словно output впервые устанавливается.
2. **Цепочка:** `IPadSheetCurlController.resolveMotion` →
   `SheetCurlMetalView.releaseSource` → hidden parent/output → следующий reveal
   с CA transaction → OS. Allocation и точный source при повторе сохраняются.
3. **Работа:** слой и его UI предок каждый раз проходят hide/reveal; сохранение
   только объектов drawable pool не сохраняет установленный output.
4. **Основание:** физический контроль с тем же пулом. Повторный hide/reveal:
   39,000/40,342 мс, по 3 discard. Output, оставленный под непрозрачной страницей:
   21,566–23,592 мс, 0 discard. Это подтверждает вклад жизненного цикла видимости;
   [контроль](audit-evidence/2026-10-01/remaining-latency-230/hide-reveal-control.json)
   не доказывает отдельный внутренний механизм CA и не закрывает strict16,667 мс.
5. **Исправление:** renderer сохраняет свой ограниченный, reclaimable pool.
   `PageTurnOutputHost` предоставляет только место монтажа. После фактически
   показанного endpoint native paper принимает output под своим существующим
   clip: `PagePresentationNativeView` под opaque GridPaper или `DocumentWebHost`
   под точным установленным native PDF. При следующей preparation слой остаётся
   там; первый scheduled bent frame возвращает его в curl вместе с refront/CA cut.
   Обычный hidden path сохраняется только при отсутствии подходящей бумаги.
6. **Риск/альтернатива:** прозрачный whole-page host показал бы прямоугольные
   остатки curl вокруг бумаги. Поэтому mount проверяет actual window, canonical
   bounds и readiness; документ дополнительно проверяет UUID/source/page raster.
   Изменение mount/source/размера, failure/fallback, retirement и scene cancel
   отзывают output и drain его существующую GPU/request работу. Новый cache,
   прогревочный кадр, delay или фоновая перерисовка не добавлены.
7. **Проверка:** шесть чередующихся переходов сохраняют точную идентичность пула;
   resize и отмена освобождают его без resurrection. Отдельно реальная notebook
   paper после reverse/eviction, document paper до WebKit/перенос host,
   первый small bend, regrab, late UUID и уход сцены. Скорость фиксируется у OS
   receipt отдельно от снимка изображения.

## Принятие первого штриха отвергало его уже подготовленный reveal

1. **Сценарий:** быстрый lift до публикации первого кадра. Принятие того же штриха
   увеличивало content revision и отвергало scheduled callback его GPU-команды.
2. **Цепочка:** Pencil → commit measured mesh → accepted append → `settle` →
   `beginStableContentUpdate` → `InkCanvasView` scheduled publication guard.
3. **Ошибка:** идентичные пиксели считались устаревшими; раскрытие слоя ожидало
   следующую подачу. После успешного reveal completion безусловно запускал ещё
   одну идентичную GPU-команду.
4. **Основание:** исходники и first-lift trace: original published/discard,
   accepted successor shown, затем реальная третья submission.
5. **Исправление:** pending reveal хранит witness конкретного predict-free pen,
   измерений, цвета, исходного action cursor, проекции и baseline. Только точный
   lift + единственный accepted append продвигает witness. Старый кадр не
   подтверждает новую accepted revision. Completion сравнивает свою demand и
   вызывает следующий кадр при изменении, queued cut или OS discard.
6. **Риск/альтернатива:** общий допуск stale revision показал бы undo/crop/source
   изменения. Они по-прежнему отвергаются; window identity и source generation
   проверяются. OS может discard корректно опубликованный кадр.
7. **Проверка:** исходная публикация после принятия штриха, собственный OS outcome,
   одна актуальная подача; undo/crop/source/eraser/reset, пиксели и нативный путь
   Pencil на физическом iPad. Hardware contact-to-display измеряется отдельно.

## Обычный curl оставался владельцем после деактивации сцены

1. **Сценарий:** Home/закрытие окна во время borrow пары или холодной цели;
   позднее завершение могло оживить переход при возвращении.
2. **Цепочка:** UIScene lifetime → mounted `IPadPageTurnController` → operation,
   input claim, page pair и GPU retirement. Отмена reference navigation не
   охватывала обычный curl.
3. **Ошибка:** незавершённая операция и ожидающие callbacks переживали свой UI.
4. **Основание:** отсутствующая source subscription и native lifetime regression.
5. **Исправление:** контроллер принимает события только своего mounted scene,
   завершает операция `.cancelled`, освобождает claim/borrow и отвергает late UUID.
   Новое окно задаёт actual scene state; повтор того же окна не отменяет раннюю
   willDeactivate. Исходная существующая страница сохраняется.
6. **Риск/альтернатива:** глобальная application notification смешала бы окна.
   Curl view сообщает только факт монтажа; решение остаётся у контроллера.
7. **Проверка:** другая сцена, delayed borrow/readiness, deactivate/reactivate,
   disconnect, remount, повторное действие и уже завершённая страница.

## Два заранее выданных разрешения складывали синхронное создание WebKit

1. **Сценарий:** холодная страница с 24 программами. Допуск количества 2 позволял
   второй constructor, даже когда первый уже занял доступный интервал UI.
2. **Цепочка:** `SceneRenderResources.admitWaiters` → два grants → native factories
   → `SceneWebConstructionAdmission.finish` → следующий UI completion.
3. **Блокировка:** первая creation 27,532 мс и следующая 4,885 мс выполнялись в
   одном actor/UI cycle; вместе с source/navigation цепочка занимала 34,929 мс.
4. **Основание:** времена у native source events физического iPad. Это wall time
   синхронного пути, не разложение CPU/IPC. Отдельный all-process profiler не
   экспортировал пригодный trace; его времена не являются latency acceptance.
5. **Исправление:** UIKit выдаёт один ещё не выполненный grant. Все native factories
   сообщают elapsed своего создания, исключая очередь. Следующий grant возможен
   в пределах двух владельцев и половины display interval; исчерпанная стоимость
   освобождается существующим CA/UI completion, без delay/polling и без ожидания
   remote navigation. AppKit/headless сохраняет свой deferred constructor cut.
6. **Риск/альтернатива:** полный запуск программ может растянуться на больше UI
   циклов. Первая синхронная creation остаётся неделимой. Миграция программ в один
   WebKit context нарушила бы независимость фокуса/состояния и изоляцию runtime.
7. **Проверка:** неизвестная стоимость запрещает pregrant; дорогая creation ждёт
   actual UI completion; deactivate/activate и cold24, затем first tap/turns/pinch.

## Результат и оставшиеся границы

- Parking: первый холодный output27,883 мс/3discard; пять повторов того же pool
  20,414–23,656 мс/**0discard**. Exact reparent, OS endpoint, resize/cancel и actual
  notebook paper после reverse/eviction прошли. Это устранение повторного
  hide/reveal; strict16,667 мс и первая установка остаются открытыми.
  [Показ и lifetime](audit-evidence/2026-10-01/remaining-latency-230/parked-output.json).
- First-lift проверка подтвердила original publication, реальный OS discard и
  одну необходимую accepted submission; идентичная третья подача исчезла.
- Большой DOM и CSS state/native contact проверки прошли. Системные UI сценарии
  подтвердили 24 первых tap, сохранение state после turns/pinch/Home, повторное
  открытие документа; UUID удаления, cancellation и remount проверены native.
- Два source observation curl: до снятия OS gate первый OS42,725 мс / 3discard;
  финальный срез23,740 мс / 1discard. GPU8,162 мс, landing333,541 мс. Это отдельные
  программные прогоны тестового окна, без hardware latency или FPS claim.
- Адресные clocks выявили один nextDrawable stall14,910 мс; worker начал сразу,
  MainActor delivery не удерживает take. Долгих app-ссылок на discarded output
  не найдено; различие занятости пула и внутренней блокировки слоя не установлено.
- Отдельный strict first bend остаётся **FAIL**: шесть переходов27,553–51,427 мс,
  бюджет16,667 мс; 2–3 initial discard. Повторы используют уже созданный pool.
  [Отрицательный результат](audit-evidence/2026-10-01/remaining-latency-230/strict-first-curl.json)
  сохраняется; первая allocation не объясняет повторный discard. Последующий
  контроль установил вклад повторного hide/reveal; исходный strict fixture
  не предоставляет actual paper receiver и сохраняет прежний путь.
- Cold24: first native263,924 мс, все источники829,827 мс. Первая navigation request
 82,041 → policy200,045 → started242,484 → ready262,687 мс; этот launch/IPC
  промежуток остаётся отдельным вопросом. Observer cost входит в диагностический
  scope; сравнивать его с профилированным прогоном как ускорение нельзя.
- Финальный source observation: cold24 first native258,412 мс/all814,987 мс;
  fresh curl GPU2,749 мс/OS24,494 мс,1discard. Перед first navigation policy
  выполняется board preparation90–179 мс; её вклад и WebKit launch/IPC пока
  не разделены. Это диагностические границы, не обещание скорости установленного
  приложения или измерение аппаратного contact-to-display.

Проверенный порядок ремонта: индекс контакта и CSSOM → допуск фактической
стоимости native construction → независимая публикация/first-ink witness →
scene cancellation → установленный output у конкретной бумаги. Последний срез
проверяет их совместный путь; изменения сохранения и runtime isolation не требовались.

Адресный cold-path review: `AgentWebElementView.loadHTMLString` возвращается за
0,103 мс после полной сборки HTML; policy сразу завершает свой decision handler.
`returned→policy`105,673 мс и `policy→started`36,006 мс не разделены между WebKit
и очередью MainActor. Другие четыре constructors в первом интервале занимают
суммарно18,774 мс. `SceneCompositionTiles` работает с отдельным source actor;
native ink использует detached worker, tile-render событий здесь нет. Поэтому
87,6 мс board elapsed нельзя объявить CPU блокировкой. Paper монтируется
независимо от cohort (`SpatialWorkspaceView`); полная отмена board задела бы
фон, cover и выход. Недостающий конкретный результат — момент готовности WK
policy message вместе с main-thread stacks, process/IPC events и его delivery.

Следующий адресный срез — остаток cold initial OS discard/занятости drawable pool
и холодного launch/IPC. Parking устраняет подтверждённый повторный hide/reveal;
первый output всё равно требует первоначальной установки. Для остатка нужны
physical drawable/texture identities и weak retirement witness; для запуска —
пригодный source-matched process trace. Hardware
Pencil и промежуточные mixed OS cuts требуют своих наблюдений. Full acceptance
GUI-190 остаётся отдельной работой; текущий ремонт её не подменяет.
