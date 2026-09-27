# Ремонт причин задержек — 27 сентября 2026

Основание: [причинный аудит](causal-audit-2026-09-27.md), F01–F18.
Работа начата от `dbaf04e94268d8d9e914a2a33b801691a2129d57` в
`codex/causal-repair`. Предыдущая установленная пара — 0.3.143 (213);
ремонт выпускается как 0.3.145 (215). Код F01–F18 собран перед первым прогоном; последующая интеграционная
проверка выявила и позволила исправить границы между владельцами.

## Изменённые владельцы

| Причина | Исправление и удаляемая работа |
|---|---|
| F01, кадр листа | `PageTurnMaterialOwner` готовит неизменные native/static материалы при установке страницы. `InkCanvasView` выдаёт lease принятой GPU texture с copy-on-write; соседний лист сохраняет готовый фон с passive priority. `PageTurnFrame` составляет кадр на GPU; curl удерживает пару до своего последнего submission. Document owner повторно использует неизменный GPU cut и отдаёт его память при давлении. Обложка использует canonical compositor; UIKit capture/retry timer удалены. Живая программа выдаёт только локальный current cut своего существующего runtime. |
| F02, холодные чернила | `PageInkSource` владеет одной подготовленной drawing/erasure projection. Reader готовит её до допуска страницы; первый lift принимает только подготовленный source. Getter SwiftUI не сериализует архив и не становится холодным decoder. |
| F03, преобразованные чернила | `InkCanvasView` удерживает ordered фон и обновляет повреждённую область ластика; следующий pen-tail использует тот же retained путь. Полная ordered staging-перерисовка и общий GPU drain удалены. |
| F04, идентичность страниц | `IPadPageTurnController` различает UUID физической страницы и revision порядка. Перестановка remap-ит резидентные owners; provisional leaf принимает сохранённый UUID. Принятая пара переживает публикацию successor до endpoint. |
| F05, обложки/порталы | `SceneNativeCameraProjection` передаёт непрерывную позу native owners обложки, тени и clip. SwiftUI получает смену смысловой фазы; повторная установка content root на каждом progress удалена. |
| F06, новый pinch | Контакт принимает текущую частичную позу settlement вместе с readiness, rollback и обязательством завершить portal handoff. Безусловное отбрасывание контакта после начала settlement удалено. |
| F07, готовая бумага | `DocumentPagePresentationOwner` допускает бумагу независимо от готовности программных slots. Focus/checkpoint обслуживает конкретный program owner; неподготовленная соседняя программа не закрывает весь лист. |
| F08, print identity | Canonical typesetter записывает реальные reads, отрицательные file probes и directory enumeration. Artifact identity отделена от causal source binding; те же входы используют PDF и projection повторно, receipt привязывается к текущей версии. |
| F09, отмена подготовки | Один typesetter scheduler различает current и background demand, ограничивает очередь и удаляет jobs без подписчиков. Deadline начинается при исполнении. Source subscriber отменяется независимо от принятого WebKit/GPU tail; старый source больше не удерживает latest sender. |
| F10, первый лист | Print cache получает lazy inputs, artifact удерживает одну decoded SyncTeX projection. Packages, state, navigation/text/links готовятся по demand физических страниц. Безусловный 15-секундный сброс immutable runtime ресурсов удалён. |
| F11, смешанный выбор | `prepareOrderedPlan` готовит геометрию; `presentOrderedPlan` принимает pose в доступный слот frame clock. В том же native cut устанавливаются ink, graphics и controls. Ожидание всех старых GPU commands/CA completion перед каждой позой удалено. |
| F12, агентская подсветка | Один episode owner готовит mask выбранного контакта и влияющих cuts вне main. Камера только проецирует готовый материал; повторное декодирование/обход всей истории в body удалены. |
| F13, read-set выбора | `NotebookInkReadSet` хранит выбранный контакт и более поздние пересекающие cuts. Native и SQL admission проверяют этот адресный набор; unrelated pen/journal clock не отменяет выбор. Schema 27 добавляет page erasers в существующий пространственный индекс. |
| F14, публикация read | `NotebookSourceWitness` проверяет фактические headers/owners/content, а `NotebookReadAdmission` учитывает ещё не сохранённые локальные edits только за жизнь read. Общий collaboration epoch/cursor больше не запрещает независимый результат. |
| F15, адресный переход | Navigation завершает текущий input и checkpoint конкретной уходящей программы, ждёт уже принятый FIFO tail, затем читает назначение. Ожидание посторонних shell/chat/arrival jobs и глобального quiescence удалено; idle wait отменяемый. |
| F16, другой участник | Peer contact сопоставляется с canonical surface и цепочкой предков. Immutable preparation продолжается; publication ждёт только пересекающий owner. Scope живёт с read либо установленной сценой и удаляется при отмене/retirement. |
| F17, открытие документа | Writer даёт короткий FIFO fence; тяжёлое чтение идёт через `NotebookSceneReader` в WAL. После peer wait и writer witness повторно проверяются latest request, cancellation и local admission. |
| F18, cloud export | Upload reader фиксирует consistent record cut и дисковый dependency plan. Immutable blobs обходятся короткими reads без replay измерений. Writer принимает подготовленные bytes/порции до 64 descriptors и уступает FIFO. Export становится отправляемым только после seal; ACK, account generation, crash resume и отмена принадлежат тому же owner. |

На границе владельцев один receipt различает показанную бумагу и пригодный для
curl кадр. Открытие и прямой переход не ждут подготовки будущего перелистывания;
начало curl требует двух пригодных кадров, завершение — показанного живого листа.
GPU completion скрытого соседа не ждёт OS presentation. После реально показанного
endpoint curl открывает готовый native host, разово запрашивает его показ и сохраняет
принятую пару/input gate до OS receipt. Повторный контакт возвращает curl наверх.
Нижняя граница sequence исключает callback старого motion с тем же cached frame.
Static SVG получают readiness от exact installed provider; маски также получают
этот разовый visibility edge. Показ бумаги не подменяется готовностью GPU.
Ошибки этих двух операций и их Retry независимы внутри одного владельца страницы.
У документа кадр включает реально установленные программы либо видимые сообщения
об их подготовке/ошибке; готовность программы к вводу не подменяет готовность бумаги.
Запрошенный лист повышает приоритет backing и возобновляет остановленную подготовку
после отказа в памяти. Замена исходника документа сохраняет native hosts, но отзывает
прежние запросы, кадры и receipts.

Receipt страницы теперь живёт столько же, сколько её физический host.
Обычный root-view refresh не создаёт пустой provider при сохранённом ready.
Смена document source явно отзывает старый receipt; перестановка notebook UUID
сохраняет его и меняет индекс. Смена установленного материала отдельно будит
принятый curl, даже когда Bool готовности остался `true`.

Временный отзыв материала во время `acquire` сохраняет принятый turn и его
прогресс. Уже полученный сигнал готовности потребляется один раз; иначе motion
ждёт следующей публикации владельца. Только типизированный отзыв source
допускает ожидание; timeout/ошибка WebKit сохраняют явный Retry. Смена live program на retained raster публикует адресную
готовность capture через один weak subscriber; одинаковый layout не будит UI.

Состояние живых программ имеет отдельный `liveSources`/generation внутри material owner.
После нажатия обновляется точный source слота; неизменная бумага и native artwork
не пересобираются. Capture фиксирует generation перед первым ожиданием и проверяет
её после локальных snapshots и composition. Так новое состояние не сравнивается
с сохранённым при открытии страницы старым `AgentElement`.

Принятый curl передаёт input priority до временных allocations. Его current cuts
живых программ не публикуются в passive cache и не создают mipmaps; прежний
snapshot/checkpoint сохраняет собственный кешируемый путь. Независимые уже установленные runtimes отдают прямые cuts одной группой: все
эти pixels и так удерживаются до composition, поэтому последовательные волны
не уменьшали пик памяти. Перед каждым capture остаётся физический resource grant.
Копии с преобразованием/стиранием ограничены четырьмя, фрагменты одной программы
документа — последовательны; порядок слоёв сохраняется.
Прямой cut без crop/transform/erasures не копируется через отдельный CPU canvas.
CPU cut удерживается до завершения GPU composition, готовый frame — до последнего
curl borrow. Кешируемые static frames сохраняют passive budget; отказ кеша допускает
временный input frame, который не становится resident. У документов и живых
обложек тот же контракт: один snapshot producer, временный cut принятого движения,
освобождение обложки на endpoint. Это убирает
последовательные WebKit display rounds и отказ принятого жеста по лимиту фонового кеша.

При запуске WebKit JavaScript-ready больше не удаляет актуальный raster до первого
нативного изображения. Точный fallback остаётся под работающим control до
существующего WK snapshot callback и проверки installation. Paint identity включает
load/presentation token; перезапуск того же WK lease не наследует старое подтверждение.
Cache/mipmap publication не блокирует input, ошибка capture снимает fallback,
чтобы прозрачная программа не удерживала прежние пиксели.

Возврат на страницу выявил гонку retirement: callback пассивного snapshot
помнил прежний `isActive=false` и мог освободить WebKit после нового активного
prepare. `PreparationOwner` хранит текущий demand/request; callbacks освобождают
только его пассивный lease, результаты после await проверяют тот же request.
Обработчик ошибки snapshot также проверяет текущую роль потребителя.
Принятое состояние отдельно публикует exact native source installation, поэтому
перепривязка существующего executor не ждёт passive cache/mipmaps.

Адресное чтение также фиксирует выбранный UUID и конечный набор подготовленных
страниц. Старое coverage/refresh не может вырезать нового соседа из `pages` и
`pageAddresses`, даже если он отсутствовал в прежнем content read-set. При смене
этого набора перечитывается актуальный запрос; движение камеры его не отменяет.

Физическое открытие плотной тетради выявило отдельный цикл:
`AgentSnapshotRasterView.layoutSubviews` → `recordInstalled` →
`PageTurnActivity.installElementFrame` → Observation invalidation → layout.
Реестры кадров и callbacks теперь исключены из Observation; смысловые состояния
перехода остаются наблюдаемыми, а готовность приходит через существующие callbacks.
Это убирает зависимость layout от записываемого им же служебного реестра.

Эксперимент с отдельным UI phase clock отклонён физическим результатом: OS
median пера/ластика выросла до 47,377/44,841 мс, первый dot не получил валидный
receipt. Этот путь удалён; текущий renderer сохраняет CAMetalDisplayLink и
отдельный OS witness. Неудачный эксперимент не объявляется улучшением.

Установка 214 выявила ошибку миграции индекса: сохранённые действия ластика
удалённых страниц читались через API с обязательным live membership. Такое
чтение возвращало `target_missing` и откатывало запуск. В 215 индекс читает
адресные сохранённые действия через тот же canonical decoder; публичное чтение
сохраняет membership gate и лимит. Пространственный backfill берёт painter order
только из заголовка действия, без measurement bodies. История не удаляется.
Регрессия 26→27 теперь включает штатно удалённую тетрадь с сохранённым ластиком,
неизменность record proof/cursor и сохранение запрета публичного чтения.

## Проверка результата

Код F01–F18 написан до первого прогона. Затем выполнена интеграционная
проверка; её отрицательные результаты привели к исправлениям границ выше.
Точный объём, исходники и ограничения — в [verification](verification.md)
и [машинной сводке](audit-evidence/2026-09-27/causal-repair.json).

Core: 46 проверок плюс миграция schema26→27; browser: 15. На физическом iPad
проверены input, mixed selection, page UUID, resources, документы, late read/write
и 100000 ink workload. Десять dense forward/reverse и десять board zoom дали
нулевые XCTHitchMetric. На Mac прошли 9 проверок render session/print read-set.
Это отдельные результаты с собственными source witnesses, не общий PASS.
В 2150 прошли UI24 first taps/state/forward/reverse и три проверки поздних
WebKit callbacks; после финальной правки failure branch три проверки повторно
прошли в 2158. Это завершённая выбранная регрессия, не полная приёмка.

Диагностика inverse-journey отделила принятый GPU cut от UIKit window capture:
новая линия присутствует в exact GPU generation17/source stamp10, OS receipt
23,023 мс, дополнительных кадров не было; `drawHierarchy(false)` её пропустил.
Потеря body в retained mesh исключена. Граница final drawable/CA/window snapshot
остаётся непроверенной независимым display oracle; исходный FAIL сохранён.
Повтор неизменённого неоднозначного window test не выдаётся за ремонт продукта.

## Существенные границы

- Print pagination остаётся глобальной, если изменён её действительный вход.
- Пространственные чернила обложки пока не имеют accepted GPU export lease:
  canonical compositor рисует их один раз на material cut, а не на каждом
  изменении положения жеста. Готовность обычного листа требует принятого
  ink key и GPU completion; готовность живой страницы дополнительно требует
  OS presentation того же источника.
- Cloud snapshot ещё требует одного consistent WAL cut для mutable address
  enumeration. Полный immutable dependency walk этот cut уже не удерживает.
  Обычная manifest part целится в 1 MiB; предел 512 parts wire-протокола может
  требовать более крупных частей, до 64 MiB. Абсолютный 1 MiB writer quantum
  для предельного workspace не заявляется.
- Исторические source-matched 192/194 служат исходным отрицательным результатом;
  новые показатели должны относиться к новому inventory.
- Полная приёмка по контракту (30 минут совместной работы, все системные
  CPU/GPU/memory измерения и все повторения) отличается от выбранной регрессии.
