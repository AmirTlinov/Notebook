# Проверка Notebook

## 19 сентября, 17:44 МСК — GUI-250: Simulator UI opening не принят

Test-only Simulator bundle собран, installed V16 и контейнер сохранены.
Sound search/tap довёл реальный public `nb.observe` до точной обложки
`98001c01-bd25-4112-90fc-591c72667a5c`, mode=cover/openProgress=0; сам документ
ещё не открыт. Последние XCTest events17:39:17 — AX cover query с automation
type mismatch. Дальнейшего прогресса не было; app наблюдался с0–1%CPU.
После bounded stop xcode не завершил finalize-test-log, собственные диагностические
PID остановлены адресно. xcresult не финализирован (нетInfo.plist); подвисший
sample не даёт performance evidence. Ни XCTest PASS, ни показ не заявляются.
`receivedByIPad=confirmed`, `shownOnIPad=awaiting_display`. Offline large UI не
запускался. Следующая проверка должна сначала локализовать cover accessibility/
UI-driver зависание, не повторять слепо полный прогон.

Evidence: `.build/gui250-received-program-ui-v18/{ui-build.json,xctest-events.log,interruption.json,sound-live-receipt.json,observe-after-interruption.json}`.
Физический iPad, production и сеть не менялись. Этот отказ UI gate не отменяет
принятый отдельно Mac scroll fix790847b или byte-for-byte receipt большого пакета.

## 19 сентября, 17:37 МСК — GUI-248: содержимое больше не прилипает к titlebar при scroll

Mac V18 source `5b52a090262d84c42eee301c42c5a390a28911894791c27efbfe7138f5e265e4`,
cdhash `5fb5dfb73194c79bc6c112a4fd294b37cc5b377a`, установлен только в private stand,
store/manifest побайтно сохранены. Simulator остаётся V16; production не затронут.

Причина: автоматический `WKWebView.obscuredContentInsets` трактовал уходящую
за верх окна бумагу как содержимое под titlebar и независимо сдвигал live DOM.
Read-only диагностика установленного V17 обнаружила top inset185.896pt при
неизменных native frame/bounds. Воспроизведение с настоящим titled/fullSizeContentView
окном: CSS height1542→1367→767 при pan; borderless fixture этого не показывал.
Фабрика теперь задаёт явные нулевые insets до mount. В текущем WebKit публичный
setter возвращается до отключения automatic policy, если значение не изменилось,
поэтому перед zero устанавливается другое значение на ещё не показанном view.
Нет private API, observers, нового camera owner или дополнительных frame loops.
[Реализация setter WebKit](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm).

- Настоящий AppKit/WebKit reproduction: до CSS height1542→767, после1542→1542,
  top insets0 во всех положениях; native regression использует titled window.
- **9 native PASS**, включая pan200/800/0, неизменные CSS/native viewport,
  prepared scale и split-pane geometry; runtime warnings/skips0.
- **1 installed Mac UI PASS**: открыть Sound → по ширине → wheel−120 → wheel+120.
  Три window PNG осмотрены: заголовок, рисунок, подписи и controls уходят вверх
  вместе на120pt и возвращаются к исходной композиции без сжатия. Не только AX.
- `source_inputs` рабочего дерева и snapshot совпали после проверки;
  `codesign --verify --deep --strict` и signature readback подтвердили artifact.

Evidence: `.build/gui250-scroll-projection/native/proof.json`,
`.build/gui250-mac-scroll-v18/{mac-build.json,native.xcresult,verified.json}`,
`.build/gui250-scroll-ui-v18/after.xcresult` и `attachments/`.
Первый CUA wheel не был доставлен (`noWindowsAvailable`); он не засчитан.
Успешный жест принадлежит exact-app XCTest, не синтетическому DOM событию.
Это закрывает конкретное расхождение бумаги/live содержимого при scroll;
системные FPS/p95, десять повторов и30мин остаются открытыми.

## 19 сентября, 17:19 МСК — GUI-242: реальная доставка 300 MiB в private Simulator

На смешанном диагностическом стенде Mac V17 / Simulator V16 подтверждена
настоящая доставка через account owner и TLS, без инъекции базы:

- Sound action `5706233e-3003-4809-8723-f68ddf8cf7a0` и актуальный large v3 action
  `2AF064DB-7071-4379-83F4-BD8E0DDB729B`: public `saved:confirmed`,
  `receivedByIPad:confirmed`, `sameActionVersion/sameRevisions=true`.
- Read-only проверка установленного Simulator-store: все **78 blobs** существуют,
  SHA256/размер каждого совпали. Всего **314581987 байт**, включая ресурс
  **314572800 байт (300 MiB)**, разбитый на75 частей по4MiB.
- `shownOnIPad:awaiting_display`: получение не подменяет показ, cold/offline UI
  ещё не принят. Encoder fix стоит на отправителе Mac; это не единый release cut.

Evidence: `.build/gui250-private-delivery-v17/{sound-receipt-after.json,large-current-receipt.json,large-simulator-bytes.json}`
и scoped TLS log. Production/физический iPad не затронуты.

## 19 сентября, 16:38 МСК — GUI-248: сжатие листа исправлено и проверено по пикселям

Установлен Mac-only private V17, immutable source
`86a0e2a55bc3cb4e563efa601ffd7fbacd74a0f12ab1454f12455c5b5c04825f`,
cdhash `5fff5350376fa7693ca33d2c0ce4e60c6c9934db`. Рабочие исходники и snapshot
совпали до/после; подпись приложения сохранена. Private store и manifest
побайтно сохранены при замене Mac. Production и физический iPad не затронуты;
Simulator остаётся V16. Это диагностический Mac-срез, не финальная новая пара.

- Прежний V16: усиленный UI сценарий FAIL уже на исходной сжатой геометрии,
  WebKit width 524 вместо ширины окна 1100. Это тот же установленный дефект,
  а не ошибка сборки; native отрицательная регрессия отдельно проверяет оба
  порядка resize и даёт 8 geometry failures на прежнем owner.
- Новый V17: все **6 SceneCameraPlaneTests PASS**, включая split-pane resize,
  pan settlement, native coordinates и raster projection; skips/warnings 0.
- Настоящий Mac UI: повторное открытие Sound → «По ширине» → «Рядом» → «Код» →
  «Показать лист»: **1 PASS**, skips/runtime warnings 0. Ширина белых пикселей
  бумаги до/после **1052 → 1052 pt** при окне 1100 pt; AX width/height также
  совпали. Обе оси текста и рисунка визуально осмотрены на PNG после возврата.
  Нормальная геометрия восстановлена; в «Рядом» нет дополнительного растяжения.

Evidence: `.build/gui250-mac-geometry-v17/{mac-build.json,native.xcresult,launch.json}`,
`.build/gui250-pane-geometry-ui/{before.xcresult,after.xcresult,provenance.json,paper-pixels.json}`
и четыре явных window PNG в `after-attachments/`. До исправления автоматические
failure attachments XCTest были pending; отрицательное доказательство — точная
ошибка width, native before/after и исходный screenshot Амира, не эти placeholders.

Этот результат закрывает горизонтальное сжатие при смене режимов. Живое
дрожание при scroll и системное frame pacing **не объявляются принятыми**:
последний сценарий не содержал scroll или системного измерения кадров.

## 19 сентября, 16:21 МСК — GUI-248: возврат из исходника искажает лист

Новый screenshot Амира после принятого source-pane сценария показал отдельный
дефект: при96% лист и текст сжаты по горизонтали примерно вдвое. Предыдущая
UI-проверка не проверяла возвращённую геометрию бумаги; её PASS не закрывает
этот дефект.

Воспроизведение на настоящем AppKit: frame1100/bounds572 → frame572 даёт
bounds297.44; возврат frame1100 после bounds1100 даёт bounds2115.38. AppKit
сохраняет уже установленный bounds transform, когда SwiftUI меняет frame после
updateNSView. Исправление у прежнего Mac SceneCameraPlaneView: размер bounds
вычисляется по фактическому frame; setFrameSize повторно применяет только
camera projection. UIKit не изменён.

Без Xcode runner выполнен scoped native probe: неизменённые тексты прежнего
и нового SceneCameraPlaneView + SceneCameraProjection, настоящий Core/AppKit/
SwiftUI, фиктивны только неиспользуемые model register/unregister callbacks.
Новый repo-тест выполняет оба порядка layout, восемь изменений ширины и held
scale. Прежний owner:8 geometry failures; новый owner:0, одинаковый масштаб
обеих осей. Evidence `.build/gui250-pane-geometry-native/`. Первый probe имел
неверный NSButton fixture (intrinsic height24); заменён обычным NSView96×96,
продуктовые проверки не ослаблены. Это native geometry evidence, не установленный
Mac UI. UI regression теперь задаёт fit width и проверяет width/height до и
после «Рядом»/«Код», сохраняет screenshot возвращённой бумаги. Новая правка ещё
не установлена; Xcode/установка ожидают завершения GUI-259.

## 19 сентября, 16:13 МСК — GUI-248: «Рядом» и «Код» приняты на установленном Mac

V16 immutable source `2f48105d25c6dcea9609d6b722e3cb92f3711a624097af006852a2ef8671a8cc`
собран и установлен в private stand, stores/manifests сохранены. Во время сборки
рабочая ветка продолжилась transport fix и test-only setup, поэтому
`workingTreeUnchanged=false`; неизменность самого source snapshot проверена.
Этот development artifact не объявлен финальным интегрированным выпуском.

Настоящий Mac UI: открыть точную Sound обложку → «Рядом» → «Код» → «Показать лист».
**1 PASS**, runtime warnings/skips0; обе window screenshots осмотрены: полная
высота панели, toolbar сверху, нет горизонтального разделителя через сообщение,
вертикальная граница только рядом с листом, no-op find/undo скрыты. Пиксели
интерактивного Sound также видны рядом с исходником. Адрес документа/приложения
заданы явно, production не затронут. Уточнённый test-only runner собран отдельно
из одного существующего Mac UI test source, не пересобирает и не заменяет app;
хеш app до/после одинаковый. Evidence: `.build/gui250-v16-source-pane-ui/`,
`ui-v2.xcresult`, `provenance.json`, две PNG в `attachments/`.

Прежние13 native Mac tests относятся к pan/prepared-scale/bookmark/account
срезу до последней визуальной правки разделителя. Это не измерение дрожания:
повтор CUA scroll остановлен ошибкой ScreenCaptureKit3811 до жеста. Системные
кадры, p95 и живой scroll остаются открытыми. Xcode передан GUI-259 в16:12:38МСК.

## 19 сентября, 16:02 МСК — GUI-242: ограниченный chunk переполнял JSON frame

Private TLS уже соединяет обе стороны, но повторно обрывается с `frameTooLarge`.
Foundation JSONEncoder экранировал `/` внутри Base64: chunk184320 байт0xff
превращался в491522 байта против frame limit262144. Read-only аудит private
store нашёл реальный blob `bae5dcd2294168324c3f3acf9662ad73568f89ad77d95f2fe8c456ecb27bf65e`
(768044 байта) с JSON chunks269009–273988 байт до envelope.

`NotebookTransportFraming` теперь не экранирует необязательные slashes;
обычный JSON, Base64, TLS, лимиты и decoder сохранены. Отрицательная Core
регрессия воспроизвела ошибку на0xfe/0xff. После правки3 byte-cases и durable
offer PASS (`.build/gui250-transport-frame-red.log` / `-green.log`).
Commit `2da169c` отправлен. V16 snapshot был создан до этой правки;
installed delivery/офлайн не подтверждены.

## 19 сентября, 15:33 МСК — GUI-250/248: Sound lifecycle и новые замечания к Mac

На установленном V14 заново опубликованы штатным private MCP все девять
научных программ; все девять PNG exports имеют status saved. Каталог адресов и
hashes: `.build/gui250-live-corpus-v14/catalog.json`. Это текущий e6bc stand,
не прежняя копия пространства и не доставка в Simulator.

Sound `98001c01-bd25-4112-90fc-591c72667a5c`: настоящий CUA Play/Pause,
сохранённая human revision1 phase `0.5221666666666686`; после выхода и поиска/
reopen программа остановлена, та же фаза и public state stamp. Сравнение
`paused-state.json` / `reopened-state.json` совпало полностью. При fit width96%
осмотрены частицы, связанная точка давления, подписи и доступные controls.
Это lifecycle/state сценарий, не frame pacing или reference-quality PASS.

Затем Амир сообщил дрожание документа при scroll и прислал пустую полосу
«Нет текстовых блоков» в режимах «Рядом»/«Код». Read-only AX установленного V14
подтвердил toolbar по центру окна, а не сверху. Candidate растягивает source
pane по высоте, объясняет отсутствие текстового исходника и убирает неработающие
кнопки. Mac pan settlement сохраняет существующую native projection, не
переносит весь SwiftUI/WebKit subtree при каждой паузе колеса; readiness replay
не публикует промежуточные reading positions во время движения. Prepared scale
остаётся закреплён за прежней камерой до завершения zoom.

Source `932dc150e1ac3e06bced29f39124740fb16f57a2ebd78cc175ddb2723dc4a08e`:
**13 Mac PASS**, runtime warnings/skips0,
`.build/gui250-scroll-source-account-native-v2/`. Первый прогон:11 PASS/2 FAIL
из-за неполного layout fixture (отсутствовал обязательный sourceOffset) и
игнорирования pixel rounding в начальной позиции SwiftUI marker; production
checks не ослаблены, точное равенство moving/settled frame сохранено.
V15 установлен с сохранением stores/identities. Первый UI attempt
`33a38db4-c35d-4c21-b071-c9c5f11a3ead` не переключил режим: системное окно
прервало XCTest. Это не результат проверки pane. После обычного перезапуска
CUA переключил «Рядом», «Код» и «Показать лист»: toolbar сверху, пустое состояние
занимает всю высоту, неработающие действия отсутствуют. В живом рендере найден
ещё старый горизонтальный Divider, пересекающий сообщение; следующий candidate
заменяет его вертикальной границей только в режиме «Рядом». Дрожание пока
не объявлено устранённым. Driver routing:81 PASS, `.build/gui250-source-pane-route.log`.

Для private Mac/Simulator подготовлена только подмена CloudKit account service:
два синтетических actor ID и один случайный256-bit pair key принадлежат run.
Реальные NotebookAccountConnection, device-only Keychain, TLS и доставка остаются
прежними владельцами; production bundle не принимает этот manifest. Нет доступа
к пользовательскому iCloud, production workspace или ключам. Native проверки
охватывают roles/actors, общий credential обеих сторон, стабильность reopen и
отказ при foreign account/stale key. CLI bootstrap также проверен в новом
временном каталоге: одинаковый ключ, разные actors, manifests0600. Текущий
V15 использует эту фикстуру на обеих сторонах. Наблюдается настоящая передача
blobs в отдельный Simulator, но публичная квитанция Sound в15:51МСК всё ещё
`receivedByIPad:awaiting_device`, `shownOnIPad:awaiting_display`; доставка и показ
не объявлены подтверждёнными. Физическая пользовательская пара не изменялась.


## 19 сентября, 15:06 МСК — GUI-250: настоящий Mac control → saved → reopen принят

Private V14 построен без изменения исходников, source
`447bc76ed3219f70764151bd798c58ef371a1a5b026ec7f1da1e96c1c3fbcef0`,
и установлен с сохранением stores/manifests. `.interactive-fragment` располагается
над canonical paper hit regions: отрицательная WebKit-регрессия до правки
попадала в пустой `section`, после правки — в iframe на44/100/150%.
Native **6 PASS**, runtime warnings/skips0 (`.build/gui250-webkit-projection-mac-v8/`).
Нативный host получает projected frame без изменения собственных bounds;
WebKit единожды проецирует канонический CSS через pageZoom.

UI attempt `271685cc-e7dc-413c-b399-78fcae2ddc8f` **PASS**:
настоящие click/клавиша → изменение range0.75→1.05 → назад → reopen1.05.
Public MCP независимо прочитал human state `{delta:1.05,time:0.2}`, revision2.
После reopen CUA получил `pointerdown/pointerup/click` с `trusted:true`;
настоящее перетаскивание изменило delta1.05→1.5 и график. Системное окно
не читалось и не обходилось; обычная XCTest activation снова доступна.

Повтор исходного, неинструментированного документа сначала не дошёл до zoom
(attempt `c36d4943-d726-4331-802f-d858b98a30ad`): диагностическую обложку я создал
поверх исходной. Обложки разнесены штатной адресной MCP-транзакцией
`3734889D-82E3-4961-8D1A-AA994E186FF8` только в private stand. Затем CUA
открыл исходный `034341cb-727d-5646-a0f3-ecc670225e74`, изменил0.75→1.05,
вышел и открыл снова:1.05 сохранилось; public read подтвердил human revision2.
Evidence: `.build/gui250-private-author-v14/`, V14 run/xcresult и
`.build/gui250-v14-original-ui-attachments/`. Это реальная приёмка данного
Mac сценария, не всех слайсов, не paired delivery и не system performance.

Отдельный следующий candidate передаёт WebKit именно prepared camera scale,
а не mutable current во время held gesture. State echo под активной камерой
не должен масштабировать бумагу дважды. Source
`3f85c25a8eb77eb70b62939a715e75e07fec12f25aa9f6e953d1d1db76bf1fcf`,
native **7 PASS**, warnings/skips0 (`.build/gui250-webkit-projection-mac-v9/`);
эта дополнительная правка ещё не установлена. Xcode уступлен другому targeted
физическому прогону; свои Xcode runners завершены. GUI-240/250 остаются In Progress.

## 19 сентября, 14:49 МСК — GUI-250: idle feedback устранён, найден отдельный browser hit defect

Installed private V13, source
`91e21c74139a82e413fc9f5e3a746c16720885afc57a709b14e3602bba4bc8d5`,
`workingTreeUnchanged=true`, сохранил stores/manifests. Тот же статичный документ
теперь даёт наблюдаемые ps CPU0.6–1.6%, вместо постоянных около100% V12.
Это scoped idle observation, не p95/FPS/GPU gate. Причина: readiness replay
изменял SwiftUI state-счётчик, а затем повторно публиковал nil selection/status.
Счётчик остаётся у прежней поверхности как не-observable reference, модель
очищает только непустое значение. Native observation regression +5 смежных
проверок —6 PASS (`.build/gui250-webkit-projection-mac-v7/`), warnings/skips0.

Ввод ещё не принят: CUA click/ArrowRight не дал события. UI attempt
`0081eca0-8f08-4631-820e-6666c0829c96` не активировал приложение и остановился
до жеста; его нельзя выдавать за проверку ползунка. ScreenCaptureKit затем
не смог снять окно; системный UserNotificationCenter недоступен CUA по политике,
его не обходим. Независимая настоящая WebKit-регрессия
`.build/gui250-browser-hit-red/mac.xcresult` показала конкретную причину:
`document.elementFromPoint` возвращает пустой canonical `section.block.interactive`,
а не iframe. Следующая правка поднимает только интерактивные фрагменты над
каноническими hit regions, без замены runtime или синтетического ввода.

## 19 сентября, 14:32 МСК — GUI-250: geometry PASS не закрыл живой layout loop

После `498d480` установленный Mac остался непригоден для приёмки ввода.
CUA выполнил настоящий click, ArrowRight и drag по видимому range при44%,
затем click/ArrowRight при100%; отдельная программа, опубликованная штатным MCP,
не получила даже pointerdown (`Input probe: no events`). Её ID
`f466679f-36a9-4521-a923-f23c5c50ebbf`, package
`6d2956cac8553d1bbbd177a24110f2789c5fa88b67890dc896ef187c5a32c554`.
Документ сохраняет модель биений, журнал только наблюдает реальные события.
Исходный authored документ не заменялся. V9 attempt `415079ab-df7c-4bb3-8d6a-62313b101737`
не дошёл до range: XCTest потерял открытое menu. Это не новый результат ввода.

На статичном листе обнаружен постоянный CPU около одного ядра. V10
`c9df66724eea10c652847ed9061e68abae28f24ad49aa8d8485dae17743cc55d`
с projected reading frame также не исправил проблему: UI attempt
`78f89e31-c1bb-40b1-b71c-34dfca4df734` не получил event-loop idle за60s и был
явно прерван. Read-only LLDB stack показывает main thread внутри
SwiftUI/AppKit fitting и AutoLayout. Это диагностические наблюдения, не system
performance gate. `sample` завис на symbolication и остановлен; результата нет.

V11 (`6d445dd7442b0ae094110e9158495cf9ba3690a8ffb6400e87bb2f5bb6439926`)
убирает изменение representable bounds из setFrameSize и сообщает SwiftUI
нативный размер без WebKit intrinsic fitting. Native **5 PASS**, warnings/skips0
(`.build/gui250-webkit-projection-mac-v5/`), но installed idle CPU по-прежнему
около100%, интерактивный слой не готов. V10/V11 upgrades сохранили оба stores и
manifests; их private Mac процессы остановлены, чтобы не занимать CPU. Debugger
отключён. Физическая пара не затронута.

V12 (`12a210a8e06b26be95ff252efd102de0c9a50ce50250efa9a3f90b3ca1401a34`)
с не-observable controller revision прошёл пять native checks, но оставил
CPU около100%. Read-only LLDB breakpoint подтвердил живой повтор
`MacDocumentSurface.onRenderReady(true) → acceptDocumentPageLanding`;
снимок стека — `.build/gui250-control-probe/v12-landing-breakpoint.txt`.
Кроме счётчика, model повторно публиковал уже пустые selection/status, снова
инвалидируя SwiftUI. V13 не записывает nil поверх nil. Regression observation
и прежние пять проверок: **6 PASS**, warnings/skips0, source
`91e21c74139a82e413fc9f5e3a746c16720885afc57a709b14e3602bba4bc8d5`,
`.build/gui250-webkit-projection-mac-v7/`. Route **81 PASS**:
`/tmp/gui250-webkit-ui-route-v2.log`. Установленный повтор ещё впереди.
V12 private process остановлен, debugger отключён; upgrade сохранил stores и
manifests. GUI-240/250 не Done; geometry/native PASS не заменяет живой ввод.

## 19 сентября, 14:00 МСК — GUI-250: WebKit AX исправлен, ввод ещё не принят

Private development v9 собран на неизменном source
`2fe373dd6b0f0bee370aa9664be0fabab54931b3986da3a1cf39fa56ce6a6fec` и установлен
через прежний upgrade. Stores, manifests, runtime/identities сохранены.
Mac host переносит масштаб существующей камеры в `WKWebView.pageZoom`, оставляя
CSS viewport каноническим. Native **4 PASS**, runtime warnings/skips0:
`.build/gui250-webkit-projection-mac-v3/`; Release содержит прежние C/SDK warnings.
Route **81 PASS**: `/tmp/gui250-webkit-ui-route-v1.log`.

Installed read-only AX подтвердил range **271×15**, а не прежние613×33 при44%.
Нативный текст, формула и график видны в записи v9. Но реальный UI attempt
`eddcf2cf-1f88-4b8c-b65a-03741dc0c726` **не принят**: значение не изменилось.
После нажатий foreground также переключился в Codex; это не основание списать
весь сбой на окружение. Повтор `ab30d52a-ad03-4751-905b-f02f6ae83fe1` остановился
на активации окна: мой read-only debugger attach задержал приложение. Никаких
выводов о ползунке из этого повтора. Debugger detached; исходники, content/store
и trust через него не изменялись, UI events не синтезировались.

Read-only native hitTest в точке AX-центра вернул тот же `WKWebView`, что и
firstResponder; camera/background не забрали эту точку. Дополнительный native
прогон с настоящим SwiftUI scaleEffect: **5 PASS**, runtime warnings/skips0,
source `f61ef073631c167c760012cc4a83c5c46089a21fd52462c1a1090ff7cbe32e2a`,
`.build/gui250-webkit-projection-mac-v4/`. Он подтверждает native hit routing,
но не browser-level ввод. Исправление геометрии фиксируется отдельно;
незавершённый UI-сценарий и его foreground guard не входят в этот commit.
Evidence: `.build/gui250-private-author-v9/`, `.build/gui250-release-v9/runs/`.
GUI-240/250 и остальные обязательные installed/shared/system/reference gates открыты.

## 19 сентября, 13:25 МСК — GUI-250: установленная диагностика и отрицательный camera повтор

`3560ba4` установлен в private development v8, source
`291c8838776925686422245b2f7ac5c2b29eb05e82ea767da37b78c7e16b30ab`,
`workingTreeUnchanged=true`. Public export job
`838cc4c7-8dd8-41ca-8c5b-9259394ffb77` теперь сообщает `program_runtime_error`
с причиной `exportProgram: Error: Error: program_export_unavailable`.
Отказ без авторского контракта остаётся отказом, успешный артефакт не подделан.
Receipt: `.build/gui250-runtime-error-public/status.json`.

Сам upgrade обнаружил ошибку нового owner-lock selector: CLI передаёт `from_run`,
а не `run`. Upgrade теперь запирает Mac/Simulator назначения из `--build`;
регрессия использует настоящий набор CLI attributes. Route **81 PASS**
(`/tmp/gui250-upgrade-lock-route-v1.log`), реальный повтор upgrade сохранил байты
обоих stores и прежних manifests; runtime/identities остались прежними.

UI v8 снова **FAIL** на настоящем вводе range. Read-only AX подтвердил прежний
размер 613×33 при видимом масштабе 44%; преобразование только native camera не
решило WebKit AX. Эта попытка и её тест удалены из рабочего изменения, camera
возвращена к прежнему владельцу. Проверяется более узкий путь в Mac WebKit host;
его готовность ещё не заявляется. Запись/отрицательная квитанция —
`.build/gui250-release-v8/runs/e6bc2672-bf28-4ccc-bd74-3d6034146723/`.

## 19 сентября, 13:09 МСК — GUI-250: большой ресурс и понятный отказ exportFrame

Installed private v7 получил настоящий файл 300 MiB через обычный MCP staging.
WebKit прочитал и сверил 104 байта четырьмя HTTP Range запросами, включая границу
4 MiB частей и конец файла. Прежний отказ PNG вызван отсутствующим авторским
`notebook.exportFrame`, а не лимитом ресурса. После добавления явного static-raster
контракта PNG сохранён и осмотрен: SHA256
`7c392144f0d020554e912911a56cca89541fd7158b21805d1d7e179990a989be`.
Portable export содержит 77 частей (314574135 байт), все hashes проверены потоково;
обычный import создал `98249ce9-5d95-51e2-a3d8-7183264f44ed`, сохранил предыдущие
материалы и дал побайтно тот же PNG. Receipts: `.build/gui250-large-public/`.
Это локальный saved/exported roundtrip, не delivery, offline-device или memory gate.

Единственный native lifecycle bridge теперь переносит bounded author exception
в публичное сообщение ошибки, вместо теряющего причину WebKit localized error.
Требование exportFrame не ослаблено. Native export positive/negative и lifecycle
проверены вместе с camera regressions: **7 PASS**, warnings/skips **0**,
`.build/gui250-camera-diagnostics-mac-v4/verification.json`, source
`291c8838776925686422245b2f7ac5c2b29eb05e82ea767da37b78c7e16b30ab`.
Installed camera/control повтор ещё не принят; прежние UI FAIL не отменены.

Run Loops + Thread Activity + Hangs probe остановлен после 371.9 s финализации
5-секундной записи: live sample показывает работу CoreSymbolicationDT, trace
не открывается (`Document Missing Template`). `.build/gui250-runloop-probe-v1/`
содержит отрицательную квитанцию и sample; это не performance acceptance.

## 19 сентября, 12:43 МСК — GUI-250: независимая Mac identity и пустое назначение portable import

Mac acceptance application/UI runner получили стабильный суффикс checkout
`.acceptance.0eb64b772a19`; приложение и manifest обязаны совпадать целиком.
Старый stand не мигрирует и не получает доступ к новым ключам: создан fresh run
`e6bc2672-bf28-4ccc-bd74-3d6034146723`, workspace `5159ED05-BD8B-495C-A4D7-197C5F291AE7`,
без заранее выданного trust. iPad остаётся в Simulator
`3E0E27D3-C87A-40EB-B875-6D6571DC29D3`; физическая пара не затронута.
Driver locks теперь относятся к конкретному Mac bundle/Simulator, не всей машине.
Worker reseal проверяет точный attested bundle вместо двух hard-coded имён.

Проверки: route **81**, release **67**, Swift scope **8**, native launch **6 PASS**;
отдельный actual Codex scope probe **1 PASS**, без model turn/новой задачи.
Журналы `/tmp/gui250-checkout-identity-routes-v3.log`,
`/tmp/gui250-checkout-release-v1.log`, `/tmp/gui250-checkout-codex-v1.log`,
`/tmp/gui250-checkout-codex-live-v1.log`,
`.build/gui250-checkout-identity-mac-v2/verification.json` (source `801a7308…f31b`).
V6 выявил оставшийся hard-coded signer guard и не был установлен.
Development v7 собран и установлен: source
`e41ffa9206535a72895a0816c3eb0b2da1c752184cb5fc3b526b65436fbee286`,
Mac CDHash `84ff911b8afa6f9772b8cb58732e53ee09734fc6`.
`workingTreeUnchanged=false`: во время сборки исправлен accessor только в
opt-in Codex test; это диагностический build, не окончательный единый gate.

В пустое пространство обычным installed MCP импортирован прежний portable
пакет биений. Новый документ `034341cb-727d-5646-a0f3-ecc670225e74` даёт SVG
SHA256 `53680f9ed2aeb74ec3d4eb3e53e5743435c27e8698de45ddebc9dcbf3f7353bd`,
побайтно равный оригиналу; receipts в `.build/gui250-private-author-v7/`.
Это не delivery/Apple Account acceptance: pair trust ещё не разрешён.

Настоящий UI runner теперь запускает правильный process, но control test пока
**FAIL**: при масштабе 44% AX slider сообщает ширину 613 вместо видимых ~270 points.
Просмотрена запись v7; Native camera correction проверяется отдельно и пока
не принята установленным UI. CUA дополнительно не смог захватить Stage Manager
thumbnail вне экрана (`SCStreamError -3811/-3812`); это не успешная UI-проверка.
Public probe реального файла 300 MiB (75 различных частей по 4 MiB) успешно
staged/published, но PNG export вернул JavaScript exception; отрицательные
receipts сохранены в `.build/gui250-large-public/`. Large-assets acceptance не закрыт.

## 19 сентября, 12:05 МСК — GUI-250: нативный лист больше не скрыт под Mac WebKit

Живой public TS-документ биений выявил дефект, которого не показывал экспорт:
на Mac были видны график и controls, но заголовок, текст и формула закрывались
белым WebKit. `underPageBackgroundColor = .clear` не отключает его page backing.
В прежнем `DocumentWebViewFactory` включена та же прозрачность `drawsBackground`,
которую уже использует пространственный WebKit. Новый renderer не добавлен.

**Mac1 PASS**, warnings0/skips0,
`.build/gui250-native-paper-mac-v1/verification.json`: настоящий WK snapshot
имеет прозрачные pixels вне программы; background не подменяет native paper.
Source `ec55fa5be0fecf9da678e49ffda3100092ddaa0ad30ee4e0938b7fe784e4068f`.
Development Release этого source собран в `.build/gui250-release-v5`;
Mac CDHash `b829ecbf7312868a1635da79decc0b73b69ce17d`. Обновление private пары
`3af2d2e9-8bd0-47e9-baba-21b83ec1d6fa` сохранило store bytes, manifests и identities.
Установленный Mac реально открыт: заголовок, текст, формула и график теперь
видны одновременно при «Вся страница». До исправления — запись
`.build/gui250-mac-ui-v3/separated-covers-attachments/A95EDDD6-B27F-4EAA-98CA-83284C9F2147.mp4`
и просмотренный `native-paper-before.png`; после — осмотр CUA установленного v5.
Это подтверждает видимость, но не полноценную интерактивную приёмку.

Новый UI-сценарий пока **НЕ PASS**: исходные test-only проблемы (перекрытые
контрольные обложки, окно вне активного Space, нечисловая трактовка AX slider)
разобраны; обычным public moveItem обложки разведены. Последний keyboard/control
прогон не подтвердил изменение значения, дальнейшая диагностика открыта.
Попытки `.build/gui250-mac-ui-v7` и соответствующие отрицательные results сохранены;
существующий другой acceptance Mac не закрывался. Нельзя считать неудачу harness
доказанным дефектом ввода или заявлять accepted/reopened по одному screenshot.

Дополнительно: public MP4 job `356d0f32-9c40-443b-8294-98d24a86b841` отменён обычным
SDK и после v3→v4 restart остаётся cancelled, без artifact. Свидетельства
`.build/gui250-free-author/cancel*-receipt.json`. **78 route tests PASS**.
System-wide Host Blank/Display + GPU + Activity Monitor впервые завершили запись:
`.build/gui250-host-display-trace-v1/system.trace`, 5,837631 с записи, exit0,
непустые display/Metal/resource таблицы. Это idle/backend probe, не атрибутированные
кадры Notebook, не p95 сценария и не аппаратный iPad. Time Profiler probes остаются
отрицательными. Новые test-only ключи/trust не выдавались без ожидаемого отдельного
разрешения. GUI-240/250 и installed shared/performance/reference acceptance открыты.

## 19 сентября, 11:21 МСК — GUI-250: public Release, полный Core gate и короткий vector viewport

Isolated Release **3deac88**, source
`e24ca83eca9022b1db9ef12a2aab557d40e9a0020e8bf57d9493eb7e9a71e847`,
собран и обновлён в `.build/gui250-release-v3`; private Mac/Simulator store inventories
и прежние manifests сохранены. Mac CDHash `f2f8f5dbcf8551acc84c6c0afdf19eb3d38591cd`.
Установленный MCP по явному private socket создал новый TS-пример биений вне
рецептов и все девять научных программ. Исправление XPC signing-team identity
подтверждено настоящим createDocument, не только конфигурационной проверкой.

Биения: saved PDF/PNG/SVG/package/MP4 из одного cut
`f20dff31ba291a7046889dba7dcec1131b436024dd4b2c420dc379f076e9c789`.
PDF, PNG, SVG и декодированный последний MP4-кадр просмотрены; H.264 800×1132,
8 кадров/с, четыре кадра за 0,5 с с последовательной модельной фазой. Это частота
экспортного файла, не измерение производительности UI. Portable reimport обычным
SDK создаёт новый документ, SVG SHA совпал байт-в-байт
`53680f9ed2aeb74ec3d4eb3e53e5743435c27e8698de45ddebc9dcbf3f7353bd`.
Roundtrip выполнен в том же private store; не объявляется cold destination proof.
Standalone HTML saved, но интерактивное открытие блокировано политикой browser
инструмента; обходов нет. Все девять corpus PNG просмотрены; это канонические
сохранённые кадры, не принятые reference episodes и не shownOnIPad.

Public PDF signal при height=800 обнаружил дефект авторского recipe: он объявлял
векторную формулу вне прокручиваемого viewport. Native bounds guard правильно
отказал `invalid_export_vector`. Height=1600 подтвердил полное содержание;
теперь recipe ограничивает замену реальными viewport/ancestor scroll clips,
сохраняя частично видимый SVG векторным и не добавляя невидимые области. Native
admission не ослаблен. **JS3 PASS**, `/tmp/gui250-clipped-vector-js-v1.log`;
**Mac1 PASS**, warnings0/skips0, `.build/gui250-clipped-vector-mac-v1/verification.json`,
source `04ec01b871141bebe8c9c3cba03e25dae455efba725f54767e447f81592e5820`:
SVG выбранного отсчёта и реальные PDF высоты 800/1000. Новый package опубликован
тем же installed Release: короткий PDF теперь saved, SHA
`e8582fd4d6b9d35ae0b91becfeb559baf3a730a9f311b0b9b3642c9a218fdc65`,
просмотрен целиком. Свидетельства `.build/gui250-corpus/signal/clipped-*`.

Полный **Swift1125 PASS**, `/tmp/gui250-swift-full-v2.log`: suites 21+33+993+49+29,
exit0, Core 1054,459 с с 100k seeds. Компиляция и неизменные test binaries относятся
к **69d6a0c**, source `694a57f80cf511248421ad969cc39f9b71b05b196d322c6cdd17735a6e1ad4d3`.
Во время завершающих Core scale tests выше изменён только signal recipe/native
fixture; их проверяет отдельный новый Mac receipt, не прежний Swift результат.
Одна inherited Swift compiler warning о лишнем try; новых runtime failures нет.

System-wide tracing разрешён Амиром. Реальный Simulator Pencil/eraser scenario
runner завершился exit0, но вся traced attempt FAILED: xctrace не финализировал
trace. Отдельные auto-stop 5 с Simulator/host probes также зависли; host сообщил
`dylibs overlap`, sample указывает CoreSymbolicationDT, не deadlock Notebook.
Ни один partial trace не принят как системные кадры/CPU/GPU. Fresh test pair ещё
без trust, разрешение на test-only bootstrap ожидается. Поэтому saved/exported
не означает received/shown; 10 повторов, 30 минут совместной работы и reference
сопоставление остаются открытыми. Physical pair/Apple Account не изменялись.


## 19 сентября, 11:02 МСК — GUI-250: действующий lifecycle вместо старых fixture shortcuts

Отрицательные проверки полного Core прогона разделены по владельцам. Старые
тесты требовали физического удаления source, хотя causal undo теперь сохраняет
его за закрытым lifecycle gate. Они проверяют именно сохранность source, отказ
чтения/поздней записи и неизменный cursor. Повтор raw native birth без immutable
action ID явно отклоняется; retry исходного action ID и запрет второго lifetime
проверены отдельно. Addressed vision fixture теперь имеет настоящую каталоговую
принадлежность; повреждённый посторонний body не уничтожает нужный owner index.
Production правила и лимиты ради тестов не менялись.

Старые ink/graphic/connector fixtures переносили только values/actions, теряя
обязательные inverse blobs. Теперь используют общий прежний addressed delivery
helper; grouped cases проходят через relay snapshot, а не синтетическую смесь
без closure. Порядки, повторы, reopen и causal undo сохранены.

**17 Core PASS**, `/tmp/gui250-retained-contracts-v3.log`;
**9 guards PASS**, `/tmp/gui250-retained-guards-v1.log` (включая повтор action ID,
retired page и cross-owner admission); **6 replication tests PASS** с параметрами
и перестановками, `/tmp/gui250-replication-fixtures-v2.log`. Два предварительных
vision test compile errors (return dictionary / nested require macro) исправлены
в самих тестах. Новый source `694a57f80cf511248421ad969cc39f9b71b05b196d322c6cdd17735a6e1ad4d3`;
полный повтор ещё нужен.

## 19 сентября, 10:46 МСК — GUI-250: Release обнаружил чужой XPC sandbox owner

Неизменная Release-пара `ce3b979`, source
`ac5cb18e064c629e5497feb86b081d7f4e8577643f59db5af5218cd874ccde22`,
собрана в `.build/gui250-release-v2`; Simulator GUI-240 установлен, Mac
запущен с новым manifest/root/socket `3af2d2e9-8bd0-47e9-baba-21b83ec1d6fa`.
Установленный в этом bundle MCP импортировал новый свободно написанный TS
пример биений: 9639 bytes, package `a56fc444afaaaaffc127df00413ed30848b8874e4a5030e5d037f12740ec5a89`.
Создание документа **не прошло**, эффект notSaved / normalization_timeout:
`secinitd` показал до-main ACL mismatch markup-service `.acceptance-runtime`
между прежним VUNH73AYPY и текущим M94V58FCVP. Этот риск ранее обходился
одноразовым S10 suffix, но штатный acceptance builder оставался неисправным.
Теперь его единственный suffix включает проверенный signing team. Старые
контейнеры, ACL, production identity и данные не меняются. **77 route tests PASS**,
`/tmp/gui250-worker-identity-tests-v1.log`; повтор Release/public route ещё нужен.

На прежнем source дополнительно **Mac4 PASS**, warnings0,
`.build/gui250-integrated-mac-v1/verification.json`: SDK/XPC immutable cut,
mixed PNG, cancellation fence, одинаковый TS/JS writer. Это не отменяет
отрицательный public Release результат. Свежий app-scoped Time Profiler
реально начал запись и UI выполнил жесты, но xctrace завис при SIGINT;
`ipad-testSystemTraceAttachesToLaunchedApplication-*` **FAIL**, не performance
receipt. Амир разрешил system-wide capture с процессами host Mac; отдельный
повтор использует это явное согласие. Физическая пара не затрагивалась.

## 19 сентября, 10:33 МСК — GUI-250: UUID alias сохраняет владельца source edit

Native source reader уже адресовал UUID независимо от регистра, но общий action
executor затем искал update/remove/insert-anchor по исходной строке. Поэтому
правильный CAS мог закончиться target_missing. Исправлен именно общий document
оператор: lookup использует прежний collaborationIdentity/memberIdentity, ID
сохранённого блока не переписывается; второго пути native сохранения нет.

**Core10 PASS**, `/tmp/gui250-source-identity-core-v1.log`: source CAS/drafts,
конфликт, независимый блок, перезапуск/undo, UUID update, отказ duplicate spelling,
remove через alias и undo с исходным ID. **Simulator1 PASS**,
`.build/gui250-source-identity-sim-v1.xcresult`: сохранение независимого native
текста оставляет тот же program heap и unsaved DOM; warnings0/skips0.
Source `ac5cb18e064c629e5497feb86b081d7f4e8577643f59db5af5218cd874ccde22`.
Не считается закрытием остальных отрицательных результатов полного прогона
или installed/shared acceptance; физическая пара не менялась.

## 19 сентября, 10:29 МСК — GUI-250: dependency admission и интеграционные расхождения

Первый full MCP run: 147/151. Три scientific/native fixture содержали устаревший
`notebook-build.json` (bridge identity); generated JS/worker/assets уже совпадали.
Они пересозданы прежними генераторами. SDK types test теперь находит pinned tsc
от своего модуля, не от cwd; root invocation больше не даёт ENOENT.
**Full MCP151 PASS**, `/tmp/gui250-mcp-full-v2.log`; отдельные compiler/science/SDK
**20 PASS**, `/tmp/gui250-fixtures-js-v1.log`. Нативная начальная справка теперь
называет MP4 и saved/presented, а не устаревший список форматов.

Full Swift run на 9729c7e не принят: выявлены несовпадения старых тестов с API2,
22 operations/26 KiB discovery, DB12 и manifest11. Они приведены к действующему
контракту (лимиты продукта не изменены): **Host2/Core17 PASS**,
`/tmp/gui250-contracts-core-v2.log`. Первый целевой запуск не скомпилировал
новую test-only проверку из-за внутреннего JSONValue API; исправлено без
изменения production contract.

Прогон нашёл и настоящий GUI-242 regression: package dependency discovery
декодировал document block до прежнего admission 4096 fragments/16 MiB. Теперь
discovery и source merger используют один bounded SQL metadata gate до первого
body decode. Initial-state children не сканируются как package owners. Проверки
oversized и слишком дробного повреждённого тела отклоняют discovery/delivery до
decode; прежние большие package closure/retry/offline правила сохранены.
**Core8/Host2 PASS**, `/tmp/gui250-admission-core-v2.log`.
**Simulator3 PASS**, `.build/gui250-admission-sim-v1.xcresult`: compiler package,
real offline 3D resources/recovery и worker/media/checkpoint через native owners;
warnings0/skips0. Source `790b0b14d9dd97922294309795143a91311bb71c66bc8c060d30436eabfb0843`.

Full Swift ещё не PASS: сохранены отрицательные результаты в
`/tmp/gui250-swift-full-v1.log` (retained deleted sources, старые domain transfer
fixtures без inverse blobs, UUID source edit, projection retry, PageVision,
late computation). Core runner остановлен после получения этих ошибок во время
100k нагрузок, остальные targets закончили; незавершённая нагрузка не считается
PASS. Первая Release сборка `.build/gui250-release-v1` явно остановлена после
выявления integration дефекта; ничего из неё не установлено/не принято.
GUI-250/240 остаются In Progress, физическая пара не изменена.

## 19 сентября, 10:17 МСК — GUI-249: frozen model связан с настоящим capture

Native document owner добавляет optional program proof только при явной
attention pause: тот же sourceVersion, принятый checkpoint, frozen runtime и
пересечение выбранной области с установленной программой. Running frame по-прежнему
даёт только pixels, не воспроизводимую модель. Resume не меняет captured state.

Presented SVG/HTML/PDF/package/MP4 используют прежний isolated export owner с
этой моделью; export не делает нового checkpoint, commit или live seek. Exact
PNG остаётся исходными байтами. Whole-document/page PDF/package/video отказывают
при других interactive blocks без frozen proof; selected SVG/HTML допустимы.
Это не выдаёт saved соседей за shown и не обещает восстановить произвольный heap.
Static paper фиксируется полным source/state cut при admission; прежний CAS,
immutable evidence, streaming, cancellation и artifact publication сохранены.

**Core20 PASS**, `/tmp/gui249-frozen-model-core-v1.log`: все пять model formats,
missing/wrong source/state/block proof, multi-program refusal, stale admission,
старый exact PNG и artifact preservation. **Mac2 PASS**,
`.build/gui249-frozen-model-mac-v1/verification.json`, source
`c87bf0ad942d2cc00bff6fab2ab3be4d3cab113efd3cc792473bc88a14e8cade`:
настоящий native publication PDF/SVG/HTML/package/MP4 от fixture evidence, phase
0.25, preserved cut/source/state/cursor, MP4 duration, прежний exact PNG.
Fixture не объявляется настоящим захватом: **Simulator2 PASS**,
`.build/gui249-frozen-model-sim-v2.xcresult`, final source
`78ef9f51ae025985bfa876f21f69429c14c07f92ff85d20b47527b3279df210d`:
реальный document capture blue phase0.5 связан с checkpoint; runtime затем red
phase0.75, evidence неизменно. Running capture с явно указанным blockID не
получает model proof. Разница с Mac source — только усиление этого негативного
Simulator assertion. Оба native runs: warnings0/skips0. **SDK3 PASS** и generated
check PASS (`/tmp/gui249-frozen-model-js-v1.log`).

Это законченный проверенный development-срез, не full GUI-249/250 acceptance.
Далее — точная isolated Release пара, installed/public route и системные
измерения. Пользовательская физическая пара не менялась.

## 19 сентября, 10:04 МСК — GUI-249: точный presented PNG из настоящего capture

`nb.export(...,{format:'png',moment:'presented',attention:{contextID,referenceID}})`
публикует неизменные PNG bytes выбранной области. Native installed document
owner добавляет captureID/time/platform только при foreground capture текущей
готовой поверхности; iPad и Simulator различаются. Cached/regenerated source
pixels такой provenance не получают. Existing attention/context delivery
переносит те же pixels/provenance; нового transport/executor нет.

Один WAL cut связывает source/state + exact immutable attention. Export не
запускает WebKit/typesetter, не checkpoint-ит/перематывает live, не читает cache,
не увеличивает/снижает разрешение. Optional pixelWidth только подтверждает actual
capture extent. Native publication проверяет исходный PNG hash/length, matching
attention и прежний source/state CAS; status/restart сохраняют moment=presented.
Старое evidence без provenance и попытка назвать saved cut показанным — отказ.

**Core19 PASS**, `/tmp/gui249-presented-core-v2.log`: native provenance required,
exact bytes, cut identity, extent refusal, stale admission/publication, prior
artifact preservation, прежняя source evidence/semantic validation.
**Mac2 PASS**, `.build/gui249-presented-mac-v1/verification.json`, source
`32ecf7cfda9d7890a6639cc617ec46efbfe08e17b3b5de3d5791bd26b08622a0`:
экспорт fixture evidence сохраняет bytes/state и число WebKit; saved PNG также
работает. Это не поддельное доказательство захвата iPad: capture проверен отдельно.
**Simulator4 PASS**, `.build/gui249-presented-sim-v2.xcresult`: реальный установленный
document owner замораживает blue frame, поздний DOM red не меняет отправленный
PNG/captureID; hidden/detached/clipped отказы и один resource owner. Финальный
source `f63b4c4357e65ae6f0e1a5d10530d93385be413cc3d1c2abc574b3d84bb78965`
отличается от Mac-квитанции только удалением ошибочного лишнего аргумента в
`#if os(iOS)` raster-transfer call (первый Simulator build честно не прошёл).
**SDK3 PASS**, `/tmp/gui249-presented-js-types.log`, generated check PASS.
Попытка sdk-snapshot integration не запускала проверки: отсутствовал изолированный
IPC test host; она не входит в PASS и не является installed MCP acceptance.

Presented пока сознательно PNG crop: другие форматы используют saved model,
а не притворяются восстановлением произвольного показанного heap. Расширение
paused model/PDF и installed/shared/system GUI-250 ещё впереди; GUI-249/240 не Done.
Физическая пара не изменена.


## 19 сентября, 09:53 МСК — GUI-249: Plot и MathJax остаются векторными внутри PDF

PDF использует тот же canonical layout и потоковый Quartz compositor. Автор
может объявить vectors:true и вернуть непересекающиеся SVG replacement regions;
native проверяет закрытый SVG, локальные границы/пересечения и лимиты. Один
существующий data-only SVG kernel типовщика конвертирует регионы; второй PDF
renderer/layout не добавлен. Raster под регионами исключается, перенос через
sourceOffset/clip сохраняет геометрию нескольких страниц. Canvas/WebGL остаются
кадром точного saved cut при 300 DPI физического листа, независимо от дисплея.
Векторные buffers учитываются в прежнем resource pool (<=8 МиБ/page).

Реальный signal экспортирует Plot и MathJax glyph paths; Canvas overview остаётся
raster. Финальный A4 PDF осмотрен: sample37125/37.125s, исходные50отсчётов,
формула min/max0.273/0.558, подписи/цвет/обрезка сохранены. PDF содержит selectable
Plot glyphs (встроенный Libertinus Sans, не зависимость от системного шрифта),
векторные paths MathJax, растровую часть2481×3509. PNG-preview самого PDF:
`.build/gui249-vectors-preview-v6/7F61AFBA-5B06-498F-BD37-C95AF80F3DCD.pdf.png`.

Проверки:
- **Mac4 PASS**, `.build/gui249-vectors-mac-v6/verification.json`, source
  `aac4f443d9e1485d3da9a7ecc843b4d58e1b71bb9bcc234e9421d7026945fdea`:
  реальный Plot/MathJax, две canonical страницы с разными vector regions,
  прежние SVG/PNG/JPEG image assets, saved vs live raster + PDF text/links.
- **JS22 PASS**, `/tmp/gui249-vectors-js-final.log`: opt-in, copied data,
  limits/finite bounds и отказ объявленного повреждённого экспорта.
- **Simulator1 PASS**, `.build/gui249-vectors-sim-v2.xcresult`: offline
  Plot/MathJax/ranges/checkpoint; source предыдущего native v5
  `ab173e9014b03e15062d81eaf9e4b410cd34fd60cbbbaf7c27f8cf9c5faca323`.
  После него изменены Mac-only PDF DPI, комментарий/whitespace; iPad code и
  signal fixture не менялись. Runtime warnings0, skips0.

Отрицательный v2/v3 не скрыт: MathJax data-latex содержал TeX escapes,
запрещённые passive validator. Рецепт теперь удаляет служебные data attributes,
не ослабляя валидатор. XCTest маскировал ошибку как InvalidTransition; явная
диагностика показала invalid_export_svg. Тест цветовой области скорректирован
по фактическому color-managed RGB; y1400 действительно лежит на второй странице,
в отличие от ошибочного ожидания для y1150. Product layout не менялся ради теста.

Presentеd cut и installed/system acceptance GUI-250 остаются открытыми.
Физическая пользовательская пара не изменена; GUI-249/240 не Done.


## 19 сентября, 09:32 МСК — GUI-249: restart не теряет смысл export job

При переходе queued/running → interrupted прежний export owner теперь сохраняет
cutSHA256, source/state revisions, moment и options (включая video timeline).
Не создаёт пустую карточку вместо исходного задания, не повторяет исполнение.
Core22 PASS, `/tmp/gui249-restart-core-v1.log`: повторный restart неизменен, saved
и cancelled receipts не повреждаются; scoped storage-only проверка, не новая
установка или GUI-250 acceptance.

## 19 сентября, 09:28 МСК — GUI-249: детерминированный MP4 из авторской модели

MP4 использует выбранную canonical страницу, тот же isolated coordinator и
source/state cut. Явные blockID/width/start/end/FPS; одинаковый saved model/seed
передаётся для каждого time=start+index/FPS. Автор подтверждает timeline:true;
без seek-capability нет фиктивного фильма из startup frame. H.264, без audio,
чётная ширина128…4096, высота листа дополняется белым до чётной, диапазон[start,end),
1…60 FPS/1…3600 целых кадров. Нет live rewind, массива кадров или PNG sequence.
Off-main AVFoundation receiver даёт backpressure; один кадр в работе, raster и
conversion buffers допущены прежним пулом. Ошибки/отмена не доходят до saved,
адресная V2 публикация/финальный CAS прежние. Sound/linear используют свои seek;
gears период16 s, wave прежний Worker от accepted/seed, media decoded seek.
Выход за диапазон численной модели/записи — ошибка, не скрытый clamp.

**Mac4 PASS**, `.build/gui249-video-mac-v4/verification.json`, source
**e4e9e7e49ffb36b716753cfd5e9e36faeecd2781ccbf11c4ca179bf24af324bc**:
настоящий опубликованный MP4640/4FPS/1s декодирован покадрово; фазы red/blue/blue/red
совпали, duration/FPS/extent/audio проверены, source/state неизменны. Отмена
во время работы isolated renderer/encoder освобождает WebKit и сохраняет прошлый
файл. Настоящий звук-пример экспортирован900px/12FPS/6s; gears/wave получают
offset0.5 и показывают10.5s/0.750s без commits. Прежний exact raster PASS.

Файл `.build/gui249-video-preview/730E9970-72A4-443B-AB61-3C510A9B6C4E.mp4` и
четыре PNG из v3: осмотрены фазы0/.25/.5/.75 — облако сохраняет частицы,
оранжевая частица движется вперёд/назад, давление соответствует фазе; заголовок,
композиция и controls остаются на canonical листе. Видео не объявлено системным
FPS-измерением и не заменяет reference-motion acceptance GUI-250.

**Core14 PASS**, `/tmp/gui249-video-core-v1.log`: timeline validation/header/CAS,
нецелое число кадров и неверный MP4 отвергаются, prior artifact цел. **JS36 PASS
+ generated check**, `/tmp/gui249-video-js-v4.log`: timeline opt-in, повторное
absolute seek, models/seed и typed API. **Simulator2 PASS** в двух независимых
от Mac прогонах: v1 шесть inline checkpoint, v2 Worker/media обновлённого package,
`.build/gui249-video-sim-v2.xcresult` на final source. Физическая пара не изменена.
Первый native run имел реальные Performance Diagnostics: synchronous codec
работа на UI actor. Устранено одним off-main encoder owner; последующие прогоны
без runtime warnings. Старый JS runtime fixture не знал exportFrame; исправлен
сам fixture, добавлена проверка seek, контракт не ослаблен.

Открыты presented cut, сохранение доступных интерактивных векторов внутри PDF
(отдельный SVG уже векторный), installed/shared/системная приёмка GUI-250.
Весь GUI-249/GUI-240 не Done.

## 19 сентября, 09:13 МСК — GUI-249: переносимый документ без исполнения при импорте

format=package публикует NotebookPortable/1: точный cut + исходные V2 manifests
+ уникальные `blob-<sha>` в одном атомарном каталоге. Целый каталог переносится;
`submit.mjs document.package` использует прежний native importer, затем одну
createDocument транзакцию, со стабильными retry/run/document IDs. Нет npm,
сборки больших файлов, Base64/asset bytes в IPC, второго хранилища или renderer.
Импорт сохраняет значения моделей (включая явный null), но не чужие clocks,
selection или камеру. Код запускается только при явном открытии. Авторский
inline/source layout транслируется в строгие варианты прежнего SDK, не в
новый формат редактирования. Deadline recovery возобновляет тот же run и
дренирует queued/running/output; не повторяет принятые действия.

**Mac3 PASS**, `.build/gui249-portable-mac-v2/verification.json`, source
**8297a76cb89e5dcdac2b0390eb51da5bd0d374ca897874b20898dd4aff2fa588**:
настоящий signal package экспортирован и перенесён в отдельный store через
NotebookProgramImporter.partPaths. Все файлы/parts/hash совпадают; экспорт
не изменяет source/state, импорт bytes не открывает WebKit и не меняет index.
После явного открытия реальная offline программа показывает sample37125 и
восстанавливает center37.125. Прежний 64 МиБ file import, FIFO responsiveness,
cancel/retry/cold status также PASS. **Core13 PASS**,
`/tmp/gui249-portable-core-v1.log`: каталог с **36 МиБ уникальных байтов**
(9 разных 4 МиБ частей), полный SHA, missing closure, prior artifact и CAS/cancel.
**JS7 PASS + generated check**, `/tmp/gui249-portable-js-final.log`: один typed
createDocument, no code execution, null state, bad metadata/symlink, cancel,
response_pending/retry/resume. Это transport-boundary JS test, не установленный
end-to-end MCP импорт. **Simulator1 PASS**,
`.build/gui249-portable-sim-v1.xcresult`: compiled package offline + checkpoint
в обоих владельцах; source a20fe433b645838770f05a564ce028f3c2c6413aa7a3099899a0fb7ae2b1e5b5,
от финального native tree отличается только исправлением UUID в JS test fixture.
Первый strict-schema JS check выявил некорректный test target='root'; исправлен
на UUID без ослабления схемы. Mac и Simulator независимы; физическая пара цела.

Не закрыты: presented cut, deterministic video, интегрированный installed/shared
маршрут GUI-250 и системные измерения. GUI-249/240 не Done.

## 19 сентября, 08:53 МСК — GUI-249: автономный offline HTML

format=html + blockID публикует выбранную inline программу с точным saved state
через прежний cut/V2/CAS/cancel owner, без typesetting и запуска кода при экспорте.
Готовый файл открывается без Notebook, npm и server. Тот же NotebookProgram/1,
opaque sandbox iframe, CSP закрывает network, parent/file-origin, frames/forms.
Изменения внутри HTML локальны; writer Notebook туда не передаётся. Modules/assets
package не притворяется file://-совместимым HTML: export_portable_required.
Standalone ограничен 8 МиБ; переносимый пакет остаётся отдельной незавершённой
частью этого же слайса.

**Mac3 PASS**, `.build/gui249-html-mac-v6/verification.json`, source
**ef7c24ad9b2709ddb2291da93b4daf6e4223fa0b242260065eb83d3c72946171**: настоящий опубликованный HTML
звук-модели загружен с file://, saved phase0.625, кнопка +¼ даёт0.875; настоящий
SVG имеет >20 элементов; CSP блокирует fetch и доступ к parent; shared state
не изменился. Прежние real SDK PNG и durable cancellation PASS. Файл и screenshot
экспортированы из v5, где модель работала, а проверка ошибочно читала range-control
с шагом0.002 вместо model state. Просмотрена композиция: облако частиц, выделенная
оранжевая частица, кривая давления, controls и объяснение.
`.build/gui249-html-preview-v5/8D9D7805-E501-4C4E-85A4-2C10B455DC6B.html`;
`.build/gui249-html-preview-v5/9AECD065-2D6E-4803-B4E8-9D8D1A9A07AE.png`.
**Core12 PASS**, `/tmp/gui249-html-core-v4.log`; **SDK3 PASS+generated check**,
`/tmp/gui249-html-js-v2.log`; **Simulator1 PASS**,
`.build/gui249-html-sim-v1.xcresult`: compile/install/lifecycle общего bridge.

Первая fixture использовала исходный pre-save document/state вместо принятого
WAL cut; после чтения настоящего cut публикация корректна. Спекулятивные изменения
filesystem/lifetime, не устранявшие этот сбой, удалены. Native publication fence
не ослаблялся. Presented/portable/video/GUI-250 остаются незавершёнными.

## 19 сентября, 08:39 МСК — GUI-249: точный authored raster вместо startup кадра

PNG/PDF ждут exportFrame(format=raster,state,pixelRatio) после author pause,
в отдельном executor. Rasters admitted до callback; общий native capture остаётся
владельцем пикселей. Без callback — явный отказ, не случайная фаза. Callback error
возвращается одному export caller, не одновременно в display invalidation.
Signal рисует целевой Canvas/Plot, Three — выбранную фазу/камеру в целевом GL
backing, wave ждёт accepted Worker result и decoded/seeked muted recording.
Шесть inline scientific scenes используют тот же render, без второго движка.

**Mac6 PASS**, `.build/gui249-raster-mac-v4/verification.json`, source
**7a3c3b5a544c9ea45dbf11ac72b130fa1ffcd46ca75168a1d1eb017e882639ce**:
exact phase0.625 после delayed Canvas draw, два PNG с одинаковым SHA, отказ без
provider, real SDK PNG и PDF/compiled assets/SVG, реальные signal/gears/wave
backings при ratio3; accepted wave0.25 вместо draft4, recording0.75 decoded/paused/
muted, commits не выросли. **JS37 PASS**, `/tmp/gui249-raster-js-v1.log`; после
правки error owner **bridge17 PASS + SDK check**, `/tmp/gui249-raster-js-v2.log`.
**Simulator2 PASS**, `.build/gui249-raster-sim-v1.xcresult` (tall lifecycle + Worker/
media); final bridge **Simulator1 PASS**, `.build/gui249-raster-sim-v2.xcresult`.
Физическая пара не затронута.

Промежуточный тест ошибочно требовал ratio>=2 при физическом viewport1091 и
PNG1600; теперь проверяет положительный target ratio, real backing ratio3
проверяется отдельно. Второй тест неверно считал red только при green<0.1 после
AppKit calibrated-to-display RGB (фактический green≈0.149). Реальный PNG открыт и
осмотрен: красный authored Canvas и печатный заголовок. Проверка использует red
dominance с учётом профиля; renderer ради этого не менялся. Артефакт осмотра:
`.build/gui249-raster-preview-v3/E95B57FF-7EAE-41D9-9CF1-B09B2BDFDACB.png`.
Это не presented/portable/video и не полная GUI-250 performance acceptance.

## 19 сентября, 08:25 МСК — GUI-249: настоящий SVG выбранного saved result

format=svg + blockID проходят прежний export owner, immutable cut и V2 publication.
Авторский exportFrame работает в отдельном executor после pause, получает именно
сохранённый state, а не поздний checkpoint; commits запрещены. Ошибка/timeout/
supersession не превращаются в PNG fallback. Passive SVG до 1 МиБ допускает
геометрию/text/local definitions, но не script/foreignObject/CSS/external resources.
Signal использует тот же Plot и точное окно исходных samples: path/text и marker
37125. Настоящий SVG открыт через QuickLook и осмотрен: тонкая синяя кривая,
отдельные точки, оранжевый выбранный sample, читаемые векторные оси/подписи.
Artifact: `.build/gui249-svg-preview-v1/1F61BA03-E39F-427C-9EDA-E7F49F39E624.svg`.

**Mac3 PASS**, `.build/gui249-svg-mac-v1/verification.json`: signal SVG и прежние
PDF/реальный SDK PNG. После ужесточения SVG validator **Mac1 PASS**,
`.build/gui249-svg-mac-v2/verification.json`, source **563477aa080f4a72ec63f26f270dfd3467da0c323e465f01c21cc74c5e6440f5**.
**Core11 PASS**, `/tmp/gui249-svg-core-v2.log`: пассивность, внешние ссылки,
CSS image-set и прежние export CAS/cancel/hash. **JS22 PASS + generated check**,
`/tmp/gui249-svg-js-v2.log`: saved state, pause, no checkpoint/commit, missing/
throwing/timeout/disposed provider, типизированный SVG API, exact signal build.
**Simulator1 PASS**, `.build/gui249-svg-sim-v1.xcresult`: установка/запуск общего
bridge и tall-program lifecycle, без изменения физической пары. Эти проверки
не являются deterministic Canvas/WebGL, presented, portable или video acceptance;
GUI-249/250 не закрыты.

## 19 сентября, 08:08 МСК — GUI-249: PNG canonical page и исправление composite

В existing export добавлен format=png, pageIndex (default0), pixelWidth
(default1600, 128…4096 с прежним ресурсным допуском). Выход имеет точный extent;
несуществующая страница отклоняется, не подменяется ближайшей. PNG идёт через
тот же cut/V2/preparation/cancel/CAS owner. Единый receipt возвращает artifact
и options; PDF-only texPath/pdfPath/pdfSHA256 удалены, PDF получает source artifact.
Options входят в package hash; header PNG проверяется до publication. Сигнатура
cancelExport в TS generator исправлена: два аргумента, как у настоящего SDK.

**Визуальная проверка нашла реальный дефект после первого зелёного Mac7**:
непрозрачный белый фон WebKit snapshot закрывал весь underlying PDF. На PNG был
красный program rectangle, но не было заголовка/формулы/SVG. Исправлен единственный
`DocumentPrintedPage.image`: overlay рисуется только в canonical program bounds,
остальное остаётся PDF; пустой набор программ не рисует overlay вообще. Это не
ослабление тестов или искусственный прозрачный фон. Добавлена проверка печатных
пикселей вне программы. После исправления изображение действительно просмотрено:
1600×2263, читаемые heading/text/x², синяя SVG-кривая, красная программа и footer.
Файл: `.build/gui249-png-preview-v2/3C311AE9-9A77-4094-A87D-0F51A24C40A2.png`.

**Mac7 PASS**, `.build/gui249-images-mac-v2/verification.json`, source
**0459b9954255bba7bc2dcc4e2f723db95cab73ef6aa632ee08bc324e56c86fd8**:
actual XPC PNG и PDF, cancel, >32 MiB Quartz PDF, saved isolation, compiled assets.
**Mac2 PASS**, `.build/gui249-images-mac-v3/verification.json`, final source
**9c393f1958eb174c04308d2387d2625e48056078e7fc3fab4ea8350fc351d688**:
mixed1600px + static800px PNG, ink outside program, nonexistent page error.
Production delta после v2 — только empty-program guard, плюс дополнительные тесты.
**Core18 PASS**, `/tmp/gui249-images-core-v2.log`, options/extent/type/package hash
и прежние source/state/cancel/atomic receipt регрессии. **MCP20 PASS+SDK check**,
`/tmp/gui249-images-js-v2.log`. **Simulator1 PASS**,
`.build/gui249-images-sim-v1.xcresult`, final source: tall lifecycle/page reclaim
после общего composite fix. Mac и Simulator выполнены параллельно, физическая
пара не затронута. Начальный TS test поймал забытый cancelExport в generator;
обновлена декларация, а не заменён рабочий двухаргументный SDK.

Это не SVG/presented export и не portable/video acceptance. Высокое PNG
разрешение не создаёт новых деталей в авторских низкоразрешённых Canvas/media;
author-controlled target-resolution rendering ещё предстоит проверить.
GUI-249 и GUI-250 остаются незавершёнными.

## 19 сентября, 07:56 МСК — GUI-249: durable cancelExport

Публичный keyed SDK `nb.cancelExport(key,{jobID})` отменяет принятый job независимо
от уже законченного JS run. Cancelled job и effect receipt сохраняются одним
writer cut; затем Task останавливается. Final publication отказывается от
cancelled даже при позднем/некооперативном ответе producer. Если saved fence
выиграл первым, поздняя отмена возвращает тот же saved receipt без изменения
файлов. Ни running, ни failure, ни startup не оживляют cancelled. Повтор key и
resume читают один durable результат. Отмена user run по-прежнему не отменяет
его уже отдельно принятые export jobs.

**Mac2 PASS**, `.build/gui249-cancel-mac-v3/verification.json`, source
**337fe83ac1712a2ab2b4f1fe325374f35ea5b84be50a7a7ae02ed20ec1678242**:
реальный XPC SDK готовит streamed PDF; cancel до final fence, повтор key, поздний
completion, status/resume — cancelled и ни одного опубликованного файла; прежний
успешный настоящий PDF export остаётся рабочим. **Core22 PASS**,
`/tmp/gui249-cancel-core-v4.log`: оба порядка cancel/publication, atomic effect,
restart/reconcile, prior bytes; прежние CAS/hash/recovery регрессии.
**MCP3 PASS + generated SDK check**, `/tmp/gui249-cancel-js.log`.
**Simulator1 PASS**, `.build/gui249-cancel-sim-v1.xcresult`, тот же source:
iOS compile/install и tall-program lifecycle. Физическая пара не изменена.
Промежуточно исправлены неверное использование private Host JSON helpers в Core
и fixture без running run; это не основания ослаблять сценарий или контракт.

PNG/SVG/presented, standalone/portable package и video ещё не реализованы;
GUI-249/250 не закрыты.

## 19 сентября, 07:49 МСК — GUI-249: потоковый PDF без binary IPC

Quartz output заменён с `NotebookPDFBuffer` на проверяемый file consumer:
ошибка/short write не становятся saved. PDF/assets/SyncTeX получают обычные V2
дескрипторы и полный file SHA; stage идёт частями по 4 МиБ через существующую
очередь записи. Подготовка читает 1 МиБ окна вне writer, проверяет каждый SHA и
map, затем native capability допускается коротким source/state CAS и atomic
move/receipt. Удалены inline `NotebookExportAsset` и IPC command publishExport,
не оставлен второй путь. Map принимает проверенный file hash без копии PDF.
Нет прежних 8/17 MiB publication caps; metadata остаётся <=1 МиБ/16384 parts,
ограничения canonical typesetter не изменены. Job receipt пишет один native
publication owner, ошибочный поздний ответ не перезаписывает saved.

**Mac6 PASS**, `.build/gui249-stream-mac-v2/verification.json`, source
**99cf4ab671e79b5ac31a761344402be0c85a646c52dca5066194c3d8f18d3652**:
настоящий 12-page Quartz PDF с несжимаемыми пикселями **>32 МиБ**, >8 parts,
publication JSON <16 КиБ; повторное чтение всех байтов даёт тот же SHA и PDFKit
открывает последнюю страницу. Также прежний real XPC export, asset-backed
program, immutable state/conflict и red-vs-blue negative control PASS.
Это не измерение системной пиковой памяти: bounded окна/состав ресурсов
проверены по реализации, системный memory/CPU/GPU acceptance ещё впереди.
После смены sink PDF действительно открыт через Quick Look: красная область,
векторный заголовок и ссылка сохранены; `.build/gui249-stream-preview/`.

**Core22 PASS**, `/tmp/gui249-stream-core-v4.log`: export/source/state CAS,
потоковые hashes/missing parts/cancel cleanup/prior artifacts, V2 namespaces,
атомарные receipts/restart. **MCP8 PASS + SDK check**,
`/tmp/gui249-stream-js.log`: native/JS MIME согласованы, typed SDK и import.
**Simulator1 PASS**, `.build/gui249-stream-sim-v1.xcresult`, тот же source hash:
iOS compile/install и tall program/pages/reclamation. Mac и Simulator работали
параллельно на независимых destination/bundle/derived data. Физическая пара не
изменена. Первые сборки отклонили забытый Codable key, test helper shadowing и
название CoreGraphics callback argument; исправлены, итоговые прогоны зелёные.

Полный GUI-249 не завершён: presented/PNG/SVG, standalone/portable package,
deterministic video и публичная отмена ещё впереди. GUI-250 не принят.

## 19 сентября, 07:34 МСК — GUI-249: immutable saved export cut

Queue admission фиксирует source/state/packages в одной WAL snapshot, до
асинхронного render. `cutSHA256`, stateRevision и moment=saved остаются в queued,
saved и failed job. Publication проверяет полный исходник и state, не только
максимальный contentStamp; output того же PDF с другим cut имеет другой package
hash. `document.cut.json` сохраняет точный вход. Рендерер обязан вернуть тот же
cut/jobID; повтор status не исполняет job заново. Slot admission учитывает также
запросы между чтением и постановкой в очередь.

Asset-backed PDF получает store. Saved render использует прежний coordinator
и **общий** бюджет, отдельную namespace для растров, не берёт поздний live image
по равному journal token и не затирает его. Вёрстка, векторный PDF и ссылки
остаются GUI-238; user runtime не перематывается и не checkpoint-ится экспортом.
Удалён старый publication contract без state cut; совместимость таких DTO не
добавлялась. Исторический JSON job читается как данные, не воспроизводится.

**Mac5 PASS**, `.build/gui249-mac-cut-v2/verification.json`, source
**08b7759c2a270005665ee0d94383a43e9e1ac8731485174c7299a41fdc02a062**:
real compiled asset module/Worker/resource -> PDF; negative blue live cache
не попал в saved red PDF и не был заменён; vector text/links; actual XPC export
с независимой записью; state меняется после admission -> revision_conflict,
нет публикации/повторного render. **Ещё Mac1 PASS**, `.build/gui249-mac-cut-final/verification.json`,
source **f4be21dcdce80172b5327743ab02914ed6665b310948b61885d9518196be617c**:
failed сохраняет исходный cut/state identity. Последующий production change
между прогонами только этот error receipt.

**Core14 PASS**, `/tmp/gui249-core-cut-v5.log`: stale source/state/causal change,
атомарная квитанция, неизменные предыдущие файлы и очистка staging.
**Simulator1 PASS**, `.build/gui249-sim-cut.xcresult`, source
**74f51a1f4e5ffd49154cdc34b6aaa37b64925d16986401163bc4f7bd65ab54e3**:
default native tall-program/curl/capture маршрут после общей правки token.
**MCP20 PASS + generated SDK check**, `/tmp/gui249-js-cut-v3.log`.

Готовые PDFs действительно открыты как Quick Look white-paper renders:
compiled parabola x=2/y=4, asset/SVG и подписи; красный program rectangle рядом
с selectable vector heading и внешней ссылкой. Первые sips PNG были прозрачными,
а не чёрной бумагой PDF; проверен настоящий белый PDF-view. Промежуточные ошибки
были compile/fixture контрактами: новый обязательный cut, мутирующий вызов внутри
Swift Testing macro, несохранённый canonical document в старой fixture, неверный
cwd TS test и старый union без GUI-238 `tex`. Они исправлены, проверки повторены.

**Это foundation, не полный GUI-249**: PDF пока сохраняет старые inline caps.
Presented cut, PNG/SVG, portable offline package/import, deterministic video,
streaming large artifacts и cancellation ещё реализуются. Полная приёмка GUI-250
не проведена; физическая пара не изменена. GUI-249 остаётся In Progress.

## 19 сентября, 07:20 МСК — GUI-248: 2/4/8 материалов и переход программы через страницу

На прежнем pool/owners проверены настоящие signal/Three gears/wave packages.
Новый scientific вариант существующей UI fixture открывает 2/4/8 материалов,
часть вне экрана. Первые control, pan туда/обратно, Home/return и холодное
открытие сохраняют принятые параметры. Пул не увеличен; при избытке видимых
материалов очередь остаётся явной, готовые пассивные пиксели не заменяются пустотой.
Canvas wave marker и линия сечения теперь экранные DOM/CSS overlays, а не
размытые части научной сетки256²; модель и число отсчётов не изменены.

Найден и исправлен настоящий общий дефект GUI-238: SyncTeX номер страницы
наследовал строку прерванного program slot. Его footer попадал в bounds блока,
завышал sourceOffset следующего фрагмента и блокировал установку всего overlay.
Тот же decoder теперь узнаёт авторские hbox/zero-width strut rows; footer не
является строкой программы. Высоты задаются в PDF `bp`, не TeX `pt` (убрана
потеря0.37%). Rendering recipe3 инвалидирует старые производные карты.
Это исправление владельца карты, не ослабление geometry guard или второй layout.

**Simulator 3 PASS из v9**: два tall-program/page-handoff native сценария и
2/4/8 UI (`.build/gui-248-sim-v9.xcresult`); ещё **1 native PASS v10**,
`.build/gui-248-sim-unit-v10.xcresult`: 2/4/8 actual packages внутри документа,
первый control каждого блока, точная сумма высот300, camera reuse того же heap,
checkpoint/reclaim/return, callback WebKit termination с восстановлением state.
После закрытия все WebKit leases и pinned rasters освобождены. Введён именно
callback delegate, не настоящий OS jetsam. Учтённый peak raster budget:
25 199 985 / 25 220 286 / 27 795 082 bytes; это **не** полная WebKit/GPU память.

**Mac 3 PASS**, `.build/gui-248-mac-v3/verification.json`: два canonical PDF
сценария (vector text/links + program composite), Worker/media lifecycle.
Mac и Simulator v9 source **05b479842f0dac427565e4fca2e8aad441ecb7c0bfde2e36c2bee2a2a0d74e63**;
окончательный source v10 **16332c6646acb5f05eb2a557fda481bfcbfb7dbb069dc9148d13d82991635d51**
отличается только test pinch pivot. **Core5 PASS**, `/tmp/gui248-core-v9.log`;
**MCP21 PASS + generated SDK check**, `/tmp/gui248-js-v9.log`, `/tmp/gui248-sdk-v9.log`.
Полностью подготовлен собственный `.build/notebook-typesetter-runtime` для
Mac/Simulator, включая новый compiled markup; shared runtime другой задачи
не изменён. Физическая пара116 не затронута.

Отказы v2–v6 отделены от результата: page-wide demand пяти live программ
не укладывается в прежний pool, поэтому проверяется реальный visible cut;
затем v7 выявил footer bug. В v8 ещё использовался старый generated markup;
он пересобран вместе с pinned runtime. V9 повторно выявил ошибку fixture:
масштабирование вокруг центра целой бумаги уводило короткий нижний fragment
за viewport, после чего owner правильно его освобождал. V10 держит pivot на
видимом фрагменте и по-прежнему требует тот же WK/nonce, не ослабляя reclaim.

Browser marker/caption, board screenshots2/4/8 и native page2 действительно
осмотрены. Последний показывает clipping программы и отдельный номер страницы;
passive cut во время восстановления имеет честный preparation label, не
квитанцию готовности всех контролов сразу. Exploratory Time Profiler v2
относится к неудачному тесту и **не принимается** за performance budget.
Input/main-thread p95, system GPU/frame measurements, Pencil, 10 повторов,
30 минут и installed shared delivery остаются открыты для интегрированного
GUI-250. GUI-248 не переводится в Done; следующий срез — GUI-249 export.

## 19 сентября, 06:45 МСК — GUI-247: точный объект и показанный кадр

В существующем меню материала чата можно выбрать видимую программу и явно
зафиксировать кадр. Прокручиваемая программа сохраняет свои жесты; отдельного
selection/scene manager нет. Тот же lifecycle подтверждает checkpoint у writer,
останавливает ввод и удерживает WebKit до Send/снятия выделения. Send синхронно
копирует фактически установленные native pixels, затем возобновляет программу.
Замена source/принятого state не оставляет её в вечной паузе. Собственное echo
записи checkpoint дожидается этой же транзакции и не считается внешней правкой.

`notebook.semantic` — ограниченный синхронный авторский callback. Только frozen
selection связывается с source revision, SHA изображения и физическими
координатами его cut; это недоверенные данные, не инструкции/permission.
Бегущая сцена, async/ошибочный callback или пропавший объект дают явное
unavailable, а не данные из более позднего heap. Plot sample, Canvas node и
Three part реализуют этот контракт; Plot/Canvas также доступны с клавиатуры.
Прежние CAS/undo/transaction остаются единственными владельцами записи.

**Simulator 4 PASS**, `.build/gui-247-sim-binding-v5.xcresult`, source inputs
**13139981db3fff2f404a0566974c1128868f3290e84d35751be25f03730f0af5**.
Проверены настоящие native Send pixels и semantic phase до/после resume,
документный physical cut/anchor, три actual compiled packages, внешняя правка
во время паузы и UI выбор/freeze/clear на доске и в документе. Экспортированный
синий PDF-composite кадр и итоговый UI действительно осмотрены. V4 выявил
собственное checkpoint echo, снимающее паузу; исправлен owner, не ослаблен тест.
**Mac 2 PASS**, `.build/gui-247-mac-final/verification.json`, source
**c108241cacc5f6276d2191e822b2a6d0c8df48ae8666e7e4a28840e5a43ac120**:
writer refusal/checkpoint/raster и causal source ABA. Последующая правка касается
только iOS DocumentBlockRuntime; Mac runtime не менялся.
**Core 33 PASS**, `/tmp/gui-247-core-final.log`; **MCP 24 PASS + SDK check**,
`/tmp/gui-247-js-final.log`, `/tmp/gui-247-sdk-final.log` — hash/trust/bounds,
ошибочные callbacks, immutable copy, CAS и human-preserving undo.

Browser keyboard proof: signal sample61338, t61.338s, u2.2285; wave node129:138,
x.506m/y.541m/u−.9597mm. Их настоящие marker/caption осмотрены. Preview tabs и
servers закрыты. Это не совместная installed agent/human сессия, не Pencil и
не system frame/CPU/GPU gate. Физическая пользовательская пара116 не изменена.
GUI-247 остаётся In Progress; интегрированный shared маршрут и GUI-248–250
ещё не приняты. Известный визуальный остаток для GUI-248: marker Canvas-поля
масштабируется вместе с научной сеткой256² и требует чёткой экранной обводки.

## 19 сентября, 05:53 МСК — GUI-246: Worker, внешний расчёт и локальное медиа

Добавлен один asset-backed recipe `wave` на прежнем TS/package пути: мембрана
256×256, фиксированный край, воспроизводимый seed, проверочная стоячая мода,
сечение и относительная дискретная энергия. Один Worker, один передаваемый
256 KiB буфер с возвратом; отмена/замена завершают старого исполнителя, поздний
ответ не меняет последний завершённый результат. Скрытие прекращает расчёт,
чтение эталона и media decoding; cold reopen восстанавливает параметры и seek.

Собственный внешний NumPy-расчёт действительно выполнен. Пакет содержит input,
Python-скрипт, provenance/hashes, float32 поле, MP4/H.264/AAC, PNG и WAV. Видео
показывает 4 секунды модели за 8 секунд; озвучивание амплитуды явно не названо
физическим звуком. HTMLMediaElement читает scoped URL напрямую, без fetch/Blob
полного видео. Python/WASM runtime в приложение не добавлен.

Окончательный package **de90ce96d5080cfe7fc5079c82f9b8db1ecd1a3c77530228b9ebbcdbe0b0e349**.
**Mac 1 + Simulator 2 PASS** (`.build/gui-246-mac-final/verification.json`,
`.build/gui-246-sim-final.xcresult`), source до/после:
**e6376d82728ae60a944a1ab2af78403b41f12cd779f3770f8b96e537c3ba9a34**.
Реальный WK проверяет transfer detachment, максимум одного worker и одного
неподтверждённого кадра, latest-wins, cancel/error с сохранением хорошего поля,
checkpoint/resume/dispose, локальное видео, seek/rate, missing MP4 и retry без
потери playhead. UI проверяет первый control, play/pause/seek, Home и холодное
SQLite-открытие на обеих поверхностях. Mac здесь offscreen WK, не видимый жест.

Последнее уточнение только UI-теста выбирает WebView по постоянному заголовку,
а не первый WebView документа, и требует достижимости конца материала.
**Ещё 1 Simulator UI PASS**, `.build/gui-246-sim-scroll2.xcresult`, неизменный source
**3ae3ee146c324863ef96f582190c4d0ced5d33f7c86b057c91d44a9ce3c8940d**.
Итоговые board/document screenshots действительно просмотрены: полный график,
единицы и формула читаемы внутри локальной прокрутки, камера доски не движется.
Окончательный browser package осмотрен в420×900 dark: исправлено сжатие шрифта
Canvas-сечения за счёт его фактической CSS-ширины/DPR, не уменьшением текста.
Временные viewport/media overrides, tabs и preview servers убраны.

**25 MCP PASS + SDK check**, `/tmp/gui-246-js-final.log`, `/tmp/gui-246-sdk-final.log`:
первый шаг из покоя, CFL, неподвижный край, дискретная энергия, сходимость к
аналитическому решению, seed и точное совпадение реального NumPy float32 с JS.
Для принятого mode t=0.650s max error=4.04e−6 mm; NumPy comparison=0.00e+0 mm.
Reference Sound/pressure-waves осмотрен: связаны поле, сечение, цвет и параметр;
собственные данные/код, постоянная шкала −1…1 mm, без скрытого auto-gain.

Промежуточные UI отказы v1/v2/scroll были ошибками адресации harness (скрытая
кнопка в query, HTML slider без AX bounds, summary как staticText). Заменены
стабильным query и настоящим касанием seek. Отдельный ранний JS-запуск попал в
`npm ci` Mac harness и не нашёл tsx; после подготовки зависимостей повтор прошёл.
Не скрыта граница сигнала: эти проверки не доказывают Pencil, system frame/CPU/
GPU/memory budget, 30 минут, 300 MiB media streaming или installed/shared chat.
Пользовательская физическая пара116 не изменена. GUI-246 остаётся In Progress;
GUI-247–250 и итоговая приёмка ещё впереди.

## 19 сентября, 05:20 МСК — GUI-245: offline 3D-механизм и его ресурсный цикл

Прежний inline `gears` заменён одним Three.js 0.186.0/WebGL 2 recipe на общем
TS/package пути. Собственная Blender-модель: **144 332 треугольника**, две 2K
текстуры, glTF в метрах, подписи в мм; 60/40/24 зуба с эвольвентными рабочими
сторонами и упрощёнными корнями. Вращение, делительные контакты и поле скоростей
используют одну модель. Выбор детали, camera, phase, раскрытие и field сохраняются
через прежний checkpoint. Старый custom WebGL renderer и его тесты удалены.

Окончательный package **5549f00e5d5e31cbbbec4d5892981c9356bed0bac979b577bbf73813a971ed52**.
**Mac 2 PASS**, `.build/gui-245-mac-final/verification.json`; **Simulator 3 PASS**,
`.build/gui-245-sim-final.xcresult` (2 unit + UI обеих поверхностей). Входы до/после
неизменны: **c409ba292faeec0c1ae783cac0f28d7f3b4e0435f917740636813ee66ad1aea5**.
Реальный WK загружает модель/текстуры offline, рисует GPU-кадр до ready, сохраняет
selection/reveal/camera, переживает WEBGL_lose_context/restore в том же renderer,
не перечитывает assets при resize и освобождает наблюдаемые WebGL buffers.
Неподвижная сцена не продолжает рисование. Mac XCTest имеет hidden document:
там принят статический GPU/lifecycle путь, **не непрерывная анимация или видимые
жесты Mac**. Simulator проверил продвижение анимации и UI: первый orbit, pinch,
выбор, rotation, Home/return и cold reopen на доске и в документе. Это не Pencil
на физическом iPad, системный FPS/VRAM или полный performance gate.

Отрицательные native сценарии: повреждённый glTF, missing PNG, реальный retry,
WebGL 2 unavailable -> явно подписанный статический план, dispose во время двух
задержанных createImageBitmap -> оба bitmap закрыты, поздний результат не оживает.
В раннем v1 обнаружены 2 оставшихся GPU buffers после восстановления окружения:
Three RoomEnvironment.dispose не освобождает instanceMatrix своих InstancedMesh.
Recipe теперь явно освобождает их; финальный strict zero check PASS. Ранние Mac
v1–v4 также обнаружили отсутствие GPU draw у offscreen rAF: вместо подделки
visibility/clock первый и checkpoint кадры теперь рисуются синхронно. Startup ready
объявлен один раз; local error UI не выдаётся за успешную 3D-модель.

**24 MCP PASS + SDK check**, `/tmp/gui-245-js-final2.log`,
`/tmp/gui-245-sdk-final2.log`: отношения скоростей/единиц, finite checkpoint,
реальные glTF/PNG bounds и exact native fixture. Дополнительная адресная проверка
контуров в `.build/gui-245-mesh-contact.mjs`: 128 фаз двух пар, 4 410 353 сравнений,
0 пересечений рабочих 2D контуров. Это не CAD-тест допусков всего glTF.

Окончательные exported native screenshots в `.build/gui-245-sim-final-shots/`
реально просмотрены; после orbit/pinch видны крупные детали и сохранённое ведомое
колесо, документная формула читаема. Окончательный browser package также осмотрен
при 834×1194 и 420×900 dark: общий вид целиком, Play/Pause, читаемые параметры и
узкая локальная прокрутка. Temporary viewport/media overrides и preview servers
убраны. Reference Mechanical Watch/mainplate просмотрен до моделирования:
перенесены отношения опор, осей, раскрытия и цветовых ролей, не исходные assets.

Физическая пользовательская пара 116 не изменена. GUI-245 остаётся In Progress:
полный installed/shared маршрут, видимые Mac-жесты и общая визуальная/performance
приёмка не заменены этими targeted checks. GUI-246–250 ещё не реализованы.

## 19 сентября, 04:41 МСК — GUI-240 + GUI-238: объединённый документный runtime

В ветку визуализаций объединён GUI-238 `a1cbfad`: canonical PDF/SyncTeX,
нативный source editor и единый **wire 28 / manifest 11**. Существующие
package-backed программы сохраняют своих владельцев; режим Код замораживает
тот же heap до durable checkpoint. В нашем package-тесте удалены два уже
несуществующих `onSourceChange` аргумента — source editor больше не WebKit.
Первый integration build остановился именно на этих тестовых аргументах;
production fallback для старого textarea не добавлялся.

Неизменные входы до/после: **1930fc6f7723b97a6133d74e7ed2f1c94909b33befc9e126480ac866ba0fbce7**.
**Mac 3 PASS**, `.build/gui-240-gui238-mac-v2/verification.json`;
**Simulator 6 PASS**, `.build/gui-240-gui238-sim-v2.xcresult` (3 unit + 3 UI).
Проверены compiled TypeScript/worker package и dense signal в обоих владельцах,
Code-hidden heap/durability, первый tap, настоящий локальный scroll без pan
доски, rotation, background/return, cold reopen и native source autosave/undo.
Это свежая native проверка и последней GUI-244 layout-only правки. Exported
board/document formula screenshots реально просмотрены в
`.build/gui-240-gui238-sim-v2-shots/`: график, ось 61.360, одна формула и пояснение
читаемы; документ использует новую Лист/Код навигацию.

**Core 13 PASS**, `/tmp/gui-240-gui238-core-v1.log`; **MCP 28 PASS + SDK check**,
`/tmp/gui-240-gui238-mcp-v1.log`, `/tmp/gui-240-gui238-sdk-v1.log`; source inventory
**2 PASS**, `/tmp/gui-240-gui238-inventory-v1.log`. Для native builds переиспользован
готовый typesetter runtime из GUI-238 checkout после `prepare --check` обоих
platforms против текущего input digest. Это тот же проверяемый артефакт, не
повторная сборка и не независимая приёмка всего typesetter.

Mac и отдельный Simulator `3E0E27D3-C87A-40EB-B875-6D6571DC29D3` исполнялись
параллельно по прямому указанию Амира. Пользовательская физическая пара
0.3.113 (116), wire26/manifest9 не обновлялась, её контейнеры не затрагивались.
GUI-240 не завершён: 3D/compute/shared editing/export/release и общая визуальная
приёмка ещё впереди. Этот merge не доказывает аппаратную performance или live
CloudKit delivery.

## 19 сентября, 04:32 МСК — GUI-244: плотный сигнал, Plot и формула в одном пакете

В прежнюю библиотеку добавлен только отсутствовавший asset-backed recipe `signal`:
100 000 воспроизводимых float32 отсчётов, Canvas min–max обзор (8 000 B),
Observable Plot 0.6.17 для адресного окна 50–4000 исходных точек, изолированный
MathJax 4.1.3 с локальными SVG-глифами и assistive MathML. Синтетический источник,
seed, units и добавленный 3-sample импульс названы явно. Всплеск открывает 50
отсчётов через Range **245248–245447**, то есть 200 B, не всю запись 400 000 B.
Один текущий запрос, отмена устаревшего, retry, resize/theme без повторной загрузки,
checkpoint selection и внешний `notebookstate` используют один путь. Нет нового
native renderer, scene DSL, package manager или второго набора семи примеров.

**23 MCP PASS + pinned SDK check**: `/tmp/gui-244-signal-js-final.log`,
`/tmp/gui-244-signal-sdk-final.log`. Полная воспроизводимость raw/envelope,
сохранение экстремумов, индексы краевых окон, точное совпадение native fixture с
browser build. Два source-inventory checks PASS: исключён только производный
`MCP/.notebook/program-builds`, соседнее authored содержимое остаётся входом.

**Mac 1 PASS + Simulator 1 PASS**, `.build/gui-244-signal-mac-v5/verification.json`,
`.build/gui-244-signal-sim-v5.xcresult`; до/после SHA
`bbd3f74fac37567f75960d1bf16ace3a87cd89ad2a246f37ef16c1c604d0ddb5`.
Проверены настоящий offline WebKit, Plot, MathJax (включая дополнительный script
глиф), Range, resize без fetch, checkpoint/resume и внешний state. Custom-scheme
загрузки не попадают в WebKit Resource Timing: v4 обнаружил 0, поэтому v5
наблюдает реальные fetch вызовы тестовым document-start script, не принимает
сравнение двух нулей за доказательство отсутствия повторной загрузки.

**Simulator UI 1 PASS** в `.build/gui-244-signal-sim-v4.xcresult`, source
`c93852f0ee876031f698d0ba2b97ff3954c51dd8ab3414d4bd3da8202d42249e`:
обе поверхности — первый tap, свайп до полной формулы без сдвига доски,
rotation, Home/return, cold SQLite reopen. Unit в этом же v4 был FAIL по
Resource Timing, исправлен и отдельно проверен выше; весь v4 не назван PASS.
Физический iPad не использовался. Exported screenshots реально осмотрены:
`.build/gui-244-signal-ui-v4-shots/68B19F65-2C74-45B8-8073-E51506715775.png`
и `7C844C3D-EE01-4EB5-A612-9ACC903DED2B.png`.

Осмотр, а не зелёный lifecycle test, нашёл обрезанную нижнюю часть сцены:
добавлена собственная focusable scroll region, использующая нынешний finger
owner. Также исправлены неверные Plot dots и видимый дубль assistive MathML
(нужен MathJax updateDocument). После native checks исправлен только правый
отступ оси при ширине <450 и обновлён generated fixture: browser 420 dark/reduced
motion + 834 light осмотрены; ось не обрезана, формула одна, 256 DOM nodes вместо
100k. Файлы `.build/gui-244-signal-{narrow-dark,834-light}.png`.
Итоговый package `38f991b9d1aee1cfcd4085a6e9fae8e4630af069f5e1f55df54247fd6ab9d3a7`
(14 211 148 B, включая offline MathJax и source maps). Native receipts относятся
к своим SHA до этой последней layout-only правки, а не выданы за весь final tree.

GUI-244 остаётся In Progress: новая 2D-ветка реализована, но визуальная приёмка
семи прежних reference episodes, live shared delivery и итоговые performance/
release условия не закрыты. Это не аппаратная performance приёмка Simulator.

## 19 сентября, 04:03 МСК — GUI-243: CLI descriptor не копирует пакет заново

Проверка реальной пары CLI-команд, а не только build API, нашла лишнюю работу:
созданный рядом `prepared.json` менял directory listing и заставлял заново
копировать тот же immutable package. Теперь после необходимого re-resolution
проверяется semantic key; прежний неповреждённый артефакт переиспользуется.
Resolver не игнорирует неизвестные JSON/пакеты ради искусственного cache hit.
Если имена файлов не менялись, остаётся прежний быстрый путь без bundler.

**27 MCP PASS + pinned SDK check**, `/tmp/gui-243-cli-cache-tests.log`,
`/tmp/gui-243-cli-cache-sdk.log`. Новый regression выполняет две настоящие CLI
команды с разными output JSON и проверяет hit, тот же directory/source map и
package identity. Генератор native fixture обновил только notebook-build.json
(builder identity/provenance); все JS/CSS/SVG/worker bytes и native owners
не менялись, Xcode ради этого CLI-исправления не повторялся. Предыдущие native
квитанции относятся к своим указанным SHA, не к этому новому всему дереву.

## 19 сентября, 04:00 МСК — GUI-244: checkpoint семи прежних научных recipes

`Science.mount` подключён к общему NotebookProgram lifecycle: pause прекращает
rAF и новые авторские изменения, checkpoint возвращает последнюю явную модель
без дополнительного commit, resume оставляет модель остановленной, dispose
отменяет кадр и снимает общие listeners. Сами семь моделей/рендеров не заменены.

* **10 MCP PASS** и pinned SDK check: `/tmp/gui-244-lifecycle-js-v1.log`,
  `/tmp/gui-244-lifecycle-sdk-v1.log`. Проверены последние анимационные phase,
  отсутствие frame commits, freeze, deep-copy checkpoint, resume/dispose.
* **Mac 1 PASS + Simulator 1 PASS**, каждый test проходит **все семь recipes**
  через настоящий spatial WebKit owner: ready, изменение доступного phase input,
  native checkpoint/repeat/resume и eventual release действительного lease.
  `.build/gui-244-lifecycle-mac-v4/verification.json`,
  `.build/gui-244-lifecycle-sim-v4.xcresult`; source до/после неизменен:
  `0016bb0a6148dce927307f94ddb9bdb067452b483742ba18583ee7a6e984bf1a`.

Первый native build выявил пропущенный try в тесте. V2 тест неверно предполагал
0.625 при шаге slider 0.002 (браузер принимает 0.626); теперь сравнивает checkpoint
с реально принятым DOM value. V3 Simulator неверно требовал синхронного release
при действительном асинхронном snapshot borrow: проверка ждёт существующее
bounded завершение. Production owner ради этих ожиданий не менялся.

Это только lifecycle-срез GUI-244. Не заменяет настоящие пользовательские жесты
и визуальное сравнение всех семи эпизодов с референсами, Plot/MathJax/100k Canvas,
ориентацию/темы/масштаб, общую performance/release приёмку. Задача In Progress.

## 19 сентября, 03:48 МСК — GUI-243: TS/build/preview до работающего package

`prepare.mjs program` теперь принимает TS entry, imports/CSS, explicit workers,
HTML и адресованные assets. Отдельный pinned TypeScript 7.0.2 CLI проверяет DOM
и WebWorker, esbuild 0.28.2 собирает ESM с linked source maps. Имеющийся package
format1 и GUI-242 importer/publication остаются единственным native путём.
Нет npm install/scripts внутри сборки, CDN или whitelist библиотек. Проверяются
lock version/integrity metadata и реальные source SHA; npm tarball integrity
заново не проверяется. Внешние bundle/CSS imports отвергаются. File URL plugin
хеширует/копирует binaries потоком; cache не перезаписывает используемые пакеты.

Local preview обслуживает только подготовленные paths на случайном loopback URL,
проверяет identity, MIME/ranges, CSP и изменённые файлы. Он использует прежний
`notebook-program.js` с local transport, явно сообщает package/build/bridge hash
и не подключается к Notebook. Runtime/ready ошибки выводятся в UI и stderr,
source maps восстанавливают авторскую позицию, если она есть в stack.

Проверки:

* **26 MCP PASS**, `/tmp/gui-243-js-v5.log`: TS/CSS/modules/typed workers, portable
  output при переносе проекта, cache/source/lock/config invalidation, две параллельные
  сборки, repair повреждённого derived entry, type/missing dependency/external CSS
  errors без изменения старого артефакта, 300 MiB binary по 75 bounded parts,
  preview namespace/Range/409 и mapped diagnostics, прежние recipes/import.
  Это sparse binary fixture, не benchmark уникальной передачи 300 MiB.
* **Pinned SDK check PASS**, `/tmp/gui-243-sdk-v5.log`. Browser fixture исключён
  только из NodeNext-конфига MCP: его TS действительно проверяет browser build,
  а regression сравнивает весь generated native fixture с текущим compiler output.
* **Mac 1 PASS**, `.build/gui-243-compiled-mac-v2/verification.json`: настоящий
  compiled package запускается в spatial и document iframe владельцах, общий
  worker chunk/asset/CSS загружаются offline, checkpoint документа возвращает x.
* **Отдельный Simulator 3 PASS**, `.build/gui-243-compiled-sim-v2.xcresult`:
  тот же native contract; compiled package first tap → Worker result → Home/return
  → process terminate/cold reopen на board и document; прежний полный LC gesture
  scenario на обеих поверхностях (параметры, background, final checkpoint).
  Исходники обоих native прогонов до/после неизменны:
  `9e4ce4c75fdfc4a42c8ff7f8c06fd65ba2070c9cc2edb7882a9dcf70d1daeb1f`.
* Живой in-app browser: 2²=4 → первый клик → 3²=9 → (−3)²=9; reload сбрасывает
  только local preview state. Отдельно runtime exception показал `main.ts:2:30`,
  rejected ready — `main.ts:1:31`, без programReady. Осмотрены финальный preview
  `.build/gui-243-preview-final.png` и оба Simulator screenshot из
  `.build/gui-243-compiled-sim-v2-shots/` — график/подписи/control читаемы.
  Проверенный compiled package SHA:
  `804e33f3780ef7a3d5796cf01187bec86cb91cbe85d8eec9371324ce5492781f`.

Первый native v1: Simulator 1 PASS/1 FAIL, Mac 0 PASS/1 FAIL. Причина — тест
вызвал callback-overload callAsyncJavaScript как async и сравнил Void с String;
исправлен сам readback теста, не поведение приложения. Итог — v2 выше.
Первый Node regression выявил абсолютные пути в virtual asset modules/source maps;
они заменены project-relative paths, воспроизводимость проверена заново.

Это принятый development-срез GUI-243, не Done всей задачи/GUI-240. Пользовательская
пара 116 не обновлялась; текущий live submit через неё, межустройственная доставка
этого TS-артефакта, full release/performance, 10 повторов/30 минут не заявляются.
Симулятор используется по прямому указанию Амира и не называется физическим iPad.
Простая квадратная функция — build/transport fixture, не визуальная приёмка
семи предметных сцен GUI-244/245. Дальше — lifecycle семи прежних recipes,
Plot/MathJax и плотная 2D-сцена через этот же открытый author-side путь.

||||||| 20b0266
## 19 сентября, 04:17 МСК — GUI-238: интеграция исходника, канонической бумаги и программ

Интеграция основана на `8e51ac2`, GUI-241 до `f692113` и GUI-242 до `20b0266`;
последующая GUI-243 здесь не включена. Нативный редактор, общие команды/undo и
один PDF сохранены; старые DOM-пагинация и textarea не возвращены. Программные
пакеты используют того же владельца, в том числе на канонических страницах.
Для совместимости новых `tex`-блоков и packages выделены **wire 28 / manifest 11**;
подмена более старого manifest новым полем отвергается до продвижения курсора.

Исправлены выявленные живым сценарием дефекты:
- Markdown ↔ бумага теперь связывает настоящий UTF-16 абзац, включая CRLF,
  повторяющиеся абзацы, emoji, формулы и opaque-изображения; координата double tap
  относится ко всему установленному листу, а не к смещённому content root.
  Позиция чтения использует ту же карту исходных абзацев, не служебные TeX-строки.
- Закрытый native paper освобождает PDF/raster, а не только WebKit; давление
  общего бюджета действительно снимает последний держатель изображения.
- «Лист → Код → Лист» сохраняет тот же runtime программы на iPad и Mac.
  Скрытая модель заморожена, быстрый возврат ждёт durable checkpoint. Ошибка
  писателя не возобновляет часы и не выбрасывает heap; адресный повтор доступен.

Mac **23/23 PASS**, без skips/runtime warnings:
`.build/gui238-canonical-mac-build/Logs/Test/Test-NotebookMac-2026.09.19_03-56-55-+0300.xcresult`,
лог `.build/canonical-engine/integration-mac6.log`. Включены нативный исходник,
causal undo/черновик/конфликт, A4/Letter/source map, изображения и экспорт того же
PDF, реальные package assets, сохранение runtime при смене исходника/видимости,
отложенная и отказанная запись, освобождение памяти. Книга >6 МиБ, 140 блоков,
35 SVG и 1680 формул: **4.561 с**, 35 страниц, PDF 1 993 592 байта,
peak accounted derived **39 211 334 байта**. Это отдельная выборка, не p95/RSS/FPS.

Core **18 PASS** (4 XCTest + 14 Swift Testing): `integration-core4.log`;
два SQLite, холодное чтение `.tex`/packages и строгая manifest-граница.
JS **29/29 PASS** (`integration-js-final.log`), жесты **7/7 PASS**
(`browser-contracts-final.log`); MCP typecheck/generated resources PASS.
Логи находятся в `.build/canonical-engine/`.

Simulator integration1: **32/32 PASS** (native source/print/state, packages и UI).
Расширенный реальным drag integration2 обнаружил сброс slider 7→3 после Code.
Integration3: **7/8 PASS**: сброс устранён, проверка отказа I/O обнаружила скрытый
под замороженной программой retry. Допуск ввода и ready теперь учитывают этот
отказ. Integration4: **7/9 PASS**; два прежних теста ещё ожидали DOM-heading
ключ вместо страницы канонического PDF и интерактивный runtime после отказа
писателя. Проверки приведены к действительным контрактам: независимый дальний
лист и сохранённый замороженный heap с настоящим нажатием retry. Integration5:
**6/6 PASS**; `.build/gui238-canonical-simulator-build/Logs/Test/Test-Notebook-2026.09.19_04-12-42-+0300.xcresult`.
Дополнительная Mac-проверка закладок/канонической бумаги: **6/6 PASS**,
`integration-mac7.log`, результат `Test-NotebookMac-2026.09.19_04-14-00-+0300.xcresult`
в том же Mac Logs/Test. Эти наборы не заменяют общую длительную приёмку.

Финальный Simulator integration6: **16/16 PASS**, без skips/runtime warnings:
шесть canonical print/reading-map проверок, шесть program lifecycle/checkpoint,
холодное восстановление смыслового места чтения и три настоящих UI-сценария
(режимы/поворот/ввод/undo/drag slider и возврат без сброса).
Результат `.build/gui238-canonical-simulator-build/Logs/Test/Test-Notebook-2026.09.19_04-14-53-+0300.xcresult`,
лог `.build/canonical-engine/integration-sim6.log`.
Финальные исходники `source_inputs`:
`f76894f8205a75a259e4fdc97e4cec854927be422cf2feba66b0c692bfa5d28e`;
инвентарь `.build/canonical-engine/final-source.json`, повторно совпал после прогона.
Это явные scoped Xcode/Core/JS результаты, не выдуманная квитанция `verify --full`.

Физическая пара и её контейнеры/ключи не менялись; использован только отдельный
Simulator `47A9B9ED-B2BD-405F-92BA-68407BAE31A3`, bundle
`com.amirtlinov.notebook.gui238`, по прямому указанию Амира. Портретный рендер
просмотрен: единая панель, два режима, каноническая бумага и slider x=7.
Геометрия и работа трёх режимов в горизонтали проверяются XCTest; обрезанный
headless framebuffer не принят за полную визуальную проверку горизонтали.

Открыты выпуск подписанной пары и production XPC `nb.export`, а также отдельная
общая приёмка: десять смешанных циклов/30 минут без перезапуска, голос,
восстановление связи, системные CPU/GPU/память/кадры. Десять отмен TeX из прошлого
прогона не заменяют эти циклы. GUI-199/205 не закрываются; GUI-238 остаётся
In Progress до интегрированной приёмки. Исторические архивы не затронуты.

## 19 сентября, 03:36 МСК — GUI-238 × GUI-241: общий жизненный цикл программ

К печатному срезу `8e51ac2` присоединена история GUI-241 до `f692113`.
Сохранены нативный исходник и canonical PDF; старый DOM-редактор не возвращён.
Mac source/export/identity 7/7 и отдельные checkpoint/retirement/causal ABA 4/4 PASS
(`gui241-mac1.log`, `gui241-mac2.log` в `.build/canonical-engine`).
Core state/native commands 21/21 в двух suites и browser lifecycle 12/12 PASS
(`gui241-core.log`, `gui241-js.log`). Проверено удержание runtime до durable writer
receipt и продолжение того же iframe после checkpoint. Скрытие листа режимом
«Код» на Mac ещё требует отдельного связывания с этим владельцем.
Физическая пара не менялась; условия GUI-199/205 этим прогоном не закрыты.

## 19 сентября, 03:18 МСК — GUI-238: один печатный движок, источник и экспорт

В рабочем срезе PDF/SyncTeX стали единственным макетом для экрана и экспорта.
Нативный TextKit-редактор использует прежние адресные команды, причинную отмену
и устойчивые черновики. Двойное касание бумажного блока и «Показать на листе»
используют карту именно установленного PDF. Markdown остаётся исходником своего
блока; произвольный TeX не конвертируется обратно в Markdown.

Заменены DOM-пагинация, textarea-редактор и отдельные Mac TeX/image subprocesses.
Один AOT WASM-движок со встроенными шрифтами работает без JIT и доступа к данным
приложения. Полная компиляция выполняется вне main actor. Ограничены VM, файловая
система, нормализация, вывод и декодирование; отмена последнего читателя снимает
реальное ожидание памяти. Лимиты не выдаются за измерение RSS всего приложения.

Mac 17/17 PASS, без skips/runtime warnings, на macOS 27.0 (26A428):
- физическая геометрия A4/Letter, растры двух плотностей, точная строка source↔PDF;
- нативная сессия: ввод во время save, общая последовательная undo, IME/draft,
  конфликт с агентом и явное разрешение;
- PNG/JPEG/SVG в настоящем PDF; статический export возвращает тот же PDF,
  export программ изменяет только их области, сохраняя векторный текст и ссылки;
- десять отмен бесконечного TeX с восстановлением без перезапуска, повреждённая
  SyncTeX в кеше, capped PDF sink и запрет host-file/external-SVG;
- >6 МиБ, 140 блоков, 35 SVG, 1680 формул: **4.020 с до canonicalReady**, 35 страниц,
  PDF 1 993 592 байта, peak accounted derived 39 156 734 байта; без layout-WebKit.
  Это одна локальная выборка, не p95 и не системная память/FPS.

Результат: `.build/gui238-canonical-mac-build/Logs/Test/Test-NotebookMac-2026.09.19_03-16-23-+0300.xcresult`,
лог `.build/canonical-engine/canonical-mac8.log`, измерение
`.build/canonical-engine/book-evidence/AE1BC627-A171-404E-A7C7-837004E59096.txt`.
Предыдущий Mac7: 14/16 PASS; два сбоя исправлены, не скрыты. SyncTeX g-records
уточняют реальную строку вместо следующего `\par`; base64-изображения извлекаются
как непрозрачные данные перед parse5, без повышения 2-секундного CPU-лимита.
MCP 16/16 + typecheck/generated-resource check PASS (`markup-types7.log`).
Core source/map/recipe: 13/13 + отдельные 3/3 locations PASS;
browser gesture 6/6, verification route 77/77, release route 66/66,
preview route 41/41 PASS. Эти наборы не заменяют проверки живого интерфейса.

Simulator6: 30/32 PASS. Двойное касание отправляло сообщение без documentID;
нативный receiver корректно отказывал. Сообщение теперь несёт полную установленную
идентичность. Второй сбой был неточным якорем фикстуры: она выбирала начало листа,
а не проверяемый дальний раздел. Якорь указан по реальному региону раздела.
Итоговый Simulator8: **9/9 PASS**, без skips/runtime warnings: четыре link/reading
проверки, физическая геометрия и четыре реальных UI-сценария исходника/режимов.
Результат `.build/gui238-canonical-simulator-build/Logs/Test/Test-Notebook-2026.09.19_03-26-36-+0300.xcresult`;
лог `.build/canonical-engine/canonical-simulator8.log`. В предыдущем Simulator6
также прошли все 15 engine/source/image/large проверки, три save/display receipt,
три program identity/state/failure и две фактической отмены/admission памяти.
JS gesture/message regression теперь 7/7 PASS (`browser-contracts5.log`).
GUI-241 checkpoint ещё требует интеграции.
Подписанная пара не обновлялась, физический iPad не использовался по прямому
указанию Амира. Системные ресурсы/кадры, голос, восстановление связи и 30 минут
смешанной работы остаются открытыми. GUI-199/205 не закрываются.

## 19 сентября, 01:53 МСК — GUI-238: единая верхняя панель и режимы по форме окна

В рабочей интеграции канонической печати убраны три независимо наложенные
верхние панели. Навигация, режим документа и инструменты используют один
оконный layout; узкое окно переносит элементы в две строки внутри одной панели.
Назад по-прежнему обрабатывает существующий владелец сцены.

На iPad вертикальное окно предлагает только **Лист / Код**, горизонтальное —
**Лист / Рядом / Код**. Поворот из «Рядом» в портрет переводит документ в «Код»,
не создавая другую сессию редактирования. Обратный поворот не меняет выбор
пользователя. Учитывается размер окна без клавиатуры, не физическая ориентация
устройства: клавиатура не добавляет третий режим.

По прямому указанию Амира проверка выполнена в отдельном Simulator
`47A9B9ED-B2BD-405F-92BA-68407BAE31A3`, iPad Pro 11, iOS 27.0 (24A434), bundle
`com.amirtlinov.notebook.gui238`, без установки на физический iPad.
**4/4 PASS**, без skips/runtime warnings: ширины панели 284/360/798/1158 pt;
число режимов и непересечение доступных кнопок в обеих ориентациях;
«Рядом» → ввод → портрет → продолжение в той же позиции → горизонтальный режим;
автосохранение → общая отмена → лист → тот же исходник.
Лог: `.build/canonical-engine/orientation-ui1.log`; результат:
`.build/gui238-canonical-simulator-build/Logs/Test/Test-Notebook-2026.09.19_01-51-00-+0300.xcresult`.
Просмотрен портретный снимок приложения с двумя режимами. У headless Simulator
ландшафтный framebuffer обрезается: его снимок не засчитан как полная визуальная
приёмка горизонтального экрана; геометрия и действия проверены XCTest.

Это локальный UI-срез незавершённой интеграции, **не новый выпуск пары**.
Общий движок, ограничения памяти/остановка, очистка заменённых путей и release
pipeline ещё не приняты целиком. Отдельный commit панели пока не сделан:
она зависит от ещё не завершённого native source workspace в том же рабочем дереве.
GUI-238 остаётся In Progress; GUI-199/205 этой проверкой не закрываются.
## 19 сентября, 03:14 МСК — GUI-240: интеграция выпущенной пары 116

В ветку визуализаций объединён завершённый `f638433` из
`codex/notebook-ipad-reliability`: прежняя реализация held zoom, видимых источников,
асинхронного mipmap и цельного eraser не заменяется второй. Сохранены GUI-241
checkpoint/source identity и GUI-242 package store во всех merged raster путях.
Package-контракт теперь **wire27 / manifest10**, отдельно от выпущенного 26/9;
история manifest9 читается, попытка объявить package в9 отвергается.
Установленная пользовательская пара 116 этим merge не обновлялась.

* Core: **38 PASS**, `/tmp/gui-242-release116-core-v1.log` — package admission,
  dependency closure, replication, inverse/undo и whole-object erasing.
* Mac: **10 PASS**, `.build/gui-242-release116-mac-v1/verification.json` — assets,
  importer и document program identities.
* Отдельный Simulator: **30 PASS**, `.build/gui-242-release116-sim-v1.xcresult` —
  assets, все AgentWebLeaseTests, независимая текстовая правка и три конфликтовавших
  PreparedAgentElementViewTests. Оба native прогона неизменны, source SHA
  `6b4d339fdd6fb0080422c7b40de206fe76a56703bc862939d90ef7101db99012`.
* MCP: **28 PASS** и pinned SDK check PASS, `/tmp/gui-242-release116-mcp-v5.log`,
  `/tmp/gui-242-release116-sdk-v4.log`. Первый ручной вызов не создал isolated IPC
  fixture host; повтор использовал настоящий собранный test host. После native
  receipt изменён только type-safe test присоединённого gear примера: размеры
  массивов явно проверяются, strict TypeScript больше не видит undefined/unused.
  Затем SDK check нашёл stale generated wholeElement return schema: оба штатных
  ресурса (sdk-reference.json/notebook-sdk.d.ts) регенерированы существующим
  генератором; isolated IPC test host пересобран перед итоговым MCP v5. Native
  receipt выше относится к предыдущему source SHA, Swift/UI code не менялся.
  Первоначальная запись SDK PASS для v3 была преждевременной; v3 завершился stale
  resource error, правильный завершённый PASS — v4.

GUI-240–243 остаются In Progress. Это scoped интеграционный прогон, не повтор
полной чужой приёмки 116 и не выпуск/physical/performance acceptance GUI-240.

## 19 сентября, 03:05 МСК — GUI-242: prepare не ждёт FIFO producer

После adapter-среза проверен ещё один локальный file boundary: Node prepare теперь
открывает файл с O_NONBLOCK/O_NOFOLLOW, затем проверяет regular file. Named pipe
отвергается до чтения, а не зависает до появления writer. Изменены только prepare
и его тест; native исходники не менялись. **5 MCP PASS** плюс pinned SDK check,
`/tmp/gui-242-prepare-fifo.log`, `/tmp/gui-242-prepare-fifo-check.log`.

## 19 сентября, 03:03 МСК — GUI-242: scoped WebKit reader на Mac и Simulator

Один `NotebookProgramAssets` обслуживает существующие spatial, document и passive
raster владельцы: пакет не становится inline JSON/String. Root HTML собирается
потоком вокруг прежнего bridge, CSS/JS/modules/assets читаются по адресу своей
публикации. GET/HEAD/206/416 и revoke/stop используют bounded reads <=1 MiB.
Mac iframe использует тот же вынесенный transport adapter для inline/package;
CSP каждого ресурса закрывает и worker. File navigation для child запрещена.

* **Mac 8 PASS**, `.build/gui-242-assets-mac-v9/verification.json`.
* **Собственный iPad Simulator 7 PASS**, `.build/gui-242-assets-sim-v11.xcresult`.
  Это независимый Simulator `3E0E27D3-C87A-40EB-B875-6D6571DC29D3`, bundle
  `.gui240-test`; физический iPad и установленные пользовательские контейнеры
  не затрагивались. Прямое указание Амира разрешает здесь параллельные независимые
  destinations/derived data, а не общую serial-очередь.
* На обоих source-before == source-after:
  `6ed12190e8c3254a432e412e34b0f1aba32ca1e69133a013b03ef6e2885b276b`.
  Skips и runtime warnings отсутствуют.
* Настоящий WK исполнил HTML и JS каждый >1 MiB, module import, worker с чтением
  своей JSON, CSS, SVG, WOFF2 и WAV metadata. Range пересёк границу 4 MiB у
  логического 300 MiB файла; fixture содержит две уникальные части, это **не**
  benchmark переноса 300 MiB уникальных bytes. Холодный новый владелец повторно
  открыл SQLite; проверены native iPad document owner, Mac/document iframe и
  passive raster с возвратом executor. Ни CDN, ни dev server для assets нет.
* Root CSP denial подтверждён браузерным событием. Worker читает разрешённую
  JSON и отвергает data URL; отдельный настоящий WK без CSP читает тот же data
  URL. Это контроль против ложного успеха из-за CORS, отсутствия сети или
  неподдержанного Fetch scheme. Parent DOM остаётся недоступен iframe.
* Native namespace tests: чужой origin/hash, encoded path/query, HEAD, suffix/
  unsatisfiable/multiple Range, отмена и revoke после первой части без поздних
  callback. Независимый текст сохраняет capability/heap; package -> inline
  немедленно отзывает прежний namespace и работает через тот же adapter.
* Shell JS **18 PASS**, `/tmp/gui-242-shell-tests-v3.log`; общий lifecycle bridge
  **12 PASS**, `/tmp/gui-242-bridge-tests-v1.log` (он не изменялся).

Отрицательные сигналы: opaque iframe запрещал worker — теперь только native-minted
package child сохраняет свой отдельный origin; inline child не ослаблен. Тест
сначала ожидал `ready` вместо реального receipt `declared`; исправлен тест, не
протокол. Raster fixture путал UIImage points и физические pixels; итог проверяет
CGImage 600x300 и pixelScale=1. Ожидание worker CSP event оказалось недостоверным
сигналом; заменено реальным fetch denial с положительным unrestricted control,
а не снятием CSP. Ранние результаты v1–v10 не объявляются итоговым PASS.

Это завершённый adapter-срез, **GUI-242 и GUI-240 ещё In Progress**. Живая доставка
и release-пара с новым контрактом, CloudKit, аппаратные метрики и длительный
совместный сценарий не подтверждены этим прогоном. Release116 другой задачи
резервирует wire26/manifest9: перед интеграцией/установкой нашего пакета нужно
объединить его завершённый commit и назначить package wire27/manifest10.

## 19 сентября, 02:27 МСК — GUI-242: причинная публикация и полная blob-зависимость

`programPackage` включён в прежний причинный source field для page/board/document.
Один источник — inline либо package; null действительно удаляет ссылку. Native
checkpoint, live identity и raster identity различают пакеты. Единственный row
writer отказывает публикации без всех частей. Direct delivery, CloudKit outbox и
snapshot несут closure текущего источника, inverse/undo и удержанных concurrent
source heads. Строки в state не превращаются в зависимости. ACK/dedupe не скрывают
пропажу части. Wire 26 / manifest 9 ограждают пару от прежнего decoder; старые
исторические manifests остаются читаемыми, но не могут объявлять programPackage.

* Core — **38 PASS**, пять затронутых suites, `/tmp/gui-242-dependencies-v4.log`.
  Последняя удержанная часть не публикует сцену и не двигает cursor; затем холодный
  peer читает диапазон через границу частей. Проверены три поверхности, source
  replacement, старый checkpoint, null → inline, snapshot с прежним пакетом,
  undo на холодном peer, concurrent heads и попытка smuggle в manifest 8.
* Native Mac — **5 PASS**, `.build/gui-242-publication-mac-v1/verification.json`.
  Включены importer и package replacement в native program/raster identities.
* Собственный iPad Simulator — **3 PASS**,
  `.build/gui-242-publication-sim-v1.xcresult`: прежняя программа не пишет в новую,
  origin move не создаёт raster заново, независимая текстовая правка сохраняет
  program context. Mac/Simulator шли параллельно с разными destinations/derived
  data, без физического iPad. На обоих source-before == source-after:
  `3ad8aa347c14d15d5288ac4fc318f76e85e28f67384e235ab73efffb532dbc49`.
  Skips/runtime warnings отсутствуют; compiler deprecation warnings старых
  XCTest UIWindow fixtures не являются runtime warnings.
* MCP — **27 PASS** и pinned SDK check PASS,
  `/tmp/gui-242-publication-mcp-v2.log`. Проверен именно CLI `prepare program`,
  затем маленькая animation transaction с package SHA для трёх поверхностей.
  Последняя правка после native receipt — только тест компактности SDK help.

Отрицательные результаты: v2 Core выявил null вместо отсутствующего optional в
канонической page projection — исправлен actual update path, v3 пять новых tests
PASS. Старый inverse test пытался опубликовать отсутствующую restoration root уже
на отправителе, где штатный indexCapturedFieldRestorations запрещает это. Фикстура
теперь имеет настоящую root на source и удерживает её именно на peer; native
validation не ослаблялась, итоговый v4 весь выбранный набор PASS. CLI prepare
раньше записывал descriptor, затем обращался к отсутствующему args — исправлен и
проверен запуском процесса. MCP v1: расширенная общая схема занимала 25 845 bytes,
на 245 bytes больше старого тестового 25 KiB бюджета; предел компактной справки
явно обновлён до 26 KiB, лимит исполняемых args не менялся.

Это storage/publication/transport-contract срез, **не завершение GUI-242**.
Scoped WK adapter, показ больших assets и офлайн UI ещё в работе. CloudKit outbox
проверен локально, живой Apple CloudKit этим проходом не подтверждён. Установленные
приложения не заменялись; физический iPad115 не понижался. GUI-240/242 не Done.

## 19 сентября, 02:09 МСК — GUI-242: ограниченный потоковый импорт

Первый, **не полный**, срез GUI-242: канонический manifest связывает namespace,
MIME, размеры и SHA частей по 4 MiB. Файлы остаются в прежнем SQLite blob store;
лимиты source/args и отдельного transport blob не повышены. Mac читает типизированный
локальный descriptor вне QuickJS. Каждый chunk проходит через существующую FIFO
очередь записи; между частями продолжаются обычные правки. Есть progress, cancel,
retry с дедупликацией и холодный status по принятому manifest. FIFO/device/final
symlink не могут зависнуть при открытии capability. Импорт не публикует сцену.

* Core package + replication: **12 PASS**, `/tmp/gui-242-package-v3.log`.
  300 MiB логический файл, bounded reads через границу частей, EOF, отсутствующие
  части, неверные SHA/MIME/пути, idempotence, no journal publication и отказ
  нерегулярным файлам. Предыдущий v1 compile FAIL исправлен, v2 — 11 PASS.
* Mac importer: **2 PASS**, без skips/runtime warnings,
  `.build/gui-242-import-mac-v2/verification.json`; source-before == source-after
  `94e48164e9c90b24b1cb2440412d331a3b8b30308cd499c081a80b927614c5bf`.
  Реальный 64 MiB файл из 16 разных частей и >1 MiB JS; небольшая запись принята
  до завершения импорта в той же очереди, cold status/retry не пишут journal;
  отмена до чтения не допускает manifest, повтор завершается.
* Node preparation/bridge/recipes/protocol: **38 PASS**,
  `/tmp/gui-242-files-v2.log`; отдельная фикстура готовит 300 MiB без Base64,
  metadata <20 KiB, относительные пути и SHA повторяемы. Финальный pinned TypeScript/SDK check — PASS
  (`/tmp/gui-242-check-v3.log`), MCP protocol/package/sidecar — **15 PASS**
  (`/tmp/gui-242-mcp-v3.log`). Check v2 выявил union string/Buffer только в тестовом
  socket callback; исправлено. После Mac v2 менялись только MCP текст/тесты.

Отдельный native WebKit probe (`.build/gui-242-wk-probe/`) подтвердил custom-scheme
classic/module/fetch/worker/image в Mac WebKit. Это не app-интеграция и не iPad.
Публикация ссылки в причинном содержании, dependency closure всех доставок/undo,
scoped WK adapter и offline-open ещё не реализованы. Установленная пара не менялась.
GUI-242 остаётся In Progress; принятие импорта не означает shown/received/offline.

## 19 сентября, 01:45 МСК — GUI-241: фон, закрытие и подтверждённый checkpoint

Checkpoint документа теперь сравнивает точные source/state версии и получает
квитанцию единственного durable writer до освобождения WebKit. Уход за пределы
рабочего набора не означает удаления: адресная запись завершает сохранение без
повторной загрузки всего документа. Spatial owner принимает новую причинную
версию из writer, поэтому задержанный SwiftUI echo не откатывает сохранённую фазу.
На Mac iframe получает эту квитанцию сразу, не ожидая перерисовки SwiftUI.

Фон, navigation boundary и закрытие используют прежних владельцев. Ошибка I/O
удерживает именно несохранённый heap/lease для явного retry; superseded source не
получает новых прав записи. Быстрые background → foreground последовательно
завершают pause/save/resume. Независимые программы сохраняются параллельно:
два зависших lifecycle не складывают deadlines и не задерживают здоровую программу;
ошибка скрытого checkpoint не запускает анимацию снова.

По прямому указанию Амира от 01:17 МСК дальнейшая проверка выполняется на отдельном
Simulator, параллельно независимым задачам, без общей очереди с физическим iPad.
`Notebook GUI-240`, `3E0E27D3-C87A-40EB-B875-6D6571DC29D3`, iPad Pro 11 M5,
iOS 27.0 / 24A434; отдельные bundle `.gui240-test` и derived data.
Это изменение маршрута этой задачи, не общее изменение AGENTS/verification runner.

Текущий source `64ddd493624d0963af44b39113a310be80727349f8db4d4ee42de2b24eb68ec7`:

* Simulator `.build/gui-241-boundary-sim-v6.xcresult` — **26 PASS**, без skips и
  runtime warnings, source-before == source-after. Включён настоящий XCUITest:
  первое касание четверти, L/C/U, play, Home/возврат, terminate/cold reopen,
  phase drag/reset/шаги в обе стороны — на доске и в документе. Камера и размер
  материала сохраняются. Это Simulator-жест, не физический iPad.
* Mac `.build/gui-241-boundary-mac-v7/verification.json` — **4 PASS**, без skips
  и runtime warnings, тот же source. В том числе повторный checkpoint/resume без
  промежуточного SwiftUI echo, удержание до writer и source ABA.
* Core — **35 PASS**, `/tmp/gui-241-boundary-core-v6.log`; Core после этого прохода
  не менялся. JS bridge/recipes — **24 PASS**, `/tmp/gui-241-boundaries-js-v4.log`;
  browser contracts после последней shell-правки — **13 PASS**,
  `/tmp/gui-241-boundary-browser-v4.log`; pinned TypeScript/SDK check — PASS.

Полный выбранный Simulator-набор v7 на том же app-source: **89 PASS/1 FAIL**.
Единственный FAIL — фикстура дальнего перехода запросила currentLinkOrigin раньше,
чем смонтированная бумага получила source receipt. После ожидания именно этой
границы `.build/gui-241-boundary-sim-v8.xcresult` — **1 PASS**, source
`15ae39c4425f6e3070828508e38a4ba5e83bb9c780cbec75bfd1c514c0504b16`, до/после совпадает.
Между v7 и v8 изменены только две строки теста, не код приложения. Это не
переименование v7 в общий PASS: сохранены обе квитанции и точная область повторов.

Последняя физическая проверка **до** смены маршрута: `.build/gui-241-boundary-v7/verification.json`,
**1 PASS**, source `66ea9eb9183eb118052e50b3607058aa65bf1767730a6da91c396aefa7661241`.
Она подтверждает сохранение/освобождение/возврат page WebKit, но не последний срез.

Отрицательные результаты сохранены. Physical v3/v5 выявили потерю причинной квитанции
и откат старым UI echo — исправлены и перепроверены. Simulator v1: 83 PASS/6 FAIL
(secure-context UUID фикстуры, запуск модели, typed error и AX switch). V2: 24 PASS/1 FAIL
(typed error ожидал прежнее имя). V3: 88 PASS/1 FAIL (тест тянул середину трека C,
а не его thumb); v4: XCUITest не получает AX scrubber endpoints от WebKit.
V5 остановлен: новая фикстура запросила три live slots в пуле на три, где один
зарезервирован под background. Пул не менялся, фикстура получила нужный четвёртый
слот. V6 использует реальные координаты thumb и прежние строгие утверждения.

Осмотрены все четыре четверти LC и финальные UI-картинки v6 после cold reopen
с L=170 мГн, C=85 мкФ, U=8,5 В: полные подписи/footer, единая фаза схемы/кривых/
энергии, органы управления внутри материала на обеих поверхностях. Источник
сравнения — эпизод Pure Tones из Sound: связь одного момента с геометрией и
кривой, спокойная композиция, соседние управления. Превосходство над референсом
не заявляется; это конкретная визуальная проверка, не автоматический screenshot gate.

Рабочая установленная пара и настоящие контейнеры/identity/trust этим срезом
не заменялись. Системные touch-to-photon/frame/CPU/GPU/memory пороги, десять
повторов, 30 минут и интегрированный выпуск остаются неподтверждёнными.
GUI-241/240 не Done; GUI-242–250 не реализованы этим изменением.

## 19 сентября, 00:16 МСК — GUI-241: причинная запись и остановка return-программ

В ветку интегрирована выпущенная база114 (`99b70dc`) без замены установленной пары.
Spatial checkpoint теперь несёт точные причинные версии id/content/css/JavaScript/state;
A → B → A отклоняется, независимая геометрия не мешает сохранению. Изменившаяся
source basis заменяет старый heap даже при побайтно одинаковом исходнике.
Ушедший документ сразу вызывает pause/checkpoint; подтверждённый runtime может
сохранить heap для возврата, но не продолжает часы до давления пула. Его обычный
допуск по-прежнему уступает foreground после сохранения.

Core: **22 PASS**, `/tmp/gui-241-causal-core-v4.log`. Physical iPad:
**4 PASS**, без skips/runtime warnings, `.build/gui-241-causal-return-v1/ipad.xcresult`,
source `4a54078af0c60bc6c1c29582ec0029222a289e600b2b0b63964550f3c3ca8333`. Mac: **2 PASS**, без skips/runtime warnings,
`.build/gui-241-causal-mac-v3/verification.json`, source `b6a41a49fa501d58144814f7ca30001f0ae5543dc834324d2df1899ce952962f`.
Разница source после iPad — только новая Mac-фикстура: secure-context-only
crypto.randomUUID заменён тестовым Math.random, ожидание проверяет также настоящий
hasLiveSource, а не старый отложенный ready callback. Ранние Mac v1/v2 FAIL сохранены.

При первом запуске другой владелец одновременно начал разрешённый ему Simulator
runner, не использовав наш общий lock. Пересечение обнаружено, дальнейшие серии
согласованы; данная задача Simulator не запускала. Итоговый Mac-only повтор шёл
после завершения чужого runner. Это не измерение производительности и не полная
физическая приёмка. GUI-241 ещё In Progress: фон/закрытие, живые пользовательские
жесты и визуальная/performance приёмка остаются открытыми.

## 18 сентября, 22:55 МСК — GUI-241: общий browser lifecycle, промежуточный срез

Изолированная ветка `codex/gui-240-visualizations` начинается от `e204211`.
`NotebookProgram/1` заменяет три определения API и отдельную preview-копию.
Сохраняются прежние владельцы WebKit, writer, transport и capture. Добавлены
ready/error, авторские pause/checkpoint/resume/dispose, revision guards и адресная
запись остановленного spatial state. LC-пример использует одну аналитическую
модель q/I/энергий, явные параметры и фазу; rAF не создаёт поток записей.

Промежуточный `.build/gui-241-native-v1/verification.json`: source
`13d0c69b72760b1c2a46e2de62842d55b234398c0fd3d8ba16098419e5d03866`,
**14 iPad + 2 Mac PASS**, без skips/runtime warnings. Это не финальный source.
`.build/gui-241-native-v2/ipad.xcresult`: **40 PASS, 2 FAIL, 1 прерванный тест**;
проход остановлен после зависания return-reclamation, положительной квитанции нет.
Checkpoint ошибочно ждал rAF уже скрытого WebKit. Ожидание удалено; границей
пикселей остаётся native snapshot, добавлен независимый native deadline 4,5 с.
Отдельный failed-composite сценарий ещё требует повторного разбора.

В v2 действительно отрисованы и осмотрены четыре четверти LC на физическом
`00008103-001E059934D9001E`, iPad Pro 11 (3rd generation), iPadOS 27.0 / 24A435.
Снимки: `.build/gui-241-native-v2-images/`. Найденная обрезка footer при 760×650
исправлена размером fixture 760×720; новый native render ещё ожидает проверки.
Standalone preview также осмотрен, но не заменяет WK и реальный жест.

Core — **20 PASS**, `/tmp/gui-241-core-v3.log`; MCP/bridge/recipes/science —
**32 PASS**; browser contracts — **13 PASS**. Pinned local TypeScript и проверка
сгенерированного SDK проходят. Final native repeat ждёт согласованного Xcode-слота
после параллельных 112/113; второй runner не запущен. Simulator не использовался.

Рабочая пара не обновлена этим срезом: установлен только отдельный `.native-test`.
Нужны финальный неизменный native cut, интеграция новых 111/112/113, жесты LC,
общий уход/фон/возврат/cold reopen и все пути уничтожения поверхности, а не только
штатное вытеснение по demand. Системные input/frame/CPU/GPU/memory, десять повторов,
30 минут и визуальный уровень референсов не подтверждены. GUI-241/240 не Done;
GUI-242–250 не реализованы этим изменением. Настоящие данные/identity/keys/trust
и исторические архивы не менялись.

### 23:40 МСК — финальный iPad source и фактическая граница UI

Срез `49b8e3d1fb99a29566fe183be6344f8e6f6c5713dbd1ea3fa0608af0719892ce`,
`.build/gui-241-native-v5/ipad.xcresult`: **14 native PASS**, без skips и runtime
warnings. Подтверждены фактическая остановка модели/кадра, отказ и stale writer,
четыре четверти LC, готовность/ошибки, освобождение return-slots и восстановление
сохранённого момента после пересоздания page WebKit. rAF в этом сценарии не пишет
состояние. Все четыре изображения `.build/gui-241-native-v4-images/` осмотрены:
footer теперь целиком внутри 760×720; источники LC между v4/v5 не менялись.

V3 обнаружил SDK-specific Swift Sendable ошибку в continuation с `Any`.
Нативный bridge теперь декодирует результат в `JSONValue` до передачи через
continuation; дубли декодирования в адаптерах удалены. V4 исполнил **69 PASS**,
но имел три неуспешных native сценария и отказ UI runner. Причины фикстур:
полный индекс дальнего документа надо запросить через `resolveLink`, а page host
должен наблюдать текущую модель, не хранить начальную копию после записей программы.
Эти сценарии исправлены без ослабления проверок и прошли в v5. Прежние положительные
JS-фикстуры объявляют `ready`; проверка отложенного state reply обращается к новому
controller вместо удалённой функции.

В v4 и v5 **UI-жест не стартовал**: XCTest сообщил `Timed out while enabling
automation mode`. Повтор не помог; устройство сообщает `passcodeRequired=false`,
`unlockedSinceBoot=true`. Успешной общей `verification.json` у этих проходов нет.
Mac-часть из-за отказа iPad-команды ещё не исполнилась. Слот 23:40 передан срочному
исправлению drag shadow; остаётся отдельный проход четырёх Mac-методов.
Рабочая пара 113 не заменялась. Это не UI/релизная приёмка GUI-241 и не выполнение
GUI-240 целиком; перечисленные выше открытые условия сохраняются. Spatial writer
пока проверяет source/state values и runtime token, а не полную причинную версию
показанного элемента: защита от ABA-замены остаётся обязательной частью GUI-241.


### 19 сентября, 00:01 МСК — Mac проверен на том же source

`.build/gui-241-mac-final/verification.json` — **4 Mac PASS**, без skips и
runtime warnings. Source остаётся
`49b8e3d1fb99a29566fe183be6344f8e6f6c5713dbd1ea3fa0608af0719892ce`,
совпадает с финальным iPad v5. Проверены checkpoint/отказ writer/согласованные
пиксели, сохранение browsing context при echo/чужом source, фокус и незавершённый
ввод при state/placement, высокое продолжение программы одним контекстом.
Начальная попытка штатно не стартовала из-за занятого Xcode; повтор после
свежей проверки владельца прошёл. Слот возвращён в21:00 UTC.

Финальные отдельные контракты: Core **20 PASS** (`/tmp/gui-241-core-v4.log`),
MCP/bridge/recipes/science **32 PASS** (`/tmp/gui-241-js-final.log`), browser
**13 PASS** (`/tmp/gui-241-browser-v6.log`), TypeScript/SDK check PASS
(`/tmp/gui-241-ts-final.log`). Mac-only квитанция не превращает отказ iPad UI
runner в успех. Реальный жест и полный GUI-241 остаются непринятыми.

Другой владелец установил рабочую пару **114** (`99b70dc`, после113). Эта ветка
не заменяла её и не является новым выпуском; перед будущим выпуском нужна
интеграция актуальной принятой базы без отката чужих исправлений. Полный план:
[GUI-240 — владельцы, вертикальные слайсы и приёмка](https://linear.app/main-cluster/document/nauchnye-vizualizacii-notebook-vladelcy-vertikalnye-slajsy-i-priyomka-238d0fc05b6e).
GUI-240 и GUI-241 остаются In Progress. Этот коммит фиксирует промежуточный
механизм lifecycle/checkpoint и LC-пример, а не завершение первого слайса или эпика.
## 19 сентября — GUI-200/255/257: дефекты 115 воспроизведены, исправление 116 проверяется

Снимки и жалоба Амира после установки 115 опровергают принятие прежнего среза
как законченного UX. GUI-255 снова In Progress; GUI-257 выделяет цельное
стирание SVG/HTML. Данные рабочего пространства не правились.

На физическом iPad изолированный native-сценарий
`canvas-ux-cursor-repro2` воспроизвёл отсутствие нового содержимого до lift:
SQL cursor продвинулся, coverage отвергал старую версию, а перечитывание
ожидало конца той же камеры. В новой реализации перечитывание принимает
свежий cut, сохраняя последнюю локальную камеру; Pencil/содержание не теряют
своей защиты. `canvas-ux-third` и `canvas-ux116-check` подтвердили прогресс
при продолжающихся camera samples без fingers-up.

В том же физическом маршруте подтверждены: новая SVG/бумага во время held
zoom, плотность смешанной сцены с тремя программами и двумя SVG, демонтаж
анимированного WKWebView по рабочему whole-element cut до lift, отсутствие
boolean geometry для 8192 samples. Снимок `Mixed scene during held zoom`
просмотрен: текст и тонкие SVG-линии различимы; это не замер FPS.
Холодный смешанный сценарий: firstVisible 0,555 s, firstShown 1,422 s
(0,867 s от входа в кадр). Это граница текущего сигнала, не «мгновенная» загрузка.

`canvas-ux116-check`: 96 PASS / 10 FAIL. Среди отказов — старые fixtures,
требовавшие невидимый parent, проверка UIKit с точностью 0,0001 pt после
pixel-aligned rebase, неверный direct-touch UI-тест Pencil и реальная лишняя
перерисовка тёплого растра (учитывался запрошенный минимум, не установленная
плотность). Причины исправляются, старый receipt не принят. Отдельный процесс
100 000 совпадающих объектов завершён signal kill без установленной причины;
этот стресс не объявлен пройденным и не входит в scoped UX acceptance.

Core: 19 тестов в трёх suites PASS (`canvas-ux-core-final.log`), включая
whole erase, undo/merge и queued manifest 4–8. MCP: native IPC round-trip
wholeElement PASS (`canvas-ux-mcp.log`); source-only TypeScript PASS.
Полный TS check имеет прежние ошибки в `test/science-examples.test.ts`, этот
неизменённый файл не исправлялся в срезе.

Финальный `canvas-ux116-accepted`: **105/105 iPad + 8/8 Mac PASS** на
неизменных исходниках SHA256
`3e258c970b171977416e6d03488c34bd6fc9a775b2073072f62d595184f53de4`.
Физический native Pencil-route (не датчик стилуса) прошёл recognizer →
model-owned targets → демонтаж двух WKWebView до lift → durable whole action
→ undo. Реальные UI-сценарии mixed controls и pinch/rotation повторно PASS.
В предыдущем проходе `canvas-ux116-final-check` iPad также 105 PASS; единственный
Mac-отказ был старым ожиданием одной публикации при 4x zoom вместо допустимого
одного LOD-rebase с тем же host. Проверка actual bounds/visible rect сохранена.
Подписанная Release-пара **0.3.113 (116)** собрана и установлена поверх
рабочих Mac и физического iPad. `canvas-ux116-build/build.json` и
`canvas-ux116-install/installation.json` фиксируют точные bundle/source hashes.
Mac завершён обычным AppKit terminate с дренированием записей. До повторного
запуска байты Notebook, Notebook.spaces, реестра пространств и activation
совпадают; реестр пространств iPad также побайтово сохранён. Uninstall,
восстановления архивов, сброса ключей/контейнеров и записей в доску не было.
Первоначальный preflight остановился до каких-либо изменений: искал старый
archive-marker на iPad. Проверка исправлена на существующий реестр пространств,
фиктивный marker не создавался.

Installed metadata подтвердили 116 на обоих устройствах; запущены Mac PID58807
и iPad PID10893. Живой установленный Mac MCP получил новую сессию iPad
`B15076EC-008D-492B-88F9-758FFC129D99`, прежний device
`5124BDCA-7613-4E48-B09B-928D81A03D4E`, прежнее пространство
`FAAAC405-8EF9-4FB9-9B93-CBD876FA97A4` и неизменный content/ink basis through1310.
`observe(includeImage:true)` вернул ready currentView; изображение просмотрено,
SHA256 `7bd692593b0fc2576a9b472f9855f9286196026849b5e32e7bf1630a5c5aa350`.
Сохранён сильный отдалённый ракурс пользователя; UI-проверка поворота оставила
landscape viewport. Это проверка установки/связи/показа, не новый замер жестов
или стилуса над пользовательским содержимым. Полная системная приёмка
FPS/CPU/GPU, десять повторов и 30 минут совместной работы не заявляется.


## 19 сентября, 02:01 МСК — GUI-200: интеграция и физический iPad 115

По прямому запросу Амира C1–C5 объединены в общей ветке
`codex/notebook-ipad-reliability` с уже выпущенным `99b70dc` (114): изменения
холста не откатывают исправления документов, камеры и Mac. Незавершённые
GUI-238/240 из чужих worktree не включены. Версия — **0.3.112 (115)**.

Итоговый неизменный source
`cd7e972883d7f99bb08d39650e34f02b1abb48adde7f59b2c870d4b8ba3dcd77`:
`.build/canvas-release115-release-check/verification.json`, штатный выбранный
маршрут — **81/81 physical iPad и 8/8 Mac PASS**, без skips/runtime warnings.
Проверены bounded ink/camera, composition reuse/readiness/priority, async capture
и cancellation, physical WebViewport, mixed button/slider/text + pan/pinch,
zoom открытого документа и тетради, Mac scene/camera. Это не полный performance
проход; соседние задачи по прямому разрешению Амира работали в отдельных
Simulator. Системные FPS/CPU/GPU, десять повторов и 30 минут не заявлены.

После merge два composition fixtures опирались на старое предпочтение native
labels перед WebKit. Теперь семь владельцев закрепляются явно: проверяется
именно общий static band, а не WebKit без смонтированного live consumer.
Production-очередь/приоритет не ослаблены. Первый широкий physical проход
`canvas-release115-native` также получил прежний signal kill в 100k coincident
fixture (он уже зафиксирован на baseline `3f30fb0` выше); причина не установлена.
Этот отдельный нагрузочный тест не включён в итоговый выбранный маршрут.
Начальный UI timeout Enable UI Automation разрешён Амиром на самом iPad.

**Граница ввода:** первый mixed physical UI завершился отказом после pan:
полная экранная клавиатура закрылась, значение осталось 760 вместо следующего
символа (`canvas-release115-accepted`: 77 PASS / 1 FAIL). Проверка затем прошла
и с экспериментальным ограничением responder forwarding, и на исходном
PhysicalWebViewport (`canvas-release115-focus-baseline`), и ещё раз в итоговом
проходе. В успешном снимке видна compact keyboard bar. Экспериментальные
24 строки удалены: причинность не доказана, неустойчивый сценарий полной
экранной клавиатуры не объявлен исправленным. Видео/снимки и неуспешные receipts
сохранены в `.build/canvas-release-20260919-preflight/`; условие отмечено в GUI-255.

Штатный `build-verified-pair.sh` собрал и проверил подписи обоих Release bundle:
`.build/canvas-release115-build/build.json`. Установлен **только iPad** поверх
`com.amirtlinov.notebook.preview` 114, без uninstall/копирования архива/ключей;
Mac **0.3.111 (114)** не изменён. Core, протокол и NotebookAppModel побайтово
совпадают с выпущенным 114. iPad binary UUID
`5FAB2272-1C66-34D2-8760-27CBA9FB798D`, manifest
`a3986083c36941dc887298ed7a4058e5de019389a7b5653fdf5c76bac500002b`.

Установщик iOS переместил data-container с D6367A69… в 886BEDC7…; проверка
буквального пути остановила наш orchestration до launch, не повторяла install.
Оба workspace UUID, размеры/mtime каталога и Notebook.spaces.json сохранены.
После штатного запуска PID **10372** установленный Mac MCP получил живую
selection iPad **5124BDCA-7613-4E48-B09B-928D81A03D4E**, прежнее пространство
**FAAAC405-8EF9-4FB9-9B93-CBD876FA97A4**, прежний frontier **1276** и ready currentView
открытого документа. Изображение просмотрено; pngSHA256
`e4762d4184b91ec256bafdc5550a61ccc1e275c0432fb38c2dfcc31792507216`.
Квитанция установки/запуска/живого чтения —
`.build/canvas-release115-install/installation.json`. Сопряжение не выполнялось
заново; историческое содержание не восстанавливалось. GUI-256 по-прежнему
условно отменён, более широкие условия GUI-200 остаются открытыми.

## 19 сентября, 01:16 МСК — GUI-255 завершён; GUI-256 не требует усложнения

После `c73ebc7` iPad mipmap строится вне MainActor в существующем
CompositionPixels. В UI остаются WebKit callback и короткая публикация.
Исходный CGImage/точные pixels сохранены; grant и submitted WebKit borrow
живут до фактического завершения работы. Перед публикацией повторно проверяются
source/state, load token, установленный live owner и отмена capture; уход
источника не превращается в ложный resource-limit. Старый синхронный цикл
удалён, второй cache/worker pool и увеличенные квоты не добавлены.

Финальные проверки одного неизменного источника
`38b90e4942c7c08dc88d9f487fc003e818e46e5a11616c1781bd1c8b5fbd870e`:

- Simulator `.build/canvas-plan-20260918/c5-complete.xcresult`: **23/23 PASS**,
  включая все AgentWebLease, отмену после async yield, source replacement,
  live DOM/crop/density, source priority, native installation и mixed WebKit
  pan/pinch: button, slider и text first-responder сохраняют принятый ввод.
- Mac `.build/canvas-plan-20260918/mac-native/`: **16/16 PASS** штатного
  `./verify.sh --only --test NotebookMacTests/SceneCameraPlaneTests --test
  NotebookMacTests/SceneRasterCompositionTests`. Проверены камера, painter
  order/alpha/clipping, bounded streaming, WebKit lifetime и input cancellation.
  Оба финальных прохода — без skips и runtime warnings.
- Предшествующий `c5-accepted.xcresult`: **91 PASS / 1 FAIL** из 92.
  Composition/Prepared/resource pressure/первый native Pencil и UI прошли;
  новый cancellation-тест ошибочно запрещал даже штатный initial readiness=false.
  Исправлена именно эта проверка: запрещён ready=true от отменённых pixels.
  Повтор всего AgentWebLease — `c5-fence.xcresult`, **20/20 PASS**, затем 23/23
  выше после дополнительного live-capture fence. Production ради PASS не ослаблен.

Прежние три passive fixtures не вызывали model.start: loadState=loading
правильно запрещал admission, WebKit даже не создавался. Теперь fixtures
проходят настоящий startup и проверяют permitsBackgroundPreparation; все три
прошли в c5-accepted. Priority fixture проверял порядок завершения при двух
параллельных executors: для проверки очереди явно задан один background slot.
Квота production осталась прежней. Неуспешные c5-final/targeted сохранены.
Два ручных unsigned Mac запуска остановились в packaging до тестов; штатный
signed selective route выше прошёл без изменения упаковки или sandbox.

В финальном Simulator receipt 2048×1536 mipmap + fence заняли **14.36 ms**
вне main; main task исполнился во время await, весь grant **33,997,696 B**
оставался учтён, отменённый source не опубликован. Для 301×173 сохранены
исходные pixels, десять mip levels и единый charged lifetime. Это проверка
исполнителя/согласованности и локальное время, не системный frame-time.

**GUI-256 — Canceled без новой реализации.** В настоящих tile presenters двух
нативных плоскостей здоровый источник установлен через **18.68 ms** после
готовности pixels, пока сосед с 5-секундным ready promise ещё pending.
Peak accounted **23,464,960 B**; синхронная публикация плоскостей при уточнении
**0.612 ms**, начальная **10.547 ms**. Уже существующий atomic cohort не ждёт
готовности всех источников. Условие для дополнительной частичной установки
не подтверждено; менять согласованность слоёв/receipts ради неё не требуется.
По той же измеренной причине GUI-255 не заменяет paintID на geometryID и
не переписывает hosting root: это не подтверждённое узкое место данного среза.
Warm reuse C3 уже избегает повторного ImageRenderer неизменной композиции.

Приложения рабочих устройств/данные не менялись. Использован Simulator по
указанию Амира, не физический iPad; Mac — изолированный подписанный test host.
Снимки и timing receipts: `c5-complete-images/`, `c5-accepted-images/` внутри
того же evidence каталога. Просмотрены mixed UI и native first-stroke pixels.
Физические FPS/CPU/GPU, десять повторов и 30 минут не заявлены. Срезы C1–C5
закончены; более широкие документные/системные условия GUI-200/GUI-199 остаются
открытыми. Новых Xcode runners после передачи слота в 01:15 МСК нет.

## 19 сентября, 00:32 МСК — GUI-254: ранний demand и видимая очередь

После `692d237` известные источники ограниченного scene workset предъявляются
прежнему scheduler до native preparation и placeholder pass. Дополнительные
находки потокового painter присоединяются к той же очереди. Задание владеет
source identity до publication, а не требует уже опубликованного placeholder.
Сортировка: видимое без fallback → видимое уточнение → bounded overscan,
затем расстояние до центра; обязательные live runtime не дублируются.
Принятые этим же проходом новые pixels гасят собственную dirty notification,
не вызывая идентичный повторный проход. Квоты WebKit/байтов не увеличены.

Simulator `.build/canvas-plan-20260918/c4.xcresult`: **51/51 PASS**, без skips
и runtime warnings. Нативное событие первого composition tile подтверждает,
что background source уже работает; z-visible завершился раньше a-neighbour,
несмотря на их имена. Уточнение проверки последовательности см. в записи GUI-255.
Проверены readiness, pending-neighbour, ранняя отмена, source/state changes,
input barrier, быстрые camera samples, warm return/eviction, ресурсы и mixed
WebKit pan/pinch с сохранением принятого ввода. Это порядок исполнения и
затронутые сценарии, не физический frame-time benchmark.

## 19 сентября, 00:28 МСК — GUI-253: reuse готовой композиции

После `493bd2d` preflight заимствует совместимые composition entries из
существующего SceneRenderResources, а не только из предыдущей когорты.
Готовность и зависимости хранятся на той же budgeted entry, без удержания
старой когорты или дополнительного кеша. Placeholder не становится cache hit;
новый WebKit capture отзывает reuse зависимых записей, не показанные leases.
Проверка publication order не даёт запоздалому painter вернуть старую запись
в reusable. Crop, density, painter range и revision сохраняют силу.

Simulator: `c3.xcresult` — **85/85 PASS** (composition, resources, environment).
`c3-accepted.xcresult` — **3/3 PASS**: A→B→A возвращает те же entryID у native
и восьми static SVG sources; старая когорта освобождена; pending/new capture,
revision change и реальное бюджетное eviction не возвращают старые пиксели.
Document pinch UI прошёл в `c3-final.xcresult`; этот промежуточный bundle
в целом FAILED из-за слишком короткого ожидания восьми заданий ограниченной
background-очереди. Диагностика показала шесть ready и два работающих, а не
resource failure. Финальная проверка ждёт завершения очереди с пределом 10 s,
не подменяет readiness таймером. Warm-return/bytes receipt сохранён в
`.build/canvas-plan-20260918/c3-accepted-images/`. Это published boundary,
не утверждение о scanout или физическом FPS.

## 19 сентября, 00:18 МСК — GUI-252: устойчивые LOD и pixel keys

После `22ea1fd` финальный occupancy probe сохраняет предыдущий LOD; при
бюджетном coarsening гистерезис не мешает движению к меньшему плану. Растры
тайлов используют 512/1024/2048 px и не колеблются вниз внутри того же LOD.
Мировые элементы/чернила исключают continuous camera scale из pixel identity;
обложки/порталы сохраняют эту зависимость, viewport/state/revision не удалены.
Crop coverage отделён от density refinement. Source density использует
полуоктавные ступени; пригодный crop/density сохраняется во время короткого
жеста, длинный pinch выходит из диапазона 0.6…1.6. Native ink также уточняется
после выхода из диапазона, без ожидания конца бесконечного жеста.

`c2-final.xcresult` в `.build/canvas-plan-20260918/`: **46/46 PASS** на том же
Simulator, без skips/runtime warnings. Финальная сетка и keys проверены на
возвратном pinch 0.99↔1.01; source/state/revision и зависимость портала остаются
различимыми. Проверены cropped coverage/refinement, delayed WebKit readiness
при непрерывном pinch, sparse/dense painter, byte pressure, remount, реальные
UI-жесты mixed controls и passive SVG после rotation. Первый проход выявил
излишне грубую source-density ступень: таблица получала canonical density 1
вместо достаточной <1. Исправлен production выбор ступени; проверка не ослаблена.
Физические FPS и время input→scanout не заявляются.

## 19 сентября, 00:09 МСК — GUI-251: конечный запас native ink, Simulator

По прямому указанию Амира этот срез проверен в **Simulator**, не на физическом
iPad; рабочая пара и её контейнеры не тронуты. База `87bf916`. Native backing
использует свободные края 512-pixel pools и ограниченный запас 64 px с каждой
стороны; refill начинается до края. Covered pan, включая settlement, больше
не меняет GPU basis. Плотность уточняется только при увеличении масштаба,
истощение покрытия и resize по-прежнему готовят согласованный successor.

`.build/canvas-plan-20260918/c1-final.xcresult`: **37/37 PASS**, 0 skips,
0 runtime warnings, iPad Pro 11-inch M5 / iOS 27.0 (24A434). Проверены оба
направления и ориентации, zoom-out 1%, неизменность drawable/mesh при движении,
атомарная установка нового basis, удержанный контакт, resize, handoff и первый
Pencil, смешанный WebKit pan/pinch. Отрицательная регрессия до изменения:
`c1-before.xcresult` (1 regression fail, 1 UI pass). Первый тест дополнительно
исправлен: default scale камеры равен 0.22, поэтому pan задаёт scale 1 явно.

Retina 834×1194 использует прежние 4×5 pools, теперь целиком 1024×1280 pt.
Под 128 MiB настоящих passive rasters первый ввод на больших экранах принят:
30/35 pools, native reservation 63,408,576 / 73,976,256 bytes, без resource
failure. Просмотрен снимок resize с прежней линией и новым первым штрихом.
Артефакты и byte receipts: `.build/canvas-plan-20260918/c1-final-images/`.
Это доказательство затронутого поведения и учёта памяти, **не измерение
физических FPS, CPU/GPU или полной плавности**; GUI-200 остаётся в работе.

## 18 сентября, 23:32 МСК — GUI-238: исходник, общая отмена и точная карта печати; пара113

В `codex/notebook-print-layout` на базе `1cf56f8` сохранение исходника блока
переведено с прямой записи на существующий причинный исполнитель `updateBlock`.
Адресный CAS проверяет исходный текст **и его авторскую версию**; запись действия,
публикация и завершение устойчивого черновика атомарны. Повтор сохранения возвращает
ту же квитанцию. Обычная отмена документа работает после холодного открытия;
чужие последующие правки и независимое состояние программы не перезаписываются.
Save дожидается окончания собственного контакта через существующий input owner,
а не обходит общий барьер. Отдельного command/undo-пути не добавлено.

Настоящий Mac-компилятор теперь сохраняет SyncTeX вместе с PDF. Конвертер строит
диапазоны строк → ID блоков при сборке точного TeX, без поиска повторяющихся
абзацев и без интерполяции ID в исполняемый TeX. Карта привязана к хешам полного
причинного снимка, исходника и PDF. Пакет, включая обе карты, публикуется атомарно;
`nb.exportStatus` возвращает их пути/хеши/размеры. Старый снимок не становится
разрешением перезаписать новый текст. Это **адресация печати, не подключённый
переход касанием страницы к исходнику**.

Проверки собственного среза:
- Core **18/18 PASS**: исходник/CAS, перезапуск, последовательная human/agent undo,
  ABA-конфликт, UUID aliases, атомарная публикация карт; 99 000 посторонних clocks
  дают 8 887 SQL VM steps для commit и 594 для повтора. Лог
  `.build/print-source-core-final.log`.
- MCP **29/29 PASS**, typecheck и проверка generated resources PASS;
  `.build/print-map-sdk-final.log`. Это не весь набор Core/MCP.
- Итоговый неизменный selected-проход `.build/gui238-source113-final-v4/`:
  **15/15 физический iPad + 2/2 Mac PASS**, без skips/runtime warnings.
  Source SHA-256
  `a66f36e8f2c8c6aafd730d3c426b85416f514790dd687c0b3e908f1591be01e3`.
  На iPad проверены правка → Save → дальняя ссылка → холодное открытие →
  обычная отмена двумя пальцами. Нативные проверки подтверждают сохранность
  независимого состояния/экземпляра живой программы. Mac действительно
  скомпилировал PDF с кириллицей, формулой, SVG и ссылкой; проверены SyncTeX gzip
  и принадлежность карт тому же снимку/PDF, без удержания writer компилятором.
  Просмотрены снимки сохранённого текста и последующей отмены; изображения
  отдельно от квитанции: `.build/gui238-source113-images/`.

В этот же неизменный проход интегрированы установленные исправления109–112
и GUI-233 `03cf876`/`f9b7c99`: pinch не выходит из открытого листа, минимальный
fit/pan и восстановленная закладка ограничены листом. Включены четыре native
camera-теста, три затронутых iPad UI-сценария и Mac reader-fit. Полный системный
FPS/CPU/GPU/memory-проход этим не подменяется.

Неуспешные попытки не засчитаны: v1 обнаружил недождённую очередь фикстуры и
ошибку Save; v2 после исправления ожидания показал неполную document-фикстуру
(нет SpatialInk root/reference owner). Фикстура теперь создаётся штатным атомарным
workspace-путём, production не ослаблен. v3 прошёл Save/холодное открытие, но
XCTest отправлял двухпальцевое касание в status bar по выходящей за экран рамке;
целевой точкой стал видимый заголовок. Только v4 — итоговый PASS.
Подготовительный Mac-проход `.build/gui238-source113-pdf-check/` остановлен до
Xcode для интеграции camera-исправления и также не засчитывается.

Подписанная **0.3.110 (113)** собрана из этой квитанции
(`.build/gui238-release113/build.json`) и установлена поверх112 на Mac и iPad.
Mac завершён штатно; заменён только bundle, совпавший с manifest. iPad in-place
install/launch подтверждены devicectl; установленные version/build совпадают.
`.build/gui238-install113/` хранит preflight и квитанции. Live SDK установленного
helper возвращает новые поля карт; `nb.read(runtime)` после запуска — `connected`.
Контейнеры, содержимое, идентичности, ключи и исторические архивы не менялись.
Runners выполнялись последовательно; слот передан GUI-241 после установки113.

**GUI-238 остаётся In Progress.** Ориентир Амира — один исходник и связанные
«Лист / Рядом / Код», а не двусторонняя конверсия произвольного TeX/Markdown.
Пока не подключены: этот интерфейс, канонический PDF в существующей сцене,
двусторонняя навигация по координатам, фоновая перекомпиляция с последним успешным
листом и живые программы на канонических страницах. Автономный iPad typesetter
ещё не допущен: native checkpoint не останавливает все фазы; исследованный
WASI-кандидат также не доказал общий memory cap (Mac peak RSS около843 МиБ
при лимите linear memory512 МиБ). Его compile-only iOS-проверка не является
физическим доказательством. Ни один экспериментальный движок не включён в
рабочую пару. Точная идентичность шрифтов/страниц Mac–iPad, десять повторов и
30 минут смешанной работы остаются открытыми; GUI-199/205 не закрываются.

## 18 сентября, 22:17 МСК — GUI-238: автономный typesetter, не новый редактор

В отдельной ветке `codex/notebook-print-layout` от `b8fd376` реализован
воспроизводимый физический прототип `Tests/NotebookTypesetterProbe/`.
Tectonic 0.16.9 (`66b6654103501b0a4a6926a7c450264be59cf927`) с портом CoreText
исполняется на iPad; прежний `notebook-markup.js` готовит тот же TeX локально.
Дистрибуция закреплена существующим TeXResources.lock, SHA-256 ZIP
`c508958589f4c18218f98a7785ff21af901fb2460106e9a11d7b7bf065204487`.
Зависимости native-кандидата имеют отдельные pins/Cargo.lock; совпадение его
геометрии с нынешним Mac-компилятором этим **не доказано**.

Подписанный `com.amirtlinov.notebook.typeset-probe` установлен отдельно на
физический iPad Pro 11 (3rd generation), iPadOS 27.0 (24A435).
22:17:13 МСК: **25/25 компонентных проверок PASS**. Проверены физические MediaBox
A4/Letter, извлекаемый русский текст, формулы, таблица, пакет mathtools,
настоящая PDF Link annotation, отказ чтения тестового частного файла контейнера,
ошибка TeX и десять циклов бесконечный макрос → deadline → успешная новая вёрстка
без перезапуска. Вёрстка не обращается к Mac/helper/сети; это не тест разрыва
и восстановления связи всей рабочей пары. Просмотрен растр полученного PDF,
не выдаваемый за снимок нового Notebook UI.

Повторная вёрстка одностраничного теста: 0.602–0.614 с, медиана 0.613 с.
`phys_footprint` после этих десяти операций — 244–249 МиБ; это не peak,
не измерение кадров и не 30-минутная стабильность. Прототип держит один открытый
ZIP index; измеренные ранее накопления autoreleased JS/PDF объектов ограничены
границей операции. Полный bundle занимает около 1.4 ГиБ на диске.
Квитанции, логи и PDF: `.build/print-layout-spike/`; SHA-256 executable
`2dc421fba02789fcf1f8e9e62f8c1f3edb7aa20d9d7b9c7c1a25b8a8849e2c3e`,
physical receipt `06dc0095488f97a81a42d75ccb18aa6bac5a191a71f91d66352bac57bc427fa6`.
Источники проверены повторно по квитанции после физического выполнения.

**GUI-238 остаётся In Progress; пользовательский результат ещё не реализован.**
Проверенный checkpoint покрывает `get_next`, но не все PDF/font/BibTeX-фазы;
жёсткая граница времени/памяти и переносимая идентичность шрифтов остаются
условиями допуска. Source map к блокам, общий command/undo-путь, редактирование
в канонических страницах, живые программы, сохранение/повторное открытие и
совпадение экранного Notebook с PDF ещё не подключены. Производственный экран,
Mac export и рабочая пара этим срезом не заменяются. Контейнеры Notebook,
идентичности, ключи и исторические архивы не затронуты. Xcode/device runners
исполнялись последовательно по согласованному слоту. GUI-199/205 не закрываются.

## 18 сентября, 20:23 МСК — GUI-205: множественный выбор на физическом iPad

На базе `bdeb1ff` добавлен единый атомарный путь одиночных и множественных
нативных правок: перенос, шесть выравниваний, копирование с переназначением
внутренних привязок, удаление и порядок наложения. Общий writer проверяет все
показанные исходники, включая неизменяемые опоры; любое устаревание отклоняет
весь пакет. Действие имеет одну обычную причинную отмену. Выбор публикует точные
ID агенту и замораживает те же источники существующим attention owner.
Рамки выбора разрешают один граф поверхности на образец движения; SQLite не
получает промежуточные движения. Новых WebKit, камер и журналов Undo нет.

Изолированный физический проход `.build/graphics-selection108-ipad-pilot/`
завершился **6/6 PASS** (4 native + 2 UI), без skips и runtime warnings.
Source `71a285e7d2a39a150b0cd5b2437127f204e723a273d56f3ed6a4bca328c7713d`;
iPad Pro 11 (3rd generation), iPadOS 27.0, build 24A435. На листе и доске
проверены выбор двух узлов и стрелки, общий перенос, выравнивание, копирование,
удаление оригиналов, холодное повторное открытие и следование скопированной
стрелки за скопированным узлом. Соседняя живая программа сохраняет экземпляр
JavaScript и счётчик. Просмотрены снимки переноса и восстановления; экспорт
лежит отдельно в `.build/graphics-selection108-ipad-pilot-images/`.
Нативно подтверждены отсутствие записи при preview, отмена всего контакта
Pencil, ограничение целой конструкции листом и точные источники агента.

Core/ScriptHost: 14 + 6 тестов выбранных контрактов PASS; в том числе
последовательная отмена, удаление/возврат чернил, copy order, недопустимые ID,
шесть перестановок конкурентных записей на реальных SQLite с повторениями,
перезапуском и сохранением поздней агентской подписи. MCP: 79/79 PASS, typecheck
PASS. Логи: `/tmp/notebook-selection108-core-final.log`,
`/tmp/notebook-selection108-peer-regression.log`,
`/tmp/notebook-selection-mcp-test.log`.
Старая фикстура конфликтующих ink claims падала `blobMissing` также на чистом
`bdeb1ff`: она передавала receipt без его обязательных inverse blobs.
Теперь она использует штатную адресную доставку и staging blobs; production
не ослаблен. Перестановки и сгруппированная доставка повторно прошли.

Это физическое доказательство выбранного среза, **не установка рабочей пары**:
использован отдельный native-test bundle. Рабочее обновление 108 ожидает
интеграции параллельного 107. Данные, идентичности, ключи и исторические архивы
не тронуты. Runners выполнялись последовательно по согласованному слоту.
Постоянные вложенные группы, расширенный текст, оставшееся распознавание и
полный профиль tldraw ещё не завершены. Десять повторов, 30 минут совместной
работы и системные кадры/ресурсы этим проходом не доказаны. GUI-205 и GUI-199
остаются открытыми.

### 20:43 МСК — совместный срез с Mac107, без установки

Собственный `4735b40` опубликован; Mac107 `1a06705` интегрирован как `a1faa77`,
сохранены независимая навигация и оба пути выбора. Wire25 понимает набор фигур.
Источник `aad43b8e7fdd4dd19da6e056e25ac253f22a5ce656453ad642e838ade4e13096`,
`.build/graphics-selection108-final/`: **23 iPad + 4 Mac PASS**, без пропусков
и runtime warnings; MCP PASS. Дополнительный SwiftPM проход — 10 Core + 6
ScriptHost PASS (`/tmp/notebook-selection108-integrated-core.log`).
Фикстура current-view теперь публикует подлинное peer presence: локальная
камера Mac не подменяет отсутствующее присутствие iPad и не инвалидирует его
квитанцию после независимого движения. Production-контракт не ослаблен.

Обновление рабочей пары **не выполнено**: после приёмки Mac107 Амир обнаружил
дефекты существующих обложек и открытия листов, GUI-233 переоткрыт. Исправление
его владельца требуется до выпуска108. Xcode/iPad освобождён в20:43 МСК;
известный дефект не скрывается успехом выбранных проверок графики.

## 17 сентября, 14:19 МСК — GUI-208: поля и центрирование системной иконки

После замечания Амира исправлена композиция внутри системной плитки, а не сам
утверждённый рисунок. `render-app-icon.sh` масштабирует знак до 84% прежнего
размера и центрирует его окрашенные границы, включая обводку переплёта.
Канонический SVG и оба template-PNG меню не изменены; 11 app-PNG заменены.
В исходнике 1024×1024 фон непрозрачный; измерение окрашенных пикселей с порогом
6/255 даёт следующие поля (антиалиасинг объясняет разницу в два пикселя):

| Edge | Pixels |
| --- | ---: |
| Left | 183 |
| Right | 181 |
| Top | 173 |
| Bottom | 173 |

Все 13 PNG побайтно воспроизводятся. Выбранный профиль `verification` завершил
79 verification + 75 release тестов без ошибок; полный native/UI-проход не
запускался. Перед запуском дождались освобождения общего lock; runners
одновременно не стартовали. Source
`119f0c1e3d23728af564efac3712a5252015c7ad230f2420d7b8cd78a6d6d867` отличается
от предыдущего установленного `efe67e80…` только генератором и 11 app-PNG.
Свидетельства проверки и подписанной пары:
`.build/notebook-icon-spacing-20260917/`,
`.build/notebook-icon-spacing-release-20260917/`.

Release 0.3.62 (65) установлена поверх рабочей пары с прежними bundle ID.
Mac завершён штатно, bundle заменён атомарно без backup; подпись, executable,
`Assets.car` и `AppIcon.icns` совпали со сборкой. Физический iPad обновлён одной
in-place установкой и запущен. Просмотрен новый системный PNG iPad 528×528
(`isPlaceholder=false`): видимые поля свободны, края книги не подходят к маске.
Также просмотрена иконка установленного Mac из `NSWorkspace`; menu template
по-прежнему 18×18. Квитанции и фактические изображения:
`.build/notebook-icon-spacing-install-20260917/`.
Пользовательские данные и ключи не удалялись и не переносились; настройки
доверия и CloudKit не менялись. Обмен пары не проверялся. Чужие незавершённые
изменения и Simulator не использовались.

## 17 сентября, 13:56 МСК — GUI-208: утверждённая иконка установлена на Mac и iPad

`Applications/AppIcon.svg` побайтно совпадает с утверждённым Амиром тонким синим
блокнотом. Прежний рисунок и все 11 PNG заменены без резервных вариантов.
Один `render-app-icon.sh` получает из него непрозрачные системные иконки на
светлой бумажной подложке и прозрачный template-знак строки меню Mac; прежний
`book.closed` удалён из `NotebookMacApp`. Проверка воспроизводимости включает
обе группы ресурсов. Иконки не зависят от исходного файла в Downloads.

`actool` Xcode 27 скомпилировал оба настоящих каталога без warnings/errors.
Все 13 PNG побайтно воспроизводятся; iPad-исходник 1024×1024 не имеет alpha.
AppKit загрузил `NotebookStatusIcon` из скомпилированного каталога как template
18×18. Выбранный профиль `verification`: 79 verification + 75 release тестов,
без ошибок; это не полный native/UI-проход. Свидетельства:
`.build/notebook-icon-20260917/`.

Основная ветка fast-forward обновлена до завершённого актуального `ffd03f3`;
чужой worktree не изменялся. Новая пара сохраняет исправление запуска и текущий
wire 16: относительно проверенного source `bc50f6b5…` изменены только 18 входов
иконок, их генерации/проверки и строки меню. Source
`efe67e8088b44d22dd6c85545edf59a732da323a23573902426dc89e42b8be4d`,
подписанная Release 0.3.62 (65): `.build/notebook-icon-release-20260917/`.

После явного согласия Амира пара установлена поверх актуального выпуска.
Mac завершён штатно и bundle заменён атомарно без backup; подпись, executable,
`Assets.car` и `AppIcon.icns` установленного приложения совпадают со сборкой.
Mac UUID `C6A18343-6DFE-3139-9624-ACF7D15DAC22`. iPad обновлён одной командой
in-place install и запущен с прежним bundle ID, именем и версией. Контейнеры,
ключи, настройки CloudKit и архивы не удалялись и не переносились; новый путь
data container назначила ОС при обновлении. Simulator не использовался.

Просмотрены **системные**, а не только исходные иконки: `NSWorkspace` вернул
новый Mac-значок; физический iPad через `devicectl device info appIcon` вернул
новый 528×528 PNG, `isPlaceholder=false`. Иконка меню загрузилась из уже
установленного bundle как template. Квитанции, изображения и ограниченный
runtime-readback: `.build/notebook-icon-install-20260917/`.
Mac сохранил workspace, ревизию доски и 7 предметов. После обновления публичное
состояние соединения — `disconnected`, окно сопряжения ожидает iPad; доверие
этой задачей не менялось. Визуальная приёмка иконок не выдана за проверку
парного обмена или работоспособности всех функций приложения.

## 17 сентября, 12:46 МСК — GUI-205: непрерывная геометрия между lift и сохранением

Физический dense-сценарий на `871e15a` действительно выявил дефект, а не сбой
UI automation. Диагностика `.build/graphics-dense-contact-probe/` подтверждает
capture `native-circle`, live admission и полный delta `(38,26)` в end. В
`.build/graphics-dense-commit-probe/` общий исполнитель сохраняет перемещение;
сразу после lift показано старое положение, затем появляется правильное.
После диагностического ожидания та же граница проявилась на bend: 0 вместо 70.
Значит, преждевременно удалялся draft, а не терялся контакт или привязка.

Владение конечным draft теперь переходит от завершённого контакта к принятой
общей команде. Только принятый SQL-срез с cursor не старше её записи передаёт
показ каноническим данным. Контуры, связи, ручки и accessibility остаются на
одной геометрии; смена выделения, поздний cancel и новый Pencil не отменяют
уже принятую запись. Пока старая версия не заменена, она не допускает новый
перенос. Отказ CAS убирает draft, не переписывает конкурирующие поля и сообщает
причину. Камера, writer и undo остаются прежними; WebKit на фигуру не добавлен.

Промежуточный source `40fdb9a23ef8f163f5a5777d3d8b871bd23a5b365e2ccdc3ec2e19e9bbcf10d5`:
`.build/graphics-draft-handoff/`, **38 PASS / 1 FAIL**. Все три настоящих UI-жеста
прошли: bound board 37,47 с, bound page 37,21 с, dense 39,64 с. Единственный отказ
новой native-регрессии — ошибочная агентская fixture без исходной reference
для перемещения (`composition_scope`), а не обход CAS. Fixture исправлена;
добавлена проверка реального SQLite `BEGIN IMMEDIATE` и более старого SQL-среза.
Плотный PNG `.build/graphics-draft-handoff-attachments/0734698A-3847-43B9-AD96-E79F0BE10B4D.png`
просмотрен: перенесённый узел, следующая за ним D1, изгиб и изменённая подпись,
соседняя программа Count 1 / 78seed. Координаты, допуски, немедленные UI-проверки
и physical Pencil guard не менялись; временные logs/ожидания удалены.

Финальный source `eedb8a7106876b26f7ff5d900c55567e40ff77aa5ca1781c475fa6ebd6bfb3fc`:
`.build/graphics-draft-handoff-final/verification.json` — **PASS выбранной области**:
**40/40 физических iPad-тестов** (37 native + 3 UI) и **3/3 Mac**, без skips и
runtime warnings. Исходники до/после совпали и соответствуют рабочему tree.
Проверены неизменённые UI-сценарии листа, доски и плотной схемы, включая
сохранение/холодное открытие, подписи, изгибы, удаление и живую программу.
Обе новые native-регрессии прошли: ожидающий настоящий SQL writer/старый срез
не сбрасывают показ; отвергнутая команда не меняет конкурентную геометрию и
не создаёт квитанцию. Повторены отмена контакта/Pencil, resize, недопущенный
объект, последовательная отмена и модельные Pencil-owner сценарии.
Финальные dense и page PNG в `.build/graphics-draft-handoff-final-attachments/`
просмотрены; тестовый синтетический Pencil не выдан за настоящий набросок.

Это не завершение GUI-205 или GUI-199: настоящие Pencil-наброски и калибровка,
зависимости вне окна, группы/множественное редактирование, форматированный текст,
остальное распознавание, весь закреплённый импорт tldraw и смешанная длительная
приёмка остаются открытыми. Используется только физический iPad и изолированная
`.native-test`, runners последовательно. Рабочая пара, контейнеры, идентичности,
ключи и исторические архивы этой работой не изменялись.

## 17 сентября, 02:04 МСК — GUI-205: зависимый допуск при уменьшении детализации

После `c7b2d4a` исправлен отдельный дефект: статическая связь больше не оставляет
подвижными свои нативные концы. Снятие допуска замыкается по привязкам и целым
painter-runs; закрепление любого затронутого конца запрещает это уменьшение
детализации. Обратное не требуется: живую связь можно редактировать при
неподвижном статическом узле, не превращая весь циклический граф в растр.
Новый/пассивный графический элемент не принимает невидимый перенос или resize,
пока его не допустил установленный состав. Выбор остаётся обычным запросом сцены.

Source `9231bbcb1d1dd94c61587069e22accdb5444d712d6bc2e9df6de3664ae358366`:
**38/38 physical native + 3/3 Mac render PASS**, 0 skips/runtime warnings,
`.build/graphics-vector-dependencies/`. Исходники до/после совпали. Новый тест
читает настоящий SQL-порядок шести разделённых runs, цикл связей из трёх узлов,
регистронезависимый UUID-якорь, pins и отсутствие растровых дублей. Второй
не допускает скрытый commit до публикации фигуры. Повторены старые resize,
отмена контакта/Pencil, последовательные движения, конкурирующие правки и
Pencil-owner сценарии листа/доски. Их физические PNG просмотрены:
`.build/graphics-vector-dependencies-attachments/`.

Это не новая UI-приёмка: синтетический Pencil и модельный перенос не заменяют
реальный жест. Сбой включения UI automation, плотный жестовый сценарий,
зависимости вне загруженного окна и полный объём GUI-205 остаются открытыми.
Рабочая пара не обновлялась; использовался только изолированный `.native-test`.
Результат не переносится на GUI-199 или длительную смешанную приёмку.

## 17 сентября, 01:55 МСК — GUI-205: нативные пакеты и адресный допуск

Фигуры допущенного окна больше не занимают слоты живых программ. Один Canvas
рисует соседний авторский run; скрытый/off-window сосед сохраняет границу
порядка. Поле ввода существует только у редактируемой подписи. Камера и контакт
остаются у прежней сцены. Необязательная детализация может уступить растрам,
не удаляя источник или закреплённый объект. Пустые диапазоны не выделяют пиксели.

Неизменный source `80e83a1c9e4217a00f38c74dc58f6d4eff7d46e281506b07ddff38acdaa38ecc`:
**25/25 physical native + 3/3 Mac render PASS**, без skips/runtime warnings,
`.build/graphics-vector-single-owner/`. Повтор выполнен после удаления
неиспользуемого второго пути фигуры из `SpatialElementContent`: нативным
показом владеет только пакет. Новые проверки охватывают 30 фигур
с материалом между двумя runs, 40 разорванных off-window соседями runs и
10 закреплений, порядок и причинное доказательство, уменьшение детализации
без замены материала. Снимки реального iPad из принятого Pencil-owner пути
просмотрены (`.build/graphics-vector-bounded-attachments/`). Контакты Pencil
синтетические; это не оценка качества живых набросков и не системный FPS.

**44 Core PASS**, `/tmp/notebook-graphics-vector-final-core.log`, source
`3e888eb5397399c63dcfd1a611040a2e9bbdac242da47235f36aa431d69eac4e`.
Core, его тесты и Package.swift побайтово совпадают с `80e83a1c…`.
Реальные 100000 SQLite-элементов одного владельца выявили скан порядка:
старый запрос для 96 элементов превысил 50000 VM steps. После диапазона
составного индекса — **7878 steps**. Индекс позиций тоже читается по адресу,
в одном WAL-срезе, а не сканируется по каждому объекту.

Широкий прогон **не прошёл**: новый source дал 25/28, исходный `3f30fb0`
(`05105379…`) — 23/26. В обоих те же три отказа: ColdSourcesFailLocally…,
ReturnBoundaryReadsCurrentParent… и HundredThousandCoincidentSources…
(signal kill, причина не установлена). Полные имена и результаты сохранены
в `.build/graphics-vector-budget-native/` и `.build/graphics-vector-baseline-native/`.
Они не объявлены новыми регрессиями или успешной полной приёмкой.

**UI и обновление рабочей пары не приняты.** Два запуска до сценариев завершились
`Timed out while enabling automation mode`; `.build/graphics-vector-admission/`
и `.build/graphics-vector-ui/`. Новый плотный UI-сценарий ещё не исполнен.
Хотя выбранные native/Mac тесты прошли, `validate_selected` обоснованно
отклоняет эту квитанцию для выпуска: изменённая UI-фикстура требует жестового
сценария. Этот запрет не обходился. Устанавливалась только `.native-test`;
рабочие контейнеры, ключи, пара и архивы не менялись, Simulator не использовался.

Остаются связи вне допущенного окна/растровой детализации, группы, полное
множественное редактирование, rich text, остальное распознавание и закреплённый
импорт tldraw. GUI-205/199 открыты; 10 повторов и 30 минут не подтверждены.

## 17 сентября — GUI-205: привязанные связи на листе и доске

В существующий графический элемент добавлена связь: независимые причинные
поля концов, привязок, изгиба, наконечников и подписи. Производная геометрия
общая для нативного показа, попадания, адресного чтения, пространственного
индекса и рендера. Перенос узла не переписывает координаты связи. Удаление
узла скрывает зависимую связь; неизвестный конец остаётся ожидающим, а не
считается удалённым. Отмена сохраняет поздние чужие связи и перечисляет их
как зависимости. Сохранённые чернила не копируются и не воскрешаются.

Draw-and-hold дополнен прямой и непрерывной одноштриховой стрелкой. На обоих
носителях доступны перенос, ручки концов/изгиба, многострочная подпись,
цвет/толщина/пунктир и девять наконечников. Это не многоштриховое распознавание
и не полный профиль tldraw. Пороги остаются гипотезами до калибровки Pencil.

Физический iPad Pro 11 (3-е поколение), iOS 27 `24A435`, отдельный
`com.amirtlinov.notebook.native-test`, source
`545e6d7e4e2dda2c2e9d470154c8ae61066c44f6725ddee6e32cc65512a9a0f1`:
**41/41 PASS** (39 native и два UI-сценария), без пропусков/runtime warnings.
`.build/graphics-gestures-checked/ipad.xcresult` и `ipad-summary.json`.
Настоящие пальцевые жесты перемещают узел, меняют изгиб и подпись, затем
проверяется холодное открытие и удаление. Соседняя программа сохраняет runtime,
счётчик и первый responder (`78seed` без повторного фокуса после переноса).
Полноэкранные PNG просмотрены: `.build/graphics-gestures-checked-attachments/`.
Это не системное измерение CPU/GPU/кадров и не ручная выборка Pencil.

Сохранены отрицательные попытки и исправлены их причины:

- `graphics-physical-checked` (`ddeaa754…`): 62 native PASS, два UI FAIL.
  На доске второй tap-recognizer камеры ошибочно снимал выбор связи по её
  сохранённой рамке вместо производного контура. Дублирующий tap-путь удалён;
  выбором и снятием выбора владеет один `NotebookSelectionGesture`.
- На листе ошибочным был критерий роста ширины рамки при изгибе: точки выхода
  на эллипсы тоже сдвигаются. В реальной SQLite уже сохранился bend
  `-69.42251552822562`. Теперь проверяются движение ручки/связи при неподвижном
  узле и та же геометрия после холодного открытия. `graphics-editor-probe`
  отдельно подтвердил эту цепочку. Диагностические prints удалены.
- Ранний физический запуск выявил ошибку логического адреса свежей SQLite:
  Foundation по-разному нормализует существующий `/private/var` контейнер и
  отсутствующий JSON-файл (который вообще является записью, не файлом).
  Логические ключи больше не разрешаются как файловые пути; добавлена
  воспроизводящая регрессия. 49 Core-проверок прошли в
  `/tmp/notebook-graphics-path-core-sealed.log`.
- После 41 физического PASS сборка Mac остановилась на старом неверном
  отступе JS внутри Swift multiline string в `DocumentRuntimeTests` (`dd3fe2b`).
  Исправлен только отступ. Эта попытка не имеет общей успешной квитанции.

Выбранный повтор текущего среза завершён успешно в
`.build/graphics-connectors-verified/verification.json`, source
`05105379fa362b078c92b6821e0bc54a1a44d51255866e39219edc91b850541b`:
**95 физических iPad-тестов** (93 native + те же два UI), **3 Mac native**,
**54 MCP**, **64 release** и **79 verification**. Исходники до/после совпали.
Mac-рендер проверяет фактические кривые и девять наконечников без WebKit,
а также обратимое представление без изменения измерений чернил. Это выборочная
квитанция, не полный PASS ветки. Рабочая `.preview` пока не обновлена:
SQLite admission 6 / wire protocol 15 требуют согласованной пары.
Контейнеры, ключи и исторические архивы не изменялись. Simulator не запускался.

**GUI-205 остаётся открыта.** За пределами квоты `liveOwners` статические связи
доски ещё не следуют предварительному переносу узла. Нужна нативная композиция
с сохранением порядка, не увеличение WebKit-квоты или наложение поверх сцены.
Также остаются группы, множественное редактирование, свободный rich text,
остальные фигуры/многоштриховое распознавание и весь закреплённый импорт.
GUI-199, десять тёплых повторов и 30 минут смешанной работы не закрыты.

## 17 сентября, 00:16 МСК — подготовка больше не появляется поверх основного окна

Физическая диагностика установила причину увеличенных чернил при закрытии
тетради: iPadOS возвращал служебный `UIWindow`, которому задавали координаты
за экраном, в `(0, 0, 834, 1194)`. При парковке в нём показывались реальные
canvas в исходном масштабе. Это видно в `.build/camera-basis-diagnostic/console.log`
(`INK_PARK`, 1789591801.293602), а не выведено из успешного теста камеры.

Отдельное окно удалено. `NotebookPreparationHost` размещает Metal/WebKit в
обрезанном, не принимающем ввод дочернем UIView за пределами основного окна.
Освобождение владельца снимает UIView. WebKit создаётся только после получения
этого окружения, поэтому ранний отказ не оставляет частично созданный runtime.
Квоты памяти не увеличивались; Mac, содержание и протокол не менялись.

На физический iPad установлена совместимая Release **0.3.62 (65)**, source
`cf72bd79be7da69ac82d3478f452aaf9d4ef9c60f65207aa14360885d0a1f07e`,
UUID `33D75C1F-9B5D-33DB-A3A2-8E53523FEE14`.
Сборка, подпись, in-place установка и запуск: `.build/preparation-host-final/`.
Она не включает незавершённый графический протокол GUI-205; установленный Mac
сохраняет совместимость. Данные/ключи не удалялись, диагностические prints
в финальной сборке отсутствуют. После требования Амира Simulator не запускался.

На устройстве проверены выход из тетради и двусторонний pan, а также возврат
из дальней главы к первой странице через настоящие группы миниатюр;
`working-route.xcresult`, видео и просмотренные PNG в `shots/` того же каталога.
Вспышки подготовительных чернил в неверном масштабе на двух повторах больше нет.
**Соседние материалы всё ещё появляются с задержкой после закрытия.** Финальные
кадры содержат их, но этого недостаточно: непрерывность и отзывчивость камеры
не приняты. 50 мс p95 и 4 мс главного потока на кадр не подтверждены.

Пять адресных native-регрессий выполнены на физическом iPad:
`.build/preparation-host-native/physical-ready.xcresult`, source `d062ee277f54ffd760066cd93d1a39b54da29200014e7244ef03c813748c62c0`.
Они проверили геометрию/освобождение host, действительные пиксели и прозрачность
WebKit, восемь последовательных программ и атомарную передачу камеры Metal.
Тестовая сборка отдельная (`.preparation-test`), после прогона удалена.
Исходники обоих прогонов сверены после завершения; это не полная приёмка ветки.

Отрицательные попытки сохранены: native XCTest начинал работу до
`foregroundActive`; тестовая фикстура теперь ожидает реальное активное окно,
не создаёт второе и не меняет runtime-допуск. Старый UI-драйвер ожидал
«Страницу 1» внутри группы 13–17 и оставил обзор открытым; следующий поиск
поэтому не начался. Использован существующий сценарий с переходом между
группами, без изменения приложения ради теста. Первое открытие и дальняя
ссылка в том отказавшем сценарии действительно состоялись; весь он не принят.

## 16 сентября, 20:41 UTC — камера принимает палец во время возврата, но непрерывность ещё нарушена

Снят запрет pan до завершения пружины: новый контакт прерывает доведение камеры
на последнем принятом положении. Передача доски больше не отклоняется из-за
общего лимита **идентичностей** старых и новых владельцев. Реальный общий бюджет
байтов сохранён. Пакет пространственных проб пустых тайлов читает один WAL-срез,
а не открывает SQLite заново на каждой ячейке/полосе.

Узкая проверка `.build/camera-continuity-check5`: настоящий mounted pan во время
трёхсекундной пружины, передача при восьми удержанных исходящих идентичностях,
256 адресных SQL-ячеек и отбрасывание устаревшего среза, существующие проверки
бюджета/пустых тайлов и настоящий двусторонний drag Simulator. Это регрессии
конкретных причин, не измерение отзывчивости физического приложения.

В 20:30 установлена Release-пара без удаления контейнеров/ключей:
`.build/camera-continuity-pair/build.json`, source
`7bb1d650eba68efc62dcdd26ab9336d2dbe8af9bf6e81b0008f46a8b0043749a`,
iPad UUID `5E07B8B0-5BB3-3087-B757-CE59D3B9E32A`. Она включает исправление
отказанного checkpoint из предыдущей записи, но не незавершённую GUI-205.
Публичный readback подтвердил прежние содержимое листа (revision 21) и блок
документа; `.build/camera-continuity-install/installation.json`.

По двум отдельно разрешённым системным 30-секундным трассам того же короткого
маршрута поиск → открыть тетрадь → закрыть pinch → pan туда/обратно:

| Time Profiler, только Notebook | До | После |
| --- | ---: | ---: |
| Сумма CPU samples всех потоков | 12,444 CPU-с | 9,268 CPU-с |
| Главный поток | 3,573 CPU-с | 3,741 CPU-с |
| Пробы тайлов, inclusive (один sample считается один раз) | 1,964 CPU-с | 0,409 CPU-с |

Данные: `.build/seven-slices-physical/working-camera-before-2012.trace` и
`working-camera-after-2032.trace`, символы соответствующих Release dSYM,
`*-notebook.json`. Перед сравнением установленная версия прошла один тёплый
повтор. Это **одна пара наблюдений**, не p95 и не доказательство ускорения всего
интерфейса; главный поток не улучшился. Задержку начала pan на 2–3 секунды этот
драйвер достоверно не воспроизвёл. Зависание 11,82 с в первой системной трассе
принадлежит тестовому Runner, а не Notebook.

**Физическая непрерывность не принята.** На видео после закрытия тетради соседний
документ ещё появляется поздно, а чернила на короткое время показаны в неверном
масштабе. Окончание жеста и отсутствие crash этого не исправляют. Следующий срез
должен устранить разрыв между установленными пикселями и их камерой/возвратным
набором. Цели 50 мс p95, 4 мс главного потока на кадр и отсутствие пропусков
содержания остаются неподтверждёнными.

## 16 сентября, 19:40 UTC — отказ checkpoint не блокирует весь пул

В продолжении тёплого возврата найден и воспроизведён дефект: программа
отказала в сохранении состояния и правильно осталась живой, но общий пул
навсегда считал её вытеснение незавершённым. Следующий запрос не мог освободить
даже другую простаивающую бумагу. Отрицательная регрессия
`.build/document-return-checkpoint-before` завершилась `attempted=true web=3
queued=1`, не ошибкой фикстуры.

Теперь тот же владелец завершает отказанную попытку, не освобождая реальный слот
и не уничтожая несохранённую программу. Существующая очередь выбирает следующий
доступный ресурс. `.build/document-return-checkpoint-fixed`: та же регрессия,
два сценария возврата и общий пул — **48 native**, без skips/runtime warnings,
source **182eb0b0642a9dff648014ad23bc9d35d750b044f06c5550094461f2a46ea2b1**.
Повтор возвращает именно прежний работающий WK программы после отказа.

Release-пара собрана отдельно от GUI-205, подтверждение —
`.build/document-demand-final-pair/build.json` (`verified-build`, source `182eb0b0…`).
Установленная пара пока остаётся `3f62b7b1…`: на iPad появился новый Pencil-ввод
(revision 21), поэтому повторный
перезапуск отложен до свободного момента Амира. Новое содержание не откатывается
к данным перед предыдущей проверкой. Это исправление конкретного зависания,
не подтверждение целей общей производительности.


## 16 сентября, 19:18 UTC — GUI-205, преобразование принадлежит принятому вводу

Устранён разрыв времени жизни: результат удержания передаётся вместе с принятыми
измерениями, а не более поздним UI callback. Владелец принятого ввода регистрирует
общую команду преобразования до освобождения очереди; Save/shutdown ожидает её.
На доске регистрация также синхронна с завершением Pencil-контакта. Нового журнала
или обходного пути сохранения нет. Это устранение найденного при review риска,
а не утверждение о воспроизведённой потере пользовательских данных.

Неизменная копия `.build/graphics-input-final-source`, SHA256
**dbbbdf80633b8c3b769939f7307d732c0ad53a8ffb8ec8a18967143aee0bdd55**:
**45 native tests PASS**, без failures/skips/runtime warnings;
`.build/graphics-input-final-evidence/verification.json`. Проверка включает
совмещённые runtime-изменения адресной подготовки документов, позднее закреплённые
в `dd3fe2b`. Все 873 исходных файла сопоставлены после прогона без несовпадений.

Новые проверки монтируют настоящую UIKit-сцену листа и доски, подают 121 измерение
существующему Pencil-владельцу, удерживают, завершают контакт и сразу закрывают
модель. Повторное открытие SQLite подтверждает геометрию, прежний UUID и точные
измерения; доска проверена со смещением и масштабом установленной камеры.
Отдельный барьер задерживает подготовку принятого ввода во время shutdown.
Это синтетические контакты, **не физический Pencil и не оценка качества**.
Core/MCP/Mac в этом узком follow-up не прогонялись заново; их предыдущая область
указана ниже. Физическая пара не менялась; полная GUI-205 и GUI-199 остаются открыты.

## 16 сентября, 19:29 UTC — адресная подготовка, тёплый возврат и видимые chunks

Убрана работа, а не добавлено ожидание: первый лист получает манифест и только
запрошенные блоки с исходниками для редактирования; автоматическая подготовка
всего хвоста заменена текущим листом и двумя следующими. Одно место возврата
удерживает прежнюю бумагу и программы в существующем вытесняемом бюджете.
`InkCanvasView` выбирает chunks через пространственный индекс до доступа к
вершинам/GPU; прежний полный обход chunks удалён. Геометрия, порядок пера/ластика
и правила сохранения не заменены приблизительными.

На iPad и Mac установлена Release-пара source
**3f62b7b1647a2a754bb3b35d659a6e9326f65f32e67f59e20a3270515b2a67cd**,
iPad UUID **12C2641F-FF6E-3CEF-BB93-FE34F4AE52CC**. Это копия `e5de9b9` с данным
срезом, без параллельного изменения графического протокола GUI-205.
`.build/document-demand-pair/build.json` и `.build/document-demand-install/`
фиксируют обычное in-place обновление; публичное чтение подтвердило неизменные
данные/допуски, затем сохранённую реальную правку документа (source counter 2).

Короткий физический маршрут **открытие → листание → дальняя ссылка → возврат →
правка → повторное открытие редактора** выполнен на этой паре:
`.build/seven-slices-physical/short-working-route-1913.xcresult`.
Отдельный native Back → обложка → открытие → редактор тоже выполнен:
`native-back-1928.xcresult`; полные XCUIScreen PNG листа и редактора просмотрены.
Три предшествующих попытки этого маленького драйвера не прошли: он ожидал
accessibility Button у растровой обложки, затем принимал выбор/фокусирование
обложки за её открытие. Отказы сохранены (`native-back-1923/1925/1926`),
production-путь ради драйвера не менялся. Приложение находилось в узком системном
окне iPadOS; старый `app.screenshot` обрезал его по неверному началу координат.
Полный снимок подтвердил читаемый лист, а не пропавшее содержание. Компоновка
верхних кнопок в таком узком окне всё ещё тесная; адаптивный UI этим не исправлен.

Адресные native-регрессии `.build/document-demand-ready-6`: **14 выполнены**,
без пропусков/runtime warnings. В частности, непрочитанный хвост >16 МиБ не
кодируется до первой рабочей страницы; возврат сохраняет WK, DOM и счётчики
MathJax/раскладки; давление слотов сохраняет состояние программы перед удалением;
пространственный запрос 8192 chunks сохраняет точный результат и порядок.
Совмещение с GUI-205 отдельно скомпилировано и проверено в
`.build/graphics-input-final-evidence` (45 native, source `dbbbdf80633b8c3b769939f7307d732c0ad53a8ffb8ec8a18967143aee0bdd55`).
Это другая область, не установленный физический бинарный файл.

**Цели 50 мс p95 и 4 мс/кадр не достигнуты и не подтверждены.** Четыре различных
request→installed одного маршрута: 1260/486/282/80 мс; первое content-ready —
187 мс. Installed включает окончание жеста/передачу UIKit, не только подготовку.
После Save диагностическая AX-запись повторяла старый request ID: она исключена
из замера повторного открытия. 90-секундная системная трасса
`short-working-route-1913.trace`: sampled CPU 26,806 с, main 9,209 с суммарно,
footprint peak 592,6 МБ / end 424,8 МБ. Это не время одного кадра и не сравнение
до/после. Крупные оставшиеся стеки: SQL-чтения, подготовка истории (3,217 с
inclusive), paint order и подготовка соединений. Нативный полный документ,
полный индекс для далёкого якоря, инвалидирование при изменении источника,
дисковое сохранение готовых фрагментов и системные кадры остаются открыты.
Общая производительность/долгая приёмка не объявлены успешными.


## 16 сентября, 19:00 UTC — GUI-205, первый нативный графический срез

Поверх `e5de9b9` реализован **только первый срез**, не весь план: круг/эллипс
на листе и доске, измеренный Pencil draw-and-hold, непосредственный перенос
пальцем, многострочная подпись, общие человеческие/агентские команды,
обратимое скрытие и последовательная причинная отмена. Ссылки на исходные
штрихи не копируют измерения и не меняют их `isActive`. Канонический journal
и маска представления разделены; рендер, адресное чтение и SQL spatial index
используют одну проекцию. Новых WebKit на фигуру и нового журнала отмены нет.
Изменение требует согласованной пары: transport protocol **14**, SQLite **5**.
Установленная физическая пара и её данные этой задачей не менялись.

Неизменная копия `.build/graphics-slice1-source`, source SHA256
**12bf6275e6d547a5fa34bafc13ea9a78df8492caeb4a62f13d1aaf4192509f75**:
выбранный `./verify.sh --only --profile mcp` с явными native/UI tests —
**PASS**, `.build/graphics-slice1-evidence/verification.json`.
**51 MCP, 2 Mac native, 68 iPad native/UI**, 0 failures/skips/runtime warnings
в Xcode summaries. Это не `--full` и не release/installation receipt.
Все 872 исходных файла квитанции повторно сопоставлены с текущим tree:
несовпадений нет. Отдельный SwiftPM-прогон на том же Core до добавления
Mac-only теста: **135 тестов / 7 suites PASS, 21,497 с**,
`/tmp/notebook-graphics-core-final.log`; он не включён в sealed verify receipt.

Проверены следующие живые границы:

- Два настоящих SQLite: перестановки, повторная и сгруппированная доставка
  пересекающихся преобразований; исходники выбираются целиком. Последовательная
  отмена, защита от независимого возврата того же значения, сохранение последующей
  чужой правки и причинное восстановление после перезапуска.
- MCP → реальный изолированный IPC/Core: записать измерения → преобразовать →
  агентская подпись → удалить → отменить удаление/подпись/преобразование.
  Байты исходных измерений не изменились. Установленный production MCP/JS SDK
  с новым бинарным владельцем ещё не проверялся.
- UIKit: измеренные, не предсказанные точки существующего Pencil-контакта,
  удержание/продолжение, отказ и отмена; контроль очереди команд и native controls;
  оба порядка доставки касания между выделением и камерой, передача двум пальцам.
- Настоящие XCTest-жесты на листе **и** доске: первое нажатие кнопки соседней
  программы, её фокус, перенос нативной фигуры без удержания и без сдвига камеры,
  ввод в прежний responder без повторного выбора, тот же runtime nonce,
  перезапуск с сохранением позиции/состояния, двойное касание подписи и удаление.
  Эти UI fixtures создают исходную фигуру общими командами; настоящий Pencil
  не генерируется XCTest. PNG `native-graphic-board-moved` и
  `native-graphic-page-moved` из итогового `ipad.xcresult` просмотрены.
- Mac native raster: геометрия / скрытие / точное возвращение чернил и ключ маски
  при неизменной версии raw ink; графика не запрашивает WebKit source.

Первые UI-запуски обнаружили конфликт выделения с page curl: поздняя отмена
допускала UIKit-перелистывание и ожидание quiescence XCTest. Раннее определение
владельца нативного объекта устранило конфликт, не записывая действие на touch-down.
Прерванный запуск `test_sim_2026-09-16T18-43-14-120Z_pid44729_edaf12d1.xcresult`
не считается PASS или замером FPS. Отдельный sample показывал преимущественно
idle main thread; он не доказывает отсутствие других задержек. Ошибки новых
фикстур (не созданный journal и недоступный `crypto.randomUUID` custom-origin)
исправлены в фикстурах, не ослаблением production-контрактов.

**Открыто:** физический draw-and-hold и повторное открытие на iPad, качество
на настоящих/отложенных набросках, сравнение задержек с исходной версией,
системные CPU/GPU/кадры/память. Связи, группы, свободный форматированный текст,
множественное редактирование, остальные классы распознавания и закреплённый
tldraw-профиль ещё не реализованы. GUI-205 остаётся In Progress. GUI-199,
десять тёплых повторов, 30 минут смешанной работы, голос и восстановление связи
этой проверкой не закрываются.

## 16 сентября, 17:29 UTC — закрытый обзор перестаёт владеть подготовкой

Адресная диагностика в `seven-slices-page-stall-diagnostic` собрана из
неизменной копии `6eeeb92c…`, отдельно от параллельной незавершённой GUI-205.
Только iPad обновлён in-place диагностическим бинарным файлом; Mac, ключи
и контейнеры не заменялись. Это диагностика, не release-квитанция.
Оба физических повтора завершились отказом (77,250 и 123,178 с).

UIKit сохранял **восемь закрытых миниатюр** двух обзоров. Их `window == nil`,
но владелец продолжал учитывать их как читателей и держать растры. Один такой
рендерер получил `rendered` и вернул frame evaluation, но остался ждать RAF
квитанции вне окна до `document_preparation_timeout`. В другом повторе
сцена отказала при 127 341 904 pinned / 613 480 passive-reserved bytes:
предварительная проверка читала ledger, но обходила освобождение ресурсов.

Теперь native attachment обновляет единственного владельца документа:
отсоединённые миниатюры снимают page demand и pins; их off-window исполнитель
отменяется, повторное присоединение того же host восстанавливает страницу.
Физический лист и незавершённая передача UIKit сохраняют собственный договор
удержания. Scene preflight обращается к прежнему `SceneRenderResources.makeRoom`,
прежде чем отклонять состав. Новых кешей, квот и таймеров нет; выдача реальных
ресурсов после каждого await остаётся обязательной.

Регрессия preflight до правки не вызвала reclamation и не смогла построить
статическое покрытие (`seven-slices-visibility-before-v2`). Регрессия закрытого
обзора оставила **4 pinned rasters** после снятия всех native hosts
(`seven-slices-visibility-before-v3`). Первые варианты этих новых фикстур
не используются как отрицательное доказательство: один не имел статических
тайлов, другой запросил несуществующий четвёртый лист короткого документа.
`seven-slices-visibility-focused`: **2/2 native PASS**. Возвращение той же
миниатюры проверено без повторного `update` и без новой SwiftUI-идентичности.
Неизменный source **817c3d7354958c5ad53dcd8c8f707f789d8e7204b514c989ee346e74f689c868**:
`seven-slices-visibility-final` — **160 iPad native + 9 Mac PASS**, 0 skips и
runtime warnings. Включены чернила/передача, документные программы и настоящий
UIKit curl, отмена подготовки, очереди/освобождение ресурсов, постоянная камера
после давления и старые пиксели при отмене. Копия от `6eeeb92c…` содержит только
изменения этой задачи; незавершённые параллельные Core/graphics GUI-205 не входят
в её квитанцию. Release-пара `seven-slices-visibility-pair` установлена in-place:
iPad UUID **4CB9A179-FD18-322B-8EF0-7B7F829EEC63**, Mac
**A3F8AAF6-0C04-3732-BE05-D01A0008740A**. Данные Mac до перезапуска и активация
iPad неизменны. Public read-only run `a5d51306-164d-451f-9b4c-39e661b1b663`
completed/error null/effects []; connected, те же 13 Pencil actions (revision и
длина данных) и блок документа, общий cursor исключён из сравнения версий.
`warm-ten-visibility-1738` завершил пять полных тёплых циклов доска →
документ → сохранённая вторая страница → глава 12 → первая страница → доска,
без перезапуска приложения. На пятом возврате XCTest начал по 60 секунд ждать
`App animations complete notification not received` перед доставкой следующего
события. Пятый возврат всё же показал прежние A = 1 и `physical 20260916`;
PNG доски и первой страницы просмотрены. На шестом цикле прогон остановлен:
xcresult имеет **Testing was canceled, не PASS и не 10/10**. После отмены
Xcode не завершил video attachment (`Finished test run with pending attachment`),
поэтому по этому запуску нет ни визуальных latency-замеров, ни FPS.

Задержка повторилась **без профайлера**: прежняя гипотеза о влиянии Instruments
не подтверждена. Нет оснований ни выдавать ожидание XCTest за зависание
приложения, ни исключать дефект его анимационного lifecycle без диагностики.
В консоли этого запуска нет `SCENE_COMPOSITION_FAILED` или timeout подготовки;
сообщения `raster_preflight attempt=0` относятся к отвергнутому первому кандидату,
после которого сцена установилась, а не к окончательному отказу перехода.

После отдельного холодного запуска `pencil-visibility-1751` — **1/1 physical
PASS, 20,323 с**: открыта настоящая страница с 13 ранее записанными человеком
действиями Pencil, её drawing count совпал после ещё одного перезапуска.
Это не новая проверка контакта пером. Срез 7 остаётся открытым: десять тёплых
повторов, 30 минут смешанной работы, reconnect/voice и системные показатели
CPU/GPU/памяти/кадров этой версии не завершены.

## 16 сентября, 16:22 UTC — размер и принадлежность нативного выделения

Смешанный preflight установленной `ac3cb40` воспроизвёл пустой переход
доска ↔ обложка документа. В живой консоли — `resource_limit`,
**222 308 352 reserved + 25 713 664 pinned bytes** при общем пределе
268 435 456. Последовательное уменьшение растров и необязательных владельцев
не освобождало нативные backing. Артефакты: `seven-slices-physical/`
`mixed-composition-console-1556.log`, `board-from-cover-console-1556.xcresult`,
`document-board-diagnostic-1554.xcresult`. Это реальные отказы, не PASS.

`SpatialInkSurfaceRegistry` больше не строит квадрат по большей стороне
экрана перед расчётом полного портала. В portrait 834×1194@2 доска получает
834×1194 pt вместо 1194×1709,396… pt: **20 вместо 35** фиксированных
512-px тайлов на непустой canvas. Плотность, два drawable и предел памяти
прежние; полный портал текущей ориентации остаётся готовым к передаче ввода.
Настоящий поворот проходит существующий приватный resize, без второго пути.

Source **b83f77edfef9da4b66f47e062ad6518f5f49e6d73d90cc8e7a7e957c4341dee0**:
`seven-slices-native-extent-final-v2` — **38 native PASS, 0 skips**.
Проверены чернила родителя/потомка/обложки вместе с видимым статическим
материалом на полном Retina-размере, первая точка после передачи, портретная
и альбомная проекции, отмена приватного resize и сохранение старых пикселей.
Два первых локальных запуска отклонены: новая фикстура ошибочно передала
board-worldPoint для локального штриха обложки и вызвала precondition.
Исправлены координаты фикстуры, не production-проверка. Эти запуски не являются
отрицательным контролем исправления и не выданы за PASS.

Отдельный запуск физического UI-test runner ранее был отклонён общим сообщением
о недоверенной подписи. Реальные подпись, entitlements, профиль и UDID были
допустимы; переустановка только тестовой оболочки восстановила запуск. Настройки
доверия, основное приложение и данные для этого не менялись. Причина кеширования
системы не доказана; отсутствие пункта в VPN не было ошибкой пользователя.

Первая установленная правка площади **не исправила весь переход**:
`warm-native-extent-1609` прошёл к доске, но отказал при открытии документа.
В момент отказа reserved 122 585 088 / pinned 53 749 632 / passiveReserved
80 314 368 bytes; ещё один native tile 2 113 536 bytes не помещался именно
в пассивные 128 MiB. Трасса `warm-native-extent-1609.trace` сохранена, но
сценарий завершился через 25,571 с отказом: 180-секундная запись с последующим
покоем не является успешной смешанной ресурсной проверкой.

Адресная диагностика `native-role-console-1617.log` локализовала входящую
обложку документа. Прежний смонтированный view при каждом обновлении менял
роли **всех** зарегистрированных canvases и успевал понизить ещё готовящуюся
input-обложку до passive. Обратный переход дополнительно пытался понизить
уходящую обложку до освобождения её старых пикселей. Теперь роли принадлежат
точному установленному набору; кандидат и уходящий состав не переклассифицируются
посторонним update. Новый корень получает input своей сцены. Общие лимиты
256/128 MiB и учёт временно удерживаемых байтов не ослаблены; диагностика удалена.

Два новых native-сценария `seven-slices-native-role-before` **2/2 FAIL** с
настоящим `native_ink resource_limit`: старый mount продолжает обновляться,
пока готовится новая доска либо focused-обложка. После изменения
`seven-slices-native-role-final` — **40/40 PASS, 0 skips**, source
**9a562720c0c41149bc44f1478f91964aada8a4281db81ff25f54e2c33cc159c4**.
Старые пиксели всё это время удерживаются; первый ввод и отмена подготовки
проверены теми же тестами, а не исключены ради допуска.

На установленном `9a562720…` первый полный тёплый круг прошёл, второй снова
отказал: `warm-native-admission-1624`, 87,225 с. Теперь отказ происходил
в `raster_preflight`: 87 760 000 pinned + 42 437 505 passive bytes не оставляли
места для требуемых 6 365 440 bytes следующего состава. Чернила невидимой
родительской области всё ещё занимали полноэкранный backing — существование
штрихов **где угодно** на доске ошибочно означало непустой видимый кадр.

`InkCanvasView` теперь проверяет установленные chunk-проекции до выделения
backing прозрачного кадра. Mesh не удаляется, а появление его области снова
готовит обычный Retina target. `seven-slices-empty-ink-before` действительно
отклонил прежние **42 270 720 bytes вместо 0**. Новый сценарий также перемещает
камеру к сохранённой линии, проверяет настоящие пиксели и сохранённую геометрию
ластика. Общий предел, первая точка и активный Pencil не обходятся.

Source **e52ebe4ce5850e36e31ff798a70ef10ca929fc8bd71bea409634703ae9e05033**:
`seven-slices-native-visibility-final-v2` — **45/45 native PASS, 0 skips**,
включая реальный большой Retina drawable первого контакта и рост viewport.
Первый объединённый проход дал 43/45: прежняя проверка размера ещё требовала
удалённый квадрат, а новая проверка сразу после install путала GPU-ready
с завершённой транзакцией. Ожидание настоящих пикселей и новой геометрии
исправлено в тестах; ввод за старой границей и все проверки сохранения остались.

Release-пара `seven-slices-native-visibility-pair` установлена in-place,
iPad UUID **E20D3D3D-FFF1-3CFF-A36E-AC05C1A6C09A**, Mac UUID
**C21BF9A6-7FE3-3380-ADDA-6CEB1707E459**. Public read-only run
`fecbadd7-c247-4048-9c8b-760a100004db` completed/error null/effects [];
connected, 13 действий Pencil и сохранённый блок прежние.

`warm-native-visibility-1634` **FAIL, 86,671 с**: первый тёплый круг прошёл,
повторное раскрытие документа показало первую страницу, но переход на вторую
не завершился. PNG первой страницы и кадр «Открываем страницу 2…» просмотрены.
Это не ресурсная приёмка; 240-секундная системная запись включает последующий
покой. Диагностический source `29365e2c…`, `warm-document-diagnostic-1645`
повторил отказ за 85,638 с: `document_preparation_timeout`, page 1.
Временная печать классификации ошибки удалена после локализации.

Найдена независимая ошибка физического WebKit handoff: старый coordinator
после замены страницы сохранял указатель на её host. При перемонтировании
либо освобождении он безусловно удалял поверхность **нового** владельца.
Два теста `seven-slices-document-host-before-v2` дали **2/2 FAIL** именно
по потере incoming WKWebView и его native window. Первый запуск без `v2`
не является отрицательным контролем: новый тест не компилировался из-за
`await` внутри XCTest autoclosure; исправлено только выражение теста.

Теперь освобождение coordinator адресовано собственному WKWebView; передача
целого физического поддерева остаётся прежней. Пределы, дедлайны, source
measurement и контракты готовности не ослаблены. Итоговый source
**6eeeb92cecd77553c45a40b4ef71cc54b4da66199fbb192e72a479c5b00b1e82**,
`seven-slices-native-ownership-final-v2`: **72 iPad native + 9 Mac PASS**,
0 skips/runtime warnings. Включены обе регрессии удаления чужой поверхности,
настоящие повторные UIKit page-curl landing, возврат ресурса и сохранение editor.
Первый дополнительный Mac-проход обнаружил отсутствовавшую безадресную очистку
приватного shell host: она сохранена для владельца контейнера, но больше не
удаляет WK, уже переданный другому host. Непрошедшая сборка не выдана за PASS.
Release-пара `seven-slices-native-ownership-pair`: iPad UUID
**91EAB375-B985-349E-BBDE-5E65F440AF5F**, Mac **1DCC0206-A14A-3414-944F-812C144B143E**.
Установлена in-place, Mac данные до запуска и активация iPad неизменны.
Public read-only run `9997b306-638d-4d85-bf8b-b18b068fde7f`
completed/error null/effects []; connected, версия/данные страницы и блока прежние.
Общий cursor 8969→9196 не является изменением блока.

Первый физический `warm-ten-native-ownership-1658` остановился ещё в поиске:
синтезированный tap попал в центр видимого результата (417; 312,25), но sheet
не закрылся. `failure=none`, запроса перехода в наблюдаемом состоянии нет;
причина этого единичного недоставленного действия не установлена. Отдельный
`accept-native-ownership-1701` тем же видимым результатом открыл доску с одного
контакта, 7,039 с. Первый запуск не объявлен успешным или исправленным этим повтором.
Комбинированная системная запись Animation Hitches + Activity Monitor + Time
Profiler + GPU завершилась `Transferred trace file is malformed` после остановки;
её метрики не используются. `warm-ten-native-ownership-1702` был прерван: XCTest повторно ждал native animation notification по 60 с. Его Activity Monitor + GPU trace записан успешно, но в основном содержит ожидание инструмента, не принятую нагрузку. `warm-ten-native-ownership-1707` после свежего запуска, уже без профилировщика, прошёл один тёплый цикл и отказал на следующей странице второго: **88,045 с, FAIL**. Исправление адресной очистки само по себе этот сценарий не завершило.
Срез 7 остаётся открытым, второй Mac по-прежнему исключён из области.

## 16 сентября, 15:34 UTC — один SQL-срез проверок и первые полезные кадры

Физическая трасса `history-team-m94-1458` показала **4,672 с inclusive CPU**
в `refreshReferenceStatuses`: адресные proof-чтения всё ещё открывали соединение
и подготавливали схему для каждого запроса. Теперь один проход существующего
владельца использует одну WAL-транзакцию. Нет нового кеша, постоянного соединения
или дополнительного владельца. Ошибка отдельного указания не мешает соседнему;
более поздний ввод и активный контакт по-прежнему запрещают публикацию.

Source **8ec51a325792407d8325e2e72a5db53286aa972e29ccd90ea17137c7a91d6b29**:
`seven-slices-proof-batch-final` — **9 native PASS / 0 skips/runtime warnings**.
Регрессия проверяет независимые current/checking/review-required/target-missing,
приход новой квитанции без пересборки содержания и границу контакта. Первый
маршрут `seven-slices-proof-batch-native` отклонён из-за ошибочно названного
несуществующего `NotebookAppModelTests`, хотя девять действительных тестов
прошли. Он не выдан за общую квитанцию PASS; окончательный маршрут выше точен.

Проверенная Release-пара `seven-slices-proof-batch-pair/build.json` установлена
обычным обновлением той же команды M94V58FCVP: UUID iPad
**E0D75393-CCF9-30EA-8A92-28E3C7047F31**, Mac **21EB5F33-47D7-3140-8A46-3C31D32C0ED8**.
Без переустановки, сброса ключей или контейнеров. Mac штатно завершил очередь,
его данные до запуска и активация iPad неизменны. Public read-only run
`ae6d2011-e413-4db3-90fc-65f536723556` completed/error null/effects []; connected,
значения страницы и документа прежние. Общий SQL cursor изменился 8377→8381;
он не является версией выбранного блока. `seven-slices-proof-batch-install`.

Физический `pencil-proof-batch-1518` **PASS, 20,879 с**: те же **13 действий пера**
после холодного запуска, PNG просмотрен. `history-proof-batch-1519` **PASS,
75,633 с**, читаемая первая страница после истории; input-ready **931,288 мс**
(demand **665,605**, content-ready **929,454**). Это отдельный проход, не p95.
Его 90-секундная Time Profiler + Activity Monitor трасса, PID 2983:

- `refreshReferenceStatuses` **0,752 с inclusive**, против **4,672 с** предыдущего
  прохода того же теста; дорогой повтор чтений устранён. Это не коэффициент
  ускорения всего приложения.
- Sampled CPU **27,231 с**, main **11,954 с**, CPU delta **27,597 с**; прежние
  значения 28,255 / 11,062 / 28,686 с. Остальные расходы не исчезли.
- Footprint **422 609 952 → peak 551 585 256 → 299 877 984 bytes**.
  Перед новым проходом был холодный запуск Pencil; старый начинался после
  переустановки, поэтому память не объявляется ни улучшенной, ни принятой.
  Potential hangs >250 мс: **0**, это не измерение кадров или всех hitches.

Отдельно успешный `document-video-team-m94-1512` сохранил физическое видео
через штатный `SystemAttachmentLifetime=keepAlways`, без намеренного провала
теста. На прежнем установленном `808a9d…` просмотрены исходные кадры: раскрытая
страница в PTS **14,133333**, последняя подготовка **14,250000**, читаемый текст
с формулой **14,283333**. Между первым кадром раскрытой страницы и текстом
**150 мс**, текст уже виден во время щипка. Native request→content-ready
**156,124 мс**, request→input-ready **1355,886 мс**. Значит, input-ready нельзя
выдавать за первый полезный кадр или сокращать ослаблением защиты контакта.
Это один проход с переменным шагом видеокадров, **не p95 и не аппаратное
касание→фотон**. Метод сохранения успешных видео описан в
[Apple WWDC25](https://developer.apple.com/videos/play/wwdc2025/344/).

На новом установленном **8ec51a32…** `document-ten-proof-batch-1523` завершил
**10/10 физических повторов PASS**, 412,396 с, без skips/runtime warnings:
холодный запуск → поиск → раскрытие → сохранённая правка на следующем листе →
дальняя ссылка → возврат. Сохранены все десять видео, первые читаемые кадры
просмотрены. Временная шкала XCTest начала щипка → первый записанный кадр текста:
**280,667–316,333 мс, p95 316,333 мс**. Для этого документа ориентир первой
полезной страницы ≤1 с выполнен. Соседние кадры разделены 33,333–35 мс;
это не аппаратный touch-to-photon и не измерение FPS. Полоса текста фиксирована
для этой главы, а не универсальный визуальный oracle. Исходные PTS сохранены
через `ffmpeg -copyts`, кадры не интерполированы.

Отдельные p95 request→native installed: первая страница **1362,616 мс**,
холодная следующая **506,046 мс**, дальняя ссылка **169,761 мс**, возврат
**127,554 мс**. Не смешиваем эти границы с первым полезным изображением.
Артефакты: `document-ten-proof-batch-1523-{media,visual-analysis}/`,
`measurements.json` и просмотренный `document-ten-proof-batch-1523-first-frames.png`.
Каждый повтор завершал процесс iPad: это проверка холодного восстановления,
**не** доказательство отсутствия накопления памяти в долгой сессии.

Срез 7 открыт: стабильность ресурсов/кадров, 30 минут смешанного
рабочего места, голос и восстановление связи **текущей пары**. Второй Mac не
входит в уточнённую Амиром область. Документ/Pencil PASS не закрывает эти условия.

## 16 сентября, 15:03 UTC — новая команда подписи, установленная пара и физический повтор

Амир подтвердил команду **M94V58FCVP / FINLEY KIWM Q**, переустановку и новое
сопряжение, затем отказался от отдельного архивирования ненужных тестовых данных.
Все четыре Xcode target и сборщик переведены на эту команду; изолированная
приёмка читает того же владельца `release.TEAM`, прежняя копия константы удалена.
Защиты подписи, собственных Keychain-групп, bundle ID и вложенных XPC не ослаблены.

Source **808a9d8837098c0d3fc3582d34352790c0b86ef7efac63f4b90c9ab66a72ee5b**:
`seven-slices-team-m94-verification` — **79 verification + 64 release PASS**;
отдельно **39 first-installer PASS** (`seven-slices-team-m94-preview-installer.log`).
Это выборка маршрута сборки, не повтор всех runtime-тестов. Неизменный runtime
предыдущего среза имеет 57 native/UI PASS. Настоящая Release-пара проверена в
`seven-slices-team-m94-verified-pair/build.json`: UUID iPad
**988B4C9D-A598-3259-BBF9-FBCE0E586BAF**, Mac **68D6DEC7-A8AE-3566-8413-AA3E42F67671**.
Профиль iPad действует до **16 сентября 2027, 14:45:27 UTC**.

Вместо недопустимого обновления поверх другого App ID prefix выполнена явно
разрешённая переустановка iPad. Между контейнерами перенесён только его текущий
набор (~54 MB), без исторических архивов/конвертера содержания и без отдельного
backup. Mac остановлен штатно; его store до повторного запуска побайтово
неизменен. Сброшена ровно прежняя запись сопряжения Notebook в Mac Keychain,
не сертификаты, ACL или другие ключи. Новый одноразовый grant проверен штатным
владельцем и потреблён обоими приложениями. Идентичности/активации сохранены.
`seven-slices-team-m94-install/installation.json`: installed-and-connected.
Read-only run `92d5ffbd-0192-4044-8067-4fb5c8773337` завершён без effects/error;
последующий observe подтвердил connected. Значения листа и блока документа
равны прочитанным перед установкой. Временные копии переноса и grant удалены
после проверки; Mac-содержание не заменялось.

Физические проверки установленного `808a9d…`:

- `history-team-m94-1458.xcresult` **PASS, 72,473 с**: тетрадь → обложка →
  история → документ. PNG просмотрен. Request→input-ready **908,248 мс**.
- `document-pencil-team-m94-1500.xcresult` **2 PASS**: цикл документа **41,049 с**,
  Pencil с холодным перезапуском **20,544 с**. Видны прежние **13 действий пера**,
  PNG просмотрен. Один проход документа: первая страница **1359,186 мс**,
  следующая **490,389 мс**, дальняя ссылка **92,941 мс**, возврат **108,054 мс**.
  Это не p95 и не touch-to-photon: installed ждёт окончания владельца жеста.
- `history-team-m94-1458.trace`, 90 с Time Profiler + Activity Monitor, PID 2890:
  sampled CPU **28,255 с**, main **11,062 с**; footprint старт **320 275 440**,
  пик **457 328 080**, конец **286 017 048 bytes**. Нет potential hangs >250 мс.
  `targetRenderRequests` исчез из пути (0 sampled ms), но вся проверка указаний
  всё ещё занимает **4,672 с inclusive**. Старт — уже открытый после переустановки
  лист, поэтому это не равный прежнему холодному запуску контроль памяти.

Срез 7 остаётся открытым: первые полезные пиксели отдельно от окончания жеста,
ресурсная стабилизация/кадры, итоговые десять повторов и 30 минут смешанной работы,
голос и восстановление рабочего места текущей пары. Второй Mac исключён Амиром
из области приёмки 16 сентября (GUI-199); его повторное упоминание здесь было
ошибочным возвратом старого требования. Видимая ошибка владельца
текущего Codex-разговора не скрыта; терминал после перезапуска helper требует
новой оболочки, прежний PTY не объявляется сохранённым.

## 16 сентября, 14:45 UTC — холодное открытие не заполняет все слоты телами

В физической тестовой тетради четыре листа. Публичный SDK read-only run
`d8e5926c-3403-4cdd-86d3-7ac766400564` завершён без effects/error: первый лист
содержит 572 788 символов drawing, второй пуст, третий и четвёртый — 1 771 484
и 1 250 068. Прежний холодный путь читал все четыре тела, а нативное окно
создавало дальние листы только ради заполнения свободных слотов.

Теперь чтение выбранного листа отделено от каталога; соседние тела запрашивает
нативный владелец. Окно удерживает уже подготовленных соседей для обратного
перелистывания, но не создаёт дальние листы без направления/назначения.
Отрицательный native-контроль `seven-slices-cold-paper-before-v2` построил
0/1/2/3 вместо 0/1. В тесте чтения полный запрос четырёх тел превышает тот же
бюджет 256 KiB, в котором выбранный лист читается; последующий адресный запрос
дальнего листа возвращает его UUID и все 600 000 символов источника.
Первоначальные ошибки подготовки presence в этой фикстуре не выдаются за
отрицательный контроль поведения.

На source **acafb9cdb127014e91861232f3c416335f1edcd89e826fdf9868bc510ba3b31d**
`seven-slices-cold-paper-final/verification.json`: **57 PASS / 0 skips/runtime
warnings**. Из них 55 native и два настоящих Simulator-жеста: тетрадь вперёд/
назад без изменения чернил и документ 1→2→3→2→1 с чтением показанного текста.
Первый запуск старой UI-фикстуры ошибочно трактовал swipe как эмулированный
Pencil (81 действие вместо исходных 80), а не как палец. Исправлен только
параметр этого теста и добавлена проверка неизменности чернил; production-ввод
не ослаблен. Журнал ошибочного запуска: `seven-slices-cold-paper-gestures`.

Физическое влияние на память/задержку **ещё не измерено**. Попытка пары
`seven-slices-cold-paper-pair` вновь получила No Account for Team VUNH73AYPY.
Амир указал новую команду **M94V58FCVP**; отдельная проверка возможности подписи
не заменяет установленное приложение. Смена App ID prefix затрагивает Keychain
и допустимость обновления поверх старой команды; данные, ключи и контейнеры
пока не изменялись. Срез 7 остаётся открытым.

## 16 сентября, 14:21 UTC — адресная проверка регионального снимка

По предыдущей системной трассе `ReferenceVision.referenceStatus` тратил
5,452 с inclusive на чтение каталога render requests. Два composite ID уже
известны: теперь существующий владелец читает именно их сохранённые запросы и
квитанции. Удалён обход первой страницы из 80 записей. Проверки target, region,
origin, page, source/recipe, отсутствия pageVision и точного совпадения квитанции
с запросом сохранены. Нет нового кеша, очереди или создания снимка при чтении.

Новая регрессия с 90 предшествующими запросами воспроизвела отказ старого пути
в бюджете 32 строки / 64 KiB (`seven-slices-addressed-proof-before/core.log`).
После исправления точный снимок находится и за пределами первой страницы;
после удаления авторитетного запроса оставшийся файл receipt не подтверждает
актуальность и не вызывает повторное создание запроса. **14 Core-тестов PASS**,
включая параметризованные rendering recipes и прежний контракт read-only.
Source `0df75fd97815aca259efe675fb7bfc1ee7a37448e607fa743756d0b02fbc06b2`,
команда, журнал и неизменные source-before/after в
`.build/seven-slices-addressed-proof-core/`. На том же source **17 iPad native
PASS / 0 skips/runtime warnings**: `seven-slices-addressed-proof-native`,
публикация сцены, очередь принятого ввода и навигация по указанию.
Физическое ускорение этого изменения
ещё не измерено; установленный iPad остаётся на предыдущем `bbd56321…`.

Штатная сборка после истечения профиля остановилась: **No Account for Team
VUNH73AYPY / No profiles for com.amirtlinov.notebook.preview**.
`.build/seven-slices-renewed-profile-pair/build.stdout.log`, строки 62–63.
Это текущая граница установки, не прежняя блокировка UI Automation. Амиру
отправлен запрос проверить Xcode → Settings → Accounts; профили, ключи,
контейнеры и приложение не удалялись. Независимая работа с кодом продолжается.

## 16 сентября, 14:15 UTC — чтение чернил только показанных досок

`NotebookSceneState` больше не принимает метаданные родителя/корня за перечень
видимых поверхностей. Чернила читаются по реально запрошенным окнам сцены;
метаданные навигации сохраняются. Отрицательный контроль
`seven-slices-parent-ink-read-before` дал четыре ожидаемых отказа: невидимый
родитель присутствовал и в inkSurfaces, и в загруженных действиях. После правки
**38 native PASS / 0 skips/runtime warnings**, включая сохранность точных чернил
при возвращении к родителю, портал, адресный переход и публикацию живой сцены.

Неизменный source **bbd56321d5e7df3e500c5e9bfca97b665abd59933e30b5482551f22188786274**:
`seven-slices-visible-ink-native/verification.json`, verified-пара
`seven-slices-visible-ink-pair/build.json`, in-place установка
`seven-slices-visible-ink-install/installation.json`. UUID iPad
`59704639-3E42-335B-9DB0-930D5E63D89F`, Mac `256208EE-3825-34C1-95A7-88A282BEEF37`.
Контейнеры/допуски сохранены, публичный MCP connected, значения блока документа
не изменились. Каталог тетради через публичный SDK содержит четыре листа:
показанные 1/4 соответствуют сохранённому каталогу, не частичной проекции UI.

Физический `history-visible-ink-1404.xcresult` PASS: тот же поиск тетради →
обложка → история → первая страница. PNG просмотрен, live/paint=true, failure=none.
Request→installed **873,763 мс** вместо одиночного прежнего **3532,238 мс**;
demand→content-ready **184,135 мс**. Это сравнение двух проходов, не p95.
90-секундный `history-visible-ink-1404.trace`, PID 2633: sampled CPU **28,379 с**,
main **9,616 с**, CPU delta **28,625 с**; inclusive readSpatialInk **1,657 с**,
readWorkingSet **1,814 с**. Пик памяти не исправлен: старт **644 088 960**,
peak **811 926 800**, конец **324 912 808 bytes**. Стартовые состояния отличались;
общий коэффициент ускорения/улучшения памяти не заявляется. Теперь виден другой
дорогой участок: проверка региональных указаний сканирует страницы render requests
(**5,452 с inclusive**) вместо чтения двух известных адресов квитанций.

`document-ten-visible-ink-1406.xcresult`: **10/10 физических повторов PASS**
(XCTest summary считает один метод; журнал содержит все десять итераций).
Каждый: cold launch → поиск → раскрытие → сохранённая строка → дальняя глава →
обзорный возврат. p95 request→native installed/input-ready: первая страница
**1367,158 мс**, следующая холодная **492,288 мс**, дальняя ссылка **148,432 мс**,
возврат **116,987 мс**. Первые два полных интерактивных перехода превышают ориентиры. У первой медиана
demand→ready **159,554 мс**, ready→installed **1179,854 мс**: задержка находится
после подготовки, её нельзя скрыть числом content-ready. Но счётчик installed
в `DocumentPagePresentationOwner` дополнительно ждёт isInteractive и снятия
gestureLocked: эта разница сама по себе **не доказывает поздний показ пикселей**.
Время первой полезной картинки при щипке требует отдельной визуальной проверки;
ради улучшения числа нельзя отдавать контролам контакт, которым ещё владеет
камера. Это не touch-to-photon; профилирование частей проходов включено в измерение.

Завершены настоящие системные записи, а не CADisplayLink: `document-frames-visible-ink-1406.trace`
(50 с, Core Animation FPS + GPU utilization, thermal Nominal),
`document-gpu-visible-ink-1408.trace` (45 с, Metal GPU) и
`document-hitches-visible-ink-1410.trace` (30 с, Animation Hitches).
У Notebook PID 2772 **29 hitches, 266,770 мс суммарно, максимум 16,673 мс**;
AutomationModeUI/InputUI/SpringBoard считаются отдельно. Есть подсказки дорогих
обновлений и 25–33 offscreen passes; это ещё не локализованная причина.
GPU active union у двух процессов Notebook **96,607 / 25,988 мс**;
их Metal-интервалы не включают отдельные WebKit/композитор и не означают FPS.
Системная FPS-оценка включает покой и не усредняется в оценку плавности приложения.
Артефакты и раздельные summaries сохранены в `.build/seven-slices-physical/`.

После десяти циклов `pencil-visible-ink-1413.xcresult` **PASS, 20,808 с**:
те же **13 действий пера** после cold launch, PNG просмотрен. Общая приёмка
среза 7 остаётся открытой: холодные задержки, пиковая память и hitches,
30 минут смешанной работы, голос/reconnect и второй Mac. Подпись выгруженного
документа в истории пока общая. Профиль данной пары истекает в 14:15:33 UTC;
следующий штатный provisioning-проход проверяет продление, не обходит подпись.

## 16 сентября, 13:48 UTC — материал не ждёт невидимую родительскую доску

Физический дефект локализован, а не выведен из зелёных тестов. На source
`d7cd9cbd728d3c5df14986067cc49f0130ef50c6536f35cde5c1072cba9c6bf9`
у нативного владельца body/state/indexed=true, input=false, permits=true,
но live=false и resource_limit. Console `history-scene-console-1337.log`:
запрос native_ink **2 113 536 bytes**, занято **207 488 640 / 268 435 456**,
пассивный бюджет **133 152 768 / 134 217 728**. Камера и документ правильные;
обязательная подготовка невидимого родителя блокировала новый состав сцены.
Опциональное `workspace-scene-state` доступно только при уже существующем
флаге профилирования документа; оно читает состояние, не запускает подготовку.

`SceneCompositionSource` теперь расширяет состав родителем только в режиме
доски. Обложка, лист и документ его не показывают; граница возврата запрашивается
обычным переходом обратно к доске. Бюджеты и геометрия не ослаблены.
Отрицательный контроль `seven-slices-parent-pressure-before` воспроизводит
именно отказ native_ink на 2 113 536 bytes. После исправления **61 native PASS /
0 skips/runtime warnings**, включая ту же пассивную нагрузку, переходы через
историю на той же/другой доске и неизменный контракт живой границы возврата.

Source `e5795b7937be7c8be2a898041622c6f6846f42435b1ecc6c420182513b9ad3fb`,
verified-пара `seven-slices-parent-pressure-pair/build.json`, in-place установка
`seven-slices-parent-pressure-install/installation.json`. UUID iPad
`4F22ECA7-BBEC-3452-94BA-F10C35DC6AD9`, Mac `7A9F00DB-320A-3E6B-BBD7-39BF95592515`.
Контейнеры/допуски сохранены; публичный MCP connected, все значения прочитанного
блока документа совпали, изменился только readCursor.

Физический `history-parent-fix-1346.xcresult` **PASS, 57,228 с**:
поиск тетради → обложка → история → настоящая первая страница документа.
PNG просмотрен: текст, формулы, ссылка и 1/17 установлены; live/paint=true,
failure=none. Request→installed **3532,238 мс**, из них demand→content-ready
**157,632 мс**. Пустое место устранено, но задержка до demand всё ещё велика;
оптимальная скорость этим проходом не заявлена.

90-секундный Time Profiler `history-parent-fix-1346.trace`, PID 2581:
CPU delta **33,852 с**, sampled **33,786 с**, main **9,014 с**; footprint
**279 856 280 → 318 752 136**, peak **389 858 768 bytes**. История больше не
доминирует, но readWorkingSet/readSpatialInk занимают **8,2 с inclusive**.
Сценарий с раскрытым чатом/файлами/терминалом отличается от прежнего цикла
документа; общий коэффициент ускорения и ресурсный PASS не заявлены.

Физический `document-pencil-parent-fix-1350.xcresult`: **2 PASS**. Холодный
документ → сохранённая строка на странице 2 → дальняя глава → обратно,
**41,023 с**. Поиск тетради → первый лист → холодный запуск без профильного
флага, **20,304 с**: восстановлены **13 действий пера**. PNG рукописи после
перезапуска просмотрен. Эти отдельные проходы не заменяют десять повторов,
30 минут смешанной работы или системные измерения GPU/кадров; срез 7 открыт.

## 16 сентября, 13:14 UTC — история читает сохранённых владельцев, а не сцену

`CollaborationReadSnapshot` переведена на один адресный SQL-срез после очереди
принятого ввода. Удалён прежний живой путь через `CollaborationContent`, который
сериализовал сцену/чернила и принимал не загруженный документ за отсутствующий.
Версии берутся из существующего полного индекса, продолжения — из фактических
адресов полей и их причинных владельцев. Публичные подробности хода используют
тот же читатель. Командообразная проекция и её селекторы удалены; новая очередь,
глобальный кеш или второй протокол хранения не добавлены. Полное сравнение
созданного владельца сохранено: человеческая доработка не теряется.

Source `e93d04b76263bc0501a91c88b96aef173f779abdf2b141c425328a39dad4f203`:
**684 Core PASS / 52,285 с**, без неизменённых scale-fixtures, и **20 iPad native
PASS / 0 skips/runtime warnings**. Проверены закрытый большой документ вне сцены,
новый порядок/добавление/удаление элементов, человеческое продолжение, отмена,
отказ устаревшей версии квитанции и ожидание незавершённой записи программы.
История поля проходит бюджет 256 KiB при 12 000 посторонних измерениях чернил
на той же доске; отрицательный контроль полного чтения этих чернил бюджет
превышает. Доказательства: `.build/seven-slices-addressed-history/` и
`.build/seven-slices-addressed-history-native/verification.json`.

Изолированный локальный fixture 12 досок / 26 указаний / 24 результатов:
10 подготовок **6,514–7,055 мс**, медиана **6,679 мс**, вместо прежнего полного
дерева с медианой 97,930 мс. Новый путь дополнительно сверяет SQL-квитанции;
это сравнение конкретной подготовки, не коэффициент ускорения приложения.

Verified-пара установлена in-place, без изменения контейнеров/допусков:
`.build/seven-slices-addressed-history-pair/build.json`, одноимённый
`-install/installation.json`. Mac UUID `A521DFF0-3760-3EA8-92DE-A6B56B83A1C2`,
iPad `820AB7BE-4AF4-3540-B3A3-D1FC089D5F2B`. Публичный MCP connected;
блок сохранённого документа и metadata совпадают с предыдущей установкой.
Чтение реального хода `6e77f1a8…` завершено: четыре программы, рукопись и правка
документа классифицированы как человеческие продолжения, а не удаления.

Свежий публичный readback Pencil: **13 активных действий**, 429 591 bytes,
SHA-256 `0fd2cf7f50029d0fd63187df6b37c2fc17a831fbd99bc9c82861ac8d386a0a82`.
Все прежние девять действий точно совпадают по декодированным значениям; добавлены
четыре новых. Частичный вывод дочитан `resume` того же run, без повторного старта.
Новые страницы/рукопись не откатывались к старой фикстуре.

Промежуточные физические попытки сохранены отдельно. В `document-addressed-history-1258`
поиск закрылся между tap поля и вводом; документ не был открыт, причина закрытия
не установлена. Эта трасса не сравнивается с полным циклом документа. В истории
`history-addressed-1304` проверка ошибочно ожидала действие в начале списка,
`history-addressed-1310` — полное имя выгруженного документа. Видео второго
прохода показывает готовые результаты и человеческие продолжения; ссылка
на выгруженный документ подписана общим «Документ». Это оставшаяся проблема
подписи, не отсутствие результата; зелёными эти две проверки не названы.

Физический `history-addressed-1314.xcresult`: нужный результат найден и нажат,
но открыто пустое поле, **FAIL**. Независимое видео/AX и осмотр спустя пять минут
подтверждают отсутствие бумаги/WebKit, а не только ошибочное ожидание тестом
кнопки обложки в раскрытом документе. Публичный readback: правильный документ,
mode=document, openProgress=1 и камера в его фактическом центре (2300, 600).
Простые native-переходы к незагруженному документу на той же и другой доске
проходят; физический разрыв ими не закрыт. Подпись истории и владелец
физической установки остаются открытыми условиями, срез 7 не завершён.

`history-blank-1320.trace` — 25 с уже пустого состояния, PID 2490:
CPU delta **4,725 с**, sampled **4,679 с**, main **0,503 с**, footprint
**291 636 712 → 291 161 576 bytes**, peak **291 653 096 bytes**, без microhang
>250 мс. Это idle-наблюдение дефекта, не успешный цикл документа и не ресурсный
PASS. Отдельная трасса неудачного поиска показала до **911 164 712 bytes**;
условия/фон различались, вывод об устранении памяти не делается.


## 16 сентября, 12:27 UTC — числовой путь чернил без исключения на каждом числе

`JSONValue` теперь сначала пробует штатное чтение Double, затем Bool.
JSONDecoder различает эти примитивы; прежний порядок создавал type-mismatch
для каждой координаты, ширины и времени. Парсер, формат, валидация и значения
не заменены. На одинаковом локальном Release-fixture 1 390 141 bytes пять
проходов — примерно **100 → 74 мс**. Это измерение декодера, не всего приложения.
Более быстрая экспериментальная конверсия JSONSerialization/NSNumber отвергнута:
`0.004166666666666667` становилось `0.0041666666666666675`; точное равенство
generic JSON и typed ink нарушалось. Она в продукт не попала.

Source `e19b603304be8012218d6e11f40fa324588091b921d356750a366459c8485c1a`:
**681 Core PASS** за 69,547 с в области без неизменённых scale-fixtures и
**37 iPad native PASS / 0 skips/runtime warnings**. Новый тест проверяет
Boolean/number/string/null, точные значения 4800 измерений и канонический hash.
Первоначальный широкий Core-run остановлен после 692 завершённых проверок,
пока готовил старую 100 000-страничную фикстуру; весь этот маршрут не назван PASS.
Команда выбранного повтора и неизменный fingerprint —
`.build/seven-slices-json-profile/core-scoped-command.json`, `core-source-*.json`.
Native receipt — `.build/seven-slices-numeric-json-native/verification.json`.

Verified-пара установлена in-place (`seven-slices-numeric-json-pair/build.json`,
`seven-slices-numeric-json-install/installation.json`): Mac UUID
`A9459EB8-F073-3D15-A553-E029DD2668DF`, iPad `C3A5A9A3-3970-3A79-8D2A-74459A8EEE0D`.
Содержание и допуски сохранены, публичный MCP connected. Физический документ
`document-numeric-json-1223.xcresult` **PASS, 40,154 с**; новая строка после cold
launch видна, исходный PNG просмотрен. Request→installed **1354,173 / 449,652 /
94,000 / 109,260 мс**, первый content-ready **159,009 мс**; это не p95.
`pencil-numeric-json-1225.xcresult` **PASS, 17,796 с**: поиск, раскрытие обложки
и холодное восстановление **9 реальных действий Амира**. PNG просмотрен;
публичное чтение после повторного открытия сохранило ровно прежние 329 698 bytes,
SHA-256 `0e8c9d63a322d205774613641edec57900dfa89d3006abad72b4d73fc7f78c4f`.

Time Profiler `document-numeric-json-1222.trace`: PID 2428, 74 Activity Monitor
samples, окно **14,436–89,537 с**, CPU delta **42,878 с**, sampled **43,377 с**,
main **6,670 с**. Inclusive JSONValue decode **16,709 с**, история **15,442 с**,
readSpatialInk **12,393 с**; эти стеки пересекаются. CPU p95 **225,198%**,
footprint peak **452 085 248**, конец **373 523 992 bytes**. Один microhang
**267,437 мс** на 19,984 с; его причина пока не локализована. Системные
dylibs-overlap warnings сохранены. Снижение конкретной работы наблюдается,
но окна/фон различаются, точный общий коэффициент не заявлен, память существенно
не исправлена и ресурсного PASS нет. Разбор — `numeric-json-summary.json`.

Отдельная попытка frames/GPU на предыдущем installed source `b351f60d…`:
`document-frames-baseline-1214.xcresult` PASS, но 90-секундный xctrace
Animation Hitches + GPU + Core Animation FPS не закончил остановку более чем
за три минуты. SIGINT также не завершил shutdown; остановлен только этот
процесс xctrace, неполный bundle сохранён. Это отказ измерительного маршрута,
не показатель кадров/GPU приложения. Срез 7 и прежние открытые условия остаются.

## 16 сентября, 12:02 UTC — неизменное чтение не пересоздаёт историю

Воспроизведено: при равном `CollaborationContent` повторный SQL-read менял
ключ подготовки 21→27 и убирал готовые результаты. Отрицательная регрессия:
`.build/seven-slices-history-invalidation-before/ipad.xcresult`. Модель теперь
различает порядок допуска/публикации scene reads и изменение входов истории.
Первый сохранён, включая отказ старому чтению до завершения записи программы;
второй не меняется от равного присваивания. Источники, квитанции, контексты,
новая подсвеченная ссылка и принятое состояние программы остаются причинами
инвалидизации. Выключения истории, новой копии данных или глобального кеша нет.

Source `b351f60dee903e48847486a2347bfdd400bcfa2334f622f3cc29509c8698d32b`:
**20 iPad native PASS / 0 skips/runtime warnings**, включая три равных чтения,
выбор/подсветку, последующую правку человека, два запоздавших переноса,
программный ввод до записи, установку/подтверждение показа и сохранение редактора.
Квитанция: `.build/seven-slices-history-invalidation-native/verification.json`.
Verified-пара и in-place установка: одноимённые `-pair/build.json` и
`-install/installation.json`. UUID Mac `5F5B0BF9-7796-3D78-883E-3C84075373FB`,
iPad `BB41D875-5087-30E0-8FC3-FA114D873037`. Контейнеры и допуски сохранены;
публичный MCP — connected, блок документа и его metadata прежние, SHA-256
текста `bb1117f44b29006373204659bf15456bc6871eba336cf26938e34a0b3ab94680`.
Курсор чтения закономерно изменился, это не изменение блока.

Физический `document-stable-inputs-1155.xcresult` — **PASS, 39,591 с**:
cold launch, поиск, первая страница, сохранённый текст на странице 2,
дальняя ссылка на главу 12 и возврат. Оригинальные PNG хвоста и главы
просмотрены. Native request→observed-install: **1334,983 / 444,666 / 73,105 /
132,393 мс**. Content-ready первого открытия — **359,312 мс**; установленный
интерактивный показ требует также завершённого жеста. Причина оставшейся
разницы не доказана, метрика не переопределена ради целевого числа. Это четыре
наблюдения, не p95 и не измерение касание→фотон.

Трасса `seven-slices-physical/document-stable-inputs-1155.trace`: новый
PID 2369, 64 Activity Monitor samples, окно **24,603–89,645 с**. CPU delta
**52,561 с**, sampled **52,880 с**, main **6,408 с**; inclusive история
**18,994 с** против 26,991 с предыдущего повтора, `readSpatialInk`
**19,044 с**. Разная длительность окна и фон исключают точный общий коэффициент.
CPU p95 **265,152%**, footprint peak **473 581 200**, конец **376 456 776 bytes**:
существенного улучшения памяти нет. Обнаружен **один microhang 258,714 мс**
на 30,984 с; собственные стеки этого интервала содержат только `main`, поэтому
его причина не приписана модели. Предупреждения export о системных dylib overlap
сохранены. Разбор: `stable-inputs-summary.json`, `stable-inputs-hang.json`.
Это проверенный локальный фикс лишней подготовки, **не** PASS общих ресурсов.
Тяжёлое чтение/преобразование чернил, десять повторов, 30 минут смешанного
сценария, кадры/GPU, неизвестный пустой переход и второй Mac ещё открыты.

## 16 сентября, 11:23 UTC — пересчёт истории разных досок и физический документ

На установленном source `e2b61ff1…` 91,046-секундная физическая трасса
`seven-slices-physical/document-cpu-memory-1057.trace` выявила лишнюю фоновую
работу: sampled CPU **62,216 с**, main **3,684 с**; inclusive
`refreshCollaborationDetails` **34,844 с**, `completeReferenceRevision`
**30,564 с**. Эти стеки пересекаются, их времена не складываются.
89 наблюдений Activity Monitor: CPU p95 **269,50%** нескольких ядер,
footprint **215 041 320 → 449 561 920 peak → 362 693 952 bytes**.
Potential hangs >250 мс — 0. Измерение включает открытие документа,
дальнюю ссылку, возврат и idle при уже активной диктовке, не весь cold launch.
Оно не доказывает системный FPS, утечку или полную приёмку.

Причина: мемоизация по целевому UUID предотвращала повтор одного указания,
но каждая другая доска/обложка заново строила полное то же дерево.
`NotebookReferenceReader` теперь готовит его один раз на неизменный набор
источников; прежний отдельный путь пересчёта удалён. SQL-алгебра и проверка
принадлежности обложки сохранены, новая долговечная структура не добавлена.
Отмена проверяется и внутри построения. На source
`8971b73b5835b6f44b9d8fe9c33a565b76d23b33520caacbc73772a213c1b289`:
**74 Core PASS** (указания, связанные обложки, текущие результаты, доработки,
отмена, bound partial scene) и **13 iPad native PASS / 0 skips/runtime warnings**.
Квитанция — `.build/seven-slices-history-tree-native/verification.json`;
Core — `.build/seven-slices-history-tree/core-regressions.log`.

Одинаковая регрессия 12 досок / 96 элементов / 26 валидных владельцев,
10 локальных Debug повторов: до **1377,862–1416,951 мс**, median **1391,670 мс**;
после **95,177–120,426 мс**, median **97,930 мс**. Во втором прогоне параллельно
исполнялись ещё пять выбранных тестов. Сравнение проверяет точное совпадение
с SQL, отдельные ID результатов, неправильного родителя и инвалидизацию
только затронутой ветви следующего среза. Это локальное измерение алгоритма,
не обещание такого же коэффициента для всего приложения. Baseline — `before-v2.log`,
`after-v1.log` — результат после изменения runtime.

Физический документ: открытие первой страницы, ссылка на главу 12
(страница 15) и возврат через обзор показывают правильное содержимое.
`document-overview-return-1102.xcresult` — PASS, просмотрен исходный PNG;
native request→installed **119,804 мс**, не касание→фотон.
Три предыдущих отказа harness сохранены: системная кнопка назад возвращает
предыдущее место, а не якорь; cold launch сохраняет открытую страницу 15;
обзор показывает шесть миниатюр, а не все сразу. Эти ошибки ожиданий не
названы дефектами продукта.

Редактор на физическом iPad дописал «Сохранено на физическом iPad 20260916»
в конец собственного `physical-chapter-0`. Независимое чтение установленного
Mac подтвердило исходный текст плюс только эту вставку, content counter 0→1.
Первое ожидание marker на странице 1 было ошибкой harness: курсор находился
в конце блока на странице 2. Без закрытия документа обычный переход к ней
показал новую строку: `document-saved-tail-1120.xcresult` PASS, PNG просмотрен.
Прежний отказ сохранён в `document-save-1118.xcresult`. Закрывающий щипок
оставляет обзорный масштаб доски, где `cover-opening-surface` не обязана
монтироваться: следующий старый harness ошибочно ждал её после cold launch
без кадрирования. Для законченного повтора используется обычный поиск
документа и раскрытие его обложки, не запись состояния тестом.

Законченный физический повтор на прежней сборке:
`document-controlled-before-1122.xcresult` **PASS, 43,522 с**. После cold launch
обычный поиск и раскрытие обложки, первая страница, сохранённый хвост на
странице 2, дальняя ссылка и обзорный возврат прошли; исходный PNG с новой
строкой после cold launch просмотрен. Дописанный текст сдвинул главу 12 на
страницу 16: прежний номер страницы не зашит в проверку якоря.
Native request→installed для четырёх показов: **453,602 / 448,907 / 98,241 /
97,436 мс**. Это четыре отдельных наблюдения, не p95 десяти повторов.

Для сравнения сохранена трасса того же сценария:
`document-controlled-before-1122.trace` **91,107 с**, новый процесс PID 2275
наблюдался с 17,626 до 89,521 с. CPU total delta **81,585 с**,
sampled **82,804 с**, main **4,830 с**; inclusive подготовка истории
**54,258 с**, полное дерево **45,118 с**. CPU p95 **227,955%**, footprint
peak **300 729 640 bytes**, конец **217 400 640 bytes**, hangs >250 мс — 0.
Предупреждения xctrace `dylibs overlap` для libdyld/libSystem сохранены:
трасса не названа чистой или приёмкой всех системных показателей. Собственные
адреса Notebook разрешены по UUID и загрузке конкретного PID; Activity Monitor
считает процесс независимо от имён системных стеков. Разбор —
`controlled-before-summary.json`, воспроизводимый анализатор рядом.

В 11:28 UTC установленная **in-place** verified-пара source `8971b73b…`
подтверждена публичным MCP: connected, сохранённый блок побайтно тот же.
Mac UUID `69EB8546-C60D-394C-9E3B-29DE194DF89E`, iPad UUID
`F22102CD-1BDA-3FFA-A7B4-3603F6467070`. Квитанции:
`.build/seven-slices-history-tree-pair/build.json` и
`.build/seven-slices-history-tree-install/installation.json`. Mac-содержание и
допуски до запуска неизменны; допуск iPad совпал, контейнеры не сброшены.
Профиль подписи всё ещё до 14:15:33 UTC.

`document-controlled-after-1129.xcresult` — **PASS**, тот же сценарий с cold
launch, поиском, сохранённым хвостом, дальней ссылкой и возвратом; оригинальные
PNG сохранённого хвоста и главы 12 просмотрены. В
`document-controlled-after-1128.trace` новый PID 2315 наблюдался с 27,797 до
89,615 с: CPU delta **57,327 с**, sampled **58,494 с**, main **6,344 с**;
inclusive подготовка истории **26,991 с**, общее дерево **14,453 с**.
Повторные полные построения внутри среза устранены, но подготовка источников
ещё занимает **12,341 с**, а `readSpatialInk` **17,593 с** (inclusive).
CPU p95 **249,243%**, footprint peak **479 053 528 bytes**, конец
**375 998 120 bytes**, hangs >250 мс — 0. Это **не** общий PASS ресурсов:
память выше предыдущего измерения, фон остаётся тяжёлым.

Сравнение трасс ограничено: новый процесс наблюдался 61,818 с против 71,895 с,
а сохранённая стартовая страница различалась. Поэтому 82,804→58,494 с sampled
CPU не названо точным коэффициентом ускорения приложения. В export после
завершения второй трассы также были `dylibs overlap` системных библиотек;
разбор сохранён в `controlled-after-summary.json`. Первая слишком ранняя
попытка export до завершения сохранения trace отказала; повтор читает уже
законченный trace и не изменяет его. Это не отказ приложения.

Четыре native request→installed после фикса: **1337,415 / 461,264 / 85,604 /
90,143 мс**. Первый теперь `cause: open`, тогда как предыдущие 453,602 мс были
переходом `cause: page`: напрямую их сравнивать нельзя. При открытии content
ready наблюдался через **377,596 мс**, установка — ещё через **959,818 мс**.
Цель первого показа ≤1 с здесь **не достигнута**; готовность канонического
содержимого не выдана за установленную страницу. Десять повторов и разбор этой
границы ещё нужны. Срез 7, неизвестный пустой переход, 30 минут смешанной работы,
системные кадры/GPU и второй Mac остаются открыты.

## 16 сентября, 10:53 UTC — восстановлен физический маршрут Pencil

На отдельном листе `74DE027C-DDC6-4C31-85EF-99ACD28B787F` Амир провёл
настоящим Pencil линию, но она не появилась. Независимое чтение установленного
Mac показало пустое `drawingData`, revision 0; физическая AX — 0 действий пера.
В системном Bluetooth Pencil был подключён. Диагностическая подписанная
iPad-сборка повторила отказ: первый `hitTest` получил пустой `allTouches`,
затем window-observer увидел **6 Pencil-контактов** на `_UIHostingView`,
а `PaperInputView` — **0**; резервирований действия тоже 0. Свидетельства:
`.build/seven-slices-pencil-diagnostic-install/console.log`,
`pencil-refusal.json`, `.build/seven-slices-physical/pencil-current-readable.json`
и `pencil-refusal-1018.xcresult`. Ошибка не приписана устройству или связи.

Удалено определение типа в `hitTest` и его Simulator-исключение. Единственный
`PaperPencilGestureRecognizer` получает уже типизированный контакт окна,
проверяет установленную геометрию и границы ввода, затем передаёт измерения
существующему владельцу чернил. Палец не входит в этот маршрут; принятый Pencil
отменяет ввод лежащего ниже вида. Уточнения нажима после отпускания сохранены.
При снятии владельца действие явно завершается, не полагаясь на синхронный
`UIGestureRecognizer.reset`. В коде принимается только контакт потомка native
text, не перекрывающей кнопки чата. Временная контактная диагностика удалена.

Регрессия воспроизводит начальный пустой event и последующий типизированный
Pencil поверх выбранной живой программы; проверяет SQL-запись одного штриха,
неизменный HTML и камеру. На старом коде она отказала из-за отсутствия владельца
типизированного контакта (`.build/seven-slices-physical-pencil-negative`).
Промежуточный v2 честно сохранил **39 PASS / 2 FAIL**: снятие не завершало
действие, а контакт кнопки чата добавлял лишний штрих на коде. Оба исправлены,
ожидание одного действия не ослаблено. На неизменном source
`e2b61ff1c8fb919aaaee7fdb1bc66a8e3207cfe732ecbcba85e76b376181d118`:
**41 iPad PASS, 0 skips/runtime warnings**, включая настоящие Simulator-жесты
на бумаге и коде, cold reopen, поздний нажим и снятие владельца.
Квитанция: `.build/seven-slices-physical-pencil-owner-v3/verification.json`;
просмотренные изображения отдельно в `seven-slices-physical-pencil-owner-v3-images`.
Эта квитанция сама по себе не заменяет физический Pencil; его повтор после
установки описан ниже.

Первая сборка пары с этим source успешно собрала оба приложения, но итоговая
проверка правильно отказала: агент экспортировал дополнительные изображения
внутрь уже неизменного каталога доказательств. Экспорт перенесён наружу;
исходные хеши всех свидетельств вновь совпали, повторных тестов ради пути нет.
Отказ сохранён в `.build/seven-slices-physical-pencil-final-pair/build.json`;
повтор выполнен отдельным штатным маршрутом, квитанция отказа не переписана в PASS.

В 10:47 UTC `.build/seven-slices-physical-pencil-final-pair-v2/build.json`
получил `verified-build`; пара установлена **in-place**. Mac UUID
`B7401DF1-05FA-3A16-8A05-5F5F2454AF2F`, iPad UUID
`3EE2AE1B-3441-322B-9CB2-4464F50C0366`. Mac-содержание до запуска и допуск iPad
не изменились, контейнеры не сбрасывались. Обычный публичный MCP подтвердил
`connected`, прежний лист и revision 0; физический screenshot показал открытый
лист и выбранную ручку. Квитанция установки и baseline —
`.build/seven-slices-physical-pencil-final-install/`;
`pencil-fixed-inspection-1047.xcresult` — PASS. Профиль пока тот же, действителен
до 14:15:33 UTC; вход в Apple Account по-прежнему не назван его продлением.

После повторного рисования Амира физический iPad показал **9 действий пера**,
все линии и надпись видны на просмотренном исходном screenshot. Независимое
чтение установленного Mac подтвердило **9 активных pen actions / 1519 samples**,
revision `9@59adbe6e-f995-48ec-857a-26e7e3513d80`, измеренный force 0…0,537.
После полного завершения и запуска iPad те же 9 действий и рисунок восстановлены:
`pencil-fixed-cold-reopen-1052.xcresult` **PASS**. Оригинальные PNG до и после
просмотрены. Повторное публичное чтение Mac дало те же 329 698 bytes,
SHA-256 `0e8c9d63a322d205774613641edec57900dfa89d3006abad72b4d73fc7f78c4f`.
Это реальное перо, не XCTest finger; тест только проверял восстановление.
Данные и разбор — `accepted-ink-summary.json`, `cold-ink-summary.json` в каталоге
установки. Первый запрос полного page упёрся в 256 KiB лимит одного события;
чтение выполнено ограниченными частями, незавершённый run продолжен через resume,
не повторением эффектов. Этот отказ чтения не был потерей чернил.

### Системное измерение ресурсов: точная область

До диагностической сборки, на установленном source `b8556b65…`, снят чистый
Time Profiler + Activity Monitor за **46,078 с** (10:13:32–10:14:18 UTC):
`.build/seven-slices-physical/paper-cpu-memory-1013.trace`. На экране — бумага,
при этом уже работала диктовка/ожидание GPT. Это не изолированный pen benchmark.
45 системных наблюдений процесса: CPU p95 **10,20%**, peak **11,94%**;
physical footprint от **162 301 200** до **170 001 680 bytes** (154,77–162,13 MiB).
Накопленный CPU за интервал 3,094 с; выборки Time Profiler — 2,963 с, из них
main 0,312 с. Potential hangs более 250 мс — 0. Этот экспорт не содержит
предупреждения overlapping dylibs прежней трассы. Разборы:
`paper-1013-resource-summary.json`, `paper-1013-cpu-summary.json`.

Заметны фоновые persistence/chat SQL-стеки; сами по себе они не доказывают
блокировку UI или необходимость ещё одного кеша. Измерение не названо FPS,
проверкой утечек, десятью повторами или 30-минутной смешанной приёмкой.
Срез 7 и прежний непрояснённый пустой переход остаются открыты.

## 16 сентября, 09:58 UTC — реальный первый ввод и исправление выбора владельцев

Авторизация Xcode выполнена: Apple Account доступен, штатная подписанная сборка
проходит. Однако Xcode использовал прежний ещё действующий профиль
`013872c3-6976-487c-ba24-981388d09c55`, истекающий сегодня в **14:15:33 UTC**.
Вход не выдан за продление; кеши профилей, ACL и ключи не очищались.

На установленной паре физический iPad открыл настоящий проект Notebook,
README и zsh PTY. Команда с iPad вывела собственный marker и PID `40313`;
независимый `ps` подтвердил shell под Mac-владельцем. Скрытие/открытие терминала
и завершение/повторный запуск iPad сохранили этот вывод и тот же процесс Mac,
без повторного исполнения команды. После cold launch компаньон по контракту
свёрнут; его обычное открытие восстановило терминал. Прежнее ожидание вывода
при свёрнутом компаньоне было ошибкой теста, не потерей PTY.
Свидетельства: `.build/seven-slices-physical/readme-terminal-0917.xcresult`
и `terminal-restore-0921.xcresult`. Это проверка первого Mac, не второго.

Для дальнейших действий через публичный MCP создана отдельная доска
`139057B3-F517-4053-8CE3-AFCDD573AFCA`, четыре программы, два SVG,
заголовок, примечание, документ и блокнот. Содержание Амира не изменялось.
После кадрирования четырёх программ D оказалась размытым статическим снимком.
Настоящий первый короткий контакт только активировал её: **D осталась 0**.
В `.build/seven-slices-physical/fourth-program-0942.xcresult` сохранён этот
отказ; `SceneCompositionSQLTests` независимо воспроизвёл три runtime вместо
четырёх (`.build/seven-slices-fourth-runtime-negative`). Причина — выбор
физических владельцев по ID: заголовок и примечание вытесняли программу.

Исправлен единственный выбор владельцев: видимый ввод раньше необязательной
статической детализации, закреплённый контакт раньше обоих. Планирование и
назначение runtime разделяют одну проверку видимости. Лимиты не увеличены,
перезапуск WebKit или активационный тап не добавлены. Проверки неизменного
source `b8556b65a2c26105e899e1bd23ec28614e1adf88df855314c7ae41ee4fa9609f`:
**39 native iPad + 18 Mac PASS**, 0 skips/runtime warnings, в
`.build/seven-slices-runtime-owner-verified` и `seven-slices-runtime-owner-mac`.

Подписанная пара установлена in-place; Mac UUID
`076D03FA-0225-33BC-B8D8-2DD2F80E5628`, iPad UUID
`138E8DB9-1CD0-39A6-B2F5-8DA1C3126A20`. Квитанции:
`.build/seven-slices-input-priority-pair/build.json` и
`.build/seven-slices-input-priority-install/installation.json`.
До запуска байты Mac-содержания прежние, допуск iPad прежний; uninstall,
сброса данных или копирования ключей нет. Обычная связь восстановилась.

На физическом iPad каждая из четырёх кнопок после первого касания дала
**0 → 1**, поле A сохранило `physical 20260916`, настоящий короткий drag
ползунка изменил **25 → 79**, не передвинув камеру. A проверена первой в
`input-priority-contacts.xcresult`; остальные кнопки и ползунок — в
`visible-contacts-0958.xcresult` (**PASS**). Независимое чтение установленного
Mac подтвердило все четыре `count: 1`, текст и `level: 79`:
`visible-contacts-read-readable.json`. Оригинальный PNG после контактов
просмотрен: все четыре программы резкие, SVG и подписи присутствуют.

Промежуточные отказы harness не переименованы в PASS: поиск сначала выбирал
одноимённую кнопку под popover вместо строки коллекции; другой запуск искал
B за пределами viewport; системный `adjust` не получил scrubber attributes
WebKit. Кроме того, после движения native WK физический iPad тоже возвращает
некоторые child AX-координаты `(20,60)` вместо экранных. Решающий положительный
сценарий использовал точки просмотренного кадра и настоящие UIKit-контакты,
не JS click или запись состояния. Продуктового обхода private API нет.

**Срез 7 остаётся открыт.** Первый вход в новую доску ранее действительно
оставил пустой экран с «Ожиданием ресурсов изображения», несмотря на доставку.
Холодный запуск показал материалы, но не доказывает исправления перехода.
Терминальный отказ композиции теперь пишет адресную диагностику;
переход проверяется отдельно от исправленного первого тапа. На обновлённой
паре поиск настоящей обложки в корне → поиск далёкой дочерней доски прошёл
без перезапуска: `warm-distant-1001.xcresult`, 1 PASS, 20,087 с на весь сценарий.
Это один другой повтор, не локализация причины первоначального отказа.

Физическая Animation Hitches трасса старой установленной сборки записана
за 100,819 с терминала/клавиатуры/cold launch. Найдены **38 Notebook hitches**
(max 41,683 мс) и **39 potential main-thread delays >33 мс**
(p95 287,924 мс, max 609,493 мс). Для 147 сопоставленных кадров p95 lifetime
50,017 мс; это не FPS и не касание→фотон. Таблица GPU описывает композицию
совпавших swap, не исключительное время GPU приложения. Экспорт сообщает
пересечение device dylibs; CPU-атрибуция не признана полной, footprint/RSS
не измерены. `.build/seven-slices-physical/terminal-trace-assessment.json`
сохраняет числа и ограничения. Это не приёмка плавности, 10 полных физических
повторов, 30 минут смешанной работы, физического Pencil/голоса или второго Mac.

## 16 сентября, 08:50 UTC — системные подтверждения iPad и первого Mac

После подтверждений Амира физический runner действительно выполнил
`testInspectInstalledWorkspace`: **1 PASS**, 0 failures/skips/runtime warnings,
iPad Pro 11-inch (3rd generation), iOS 27.0 / 24A435. Активировано именно
установленное `com.amirtlinov.notebook.preview`; приложение и данные не
переустанавливались. Оригинальный снимок рабочего места просмотрен.
Свидетельство: `.build/seven-slices-physical/confirmation-0848.xcresult`.
Прежний timeout Enable UI Automation больше не является текущим блокером.

Публичный MCP первого установленного Mac завершил запуск
`6f9683df-8515-46cc-b043-2c594a9c0028`: `completed`, событие ready,
`error: null`, `effects: []`. Результат сохранён в
`.build/seven-slices-installed-pair/confirmation-0850-response.json`.
Ожидание ScriptService до main также снято обычным системным разрешением,
без изменения ACL, контейнера или подписи.

Это допуск к физической приёмке, не её выполнение. Остались полные сценарии
среза 7 и вход владельца в Apple Accounts Xcode для обновления истекающего
профиля. Автоматическое управление окном Xcode отказало с ScreenCaptureKit
-3811; владельцу передан обычный путь Settings → Apple Accounts.

## 16 сентября — полный набор и принадлежность проверки записи

`.build/seven-slices-full-v4` запущен один раз на общем source
`13e3d53c00b1d54949a55a5e97328207fe80ab52602751c735cad655a325bf4b`.
697 Core, 49 Codex, 29 Archive, 15 AgentSDK, 12 Computation, 212 Mac и
918 iPad (846 native + 72 UI) **PASS**. Оба xcresult: 0 failures, skips и
runtime warnings. Три UI-отказа предыдущего полного прохода здесь также PASS.
Оригинальное изображение безоконного Mac-помощника просмотрено.

Сам полный маршрут завершился **FAIL**, не опубликовав `verification.json`:
последующая SQLite-проверка ожидала один штрих в общей `DrawingResponsiveness`.
Тест пера завершился в 07:52:50 UTC, а позднейшие сценарии создали эту общую
фикстуру заново в 07:57:18 UTC. Прочитанный counter 0 принадлежал другому
сценарию, не потерянному штриху. Свидетельства и границы сохраняет
`.build/seven-slices-full-v4/assessment.json`.

Исправлен именно маршрут доказательства: у существующего pen-сценария теперь
своя `PenPersistence`; строгая проверка «один лист, counter == 1» читает её.
Сценарий дополнительно завершает приложение и проверяет 81 действие после
холодного открытия; исходный PNG просмотрен, новый штрих виден. Следующий
настоящий terminal UI-сценарий заново создаёт обычную фикстуру. После обоих
тот же SQLite-check отказывает на старом адресе (0) и проходит на адресе пера
(1). Счётчик не исправлялся вручную, условие не ослаблялось.

`.build/seven-slices-pen-proof-owner`: **2 UI PASS**, 0 skips/runtime warnings,
неизменный source `2b370a0e95242f114853e2a6ea20a23f961705461556111ac4f1ba9954191b9b`;
`.build/seven-slices-pen-proof-postcheck.json` содержит независимое чтение.
Изменены только Simulator DEBUG-фикстура, её UI-тест и проверочный shell-путь;
Release-поведение и установленная пара не менялись. Старый полный отказ не
переименован в PASS, часовой набор ради этой адресации не повторялся.
Это не приёмка физического Pencil, производительности или среза 7.

## 16 сентября — неизменный Release v4: документ, агент и установленная пара

Private Release v4 собран из `f1d8286704da80b69e81b66be6efc9ccbeb570c6`,
source `13e3d53c00b1d54949a55a5e97328207fe80ab52602751c735cad655a325bf4b`.
`.build/seven-slices-release-v4/build.json` подтверждает Release без DEBUG и
неизменность входов. Обновлён тот же private run
`d3f8489d-d961-46b1-8f07-3cc0cb89a795`, а не новый пустой стенд.

Большой документ (140 блоков, 35 SVG, 1680 формул, около 6,9 млн символов):

| Настоящий UI-сценарий Simulator | Результат текущей сборки |
| --- | --- |
| Cold → дальняя ссылка → назад | PASS; 441,143 / 189,851 / 160,884 мс, по одному переходу |
| 10 cold / 20 warm установок | PASS; cold p95/max 470,336 мс, warm p95 222,013 мс, max 238,305 мс |
| Дальняя ссылка → назад → ввод → Save до закрытия → kill → cold reopen | PASS, 114,071 с; новый текст виден после Save и сохранён после перезапуска |
| Реальный Codex → человеческая правка → устаревшая CAS → собственная отмена | PASS, 282,377 с; человеческие счётчик и текст сохранены |

Задержки — request→native installed/input-ready, не touch-to-photon, кадры или
физический iPad. Есть 10/20 отдельных квитанций новых установок. Оценки:
`.build/seven-slices-release-v4-short-analysis/assessment.json`,
`.build/seven-slices-release-v4-openings-analysis/assessment.json` и
`.build/seven-slices-release-v4-lifecycle-analysis/witness.json`.
Просмотрены оригинальные PNG после Save и source-editor после cold reopen:
новый marker `76E33743-7AC8-4B97-82E2-EF10FB680257` и прежний marker сохранены.
Независимое публичное чтение Mac подтверждает одну новую строку и переход
human version 1→2; это не только утверждение UI-теста.

Совместный сценарий использовал настоящий Codex и настоящий ввод XCTest:
счётчик 87→88, `Human edit 49df075d-25a9-4cf7-9ad6-7cb1161b58fa`.
Публичный журнал подтверждает `revision_conflict` / `notSaved` для устаревшей
CAS и `preservedCount: 1, restored: 0` для отмены действия
`D8AB4100-D98C-40E0-82EC-D66789F9DFD8`. Квитанция отмены не заявляет новый
показ, когда она не изменила содержание. Доказательство:
`.build/seven-slices-release-v4/public/collaboration-independent-assessment.json`.
Первая попытка остановилась на сохранённом черновике прежнего offline-теста,
до отправки агенту. Только этот тестовый черновик удалён обычным UI-вводом;
хранилище не очищалось, проверки сценария не ослаблялись.

Экспорт после правки завершён: PDF 1.7, 35 страниц A4, 2 331 801 байт, SHA
`393aa6376e61eb29b4e7b3a627b1e1b8e4d06e90ce7422a888fe716ba6f62446`.
Независимый `pdftotext` нашёл новый marker ровно один раз и дальнюю Chapter 136;
первая страница просмотрена, формулы и тонкие линии SVG видны. Сохранены
35 предупреждений компилятора о включении PDF 1.7 при начальной настройке 1.5;
это не результат «без предупреждений» или визуальный просмотр всех страниц.
Оценка: `.build/seven-slices-release-v4/public/export-assessment.json`.

**Системная трасса не дала общей приёмки плавности.** Три сегмента Time Profiler
привязаны к точным PID и UUID бинарника `267D58F8-7531-3949-9CDF-C73B3FBE0214`.
У двух рабочих процессов есть 8 potential Brief Unresponsiveness 101,815–249,697
мс. Выборки показывают главным образом создание поиска/NavigationStack,
переходы системной клавиатуры и WebKit focus; некоторые мелкие app-стеки также
присутствуют. Это локализация наблюдаемой работы, не доказательство, что все
причины принадлежат ОС, и не основание добавлять обход клавиатуры или кеш.
В `.build/seven-slices-release-v4-trace-analysis/` сохранены таблицы,
`assessment.json` и `hang-stack-assessment.json`. Эти 1-мс статистические
CPU-выборки не измеряют WebContent, GPU, память, dropped frames или физический
touch-to-photon. Нужна проверка тех же действий на устройстве.

Контрольный v4 сценарий без поиска/панорамирования/ввода текста:
`testTenReadyControlContactsForSystemTraceDiagnosis` **1 PASS**, 0 skips и
warnings, десять настоящих нажатий дали по одному изменению счётчика.
Time Profiler PID 28600, тот же UUID бинарника, содержит main-thread выборки
от 380,848 до 19 922,847 мс и **0 potential hangs** с порогом 100 мс.
`.build/seven-slices-release-v4-controls-analysis/assessment.json` не объявляет
это pixel-latency ≤100 мс, кадрами или общей плавностью: проверен только уже
видимый control без переходов поиска/клавиатуры. Внешняя zsh-обёртка после
успешного runner попыталась записать readonly `status` и завершилась 1;
неизменные `scenario.json` / xcresult подтверждают runner exit 0 и PASS.

**Установка — выполнена, физическая приёмка — нет.** В 05:59 UTC текущая
подписанная пара установлена in-place: Mac UUID
`713A1029-4771-33D0-91E8-C5CFAED00F87`, iPad UUID
`9ED1CEFE-1D79-3D76-98B1-02CF47115DAA`. Версия осталась 0.3.62 (65), поэтому
идентичность сборки доказывают manifest/UUID, не номер версии. Mac-содержание
и допуск до первого запуска побайтно прежние; допуск, actor и текущее место
iPad сохранены. Обычное соединение восстановлено. Два новых публичных MCP
инструмента проверены через sidecar именно установленного помощника.
Доказательства: `.build/seven-slices-installed-pair/installation.json` и
соседние квитанции. Нет uninstall, сброса контейнера, восстановления старого
архива или копирования ключей.

Начальная физическая UI-попытка не выполнила ни одного теста: отдельный системный
запрос «Enable UI Automation» потребовал код-пароль iPad. Повтор в 06:20 UTC
после исчезновения диалога также не начал тесты: тот же timeout, хотя
`passcodeRequired: false`. Разблокировка экрана не равна этому разрешению.
Первый production
`notebook_execute` также не исполнил код и завершился `script_timeout` без
эффектов: подписанный ScriptService ждёт обычного подтверждения macOS доступа
к контейнеру со старым ad-hoc ACL. Это подтверждено стеком до `main` и журналом
`libsecinit_appsandbox`; обход разрешений и удаление контейнера не применялись.
Отдельно профиль iPad истекает 16 сентября в 14:15:33 UTC, список Apple Accounts
Xcode пуст. Владельцу переданы запросы системных подтверждений и входа, не QA.

**Срез 7 остаётся In Progress.** Не закрыты физические Pencil/voice, весь
рабочий цикл файлов/терминала/reconnect, кадры/CPU/GPU/память, десять физических
повторов и 30 минут, обычное сопряжение второго Mac. Подготовка второго Mac
описана в `docs/computer-enrollment.md`. Прежние записи о неустановленной паре,
недоступном кабеле и ожидающем v4 ниже являются историей, не текущим состоянием.

Дополнение 06:52 UTC: установленный ScriptService **второго Mac** завершил
публичный запуск `aba68e8c-8220-40fa-a2e3-622b7b6353ea` с одним событием ready,
без ошибки и эффектов. Подписанный исполнитель работает в новом контейнере;
это не снимает отдельный системный запрос доступа на первом Mac.

Попытка продолжить файлы/терминал через настоящий UI того же private Release
остановилась на предусловии: «В Codex пока нет проектов». Это ожидаемая граница
`CodexCatalogue.projects`: private `runtimeScope` возвращает пустой список и
не разрешает доступ к рабочим проектам. Диагностический XCTest
`testInspectProjects` **FAIL** через 20,453 с, а не проверка файлов или PTY.
Снимок фактического экрана подтверждает пустой список. Материалы:
`.build/seven-slices-draft-preparation/workplace-projects.log` и
`workplace-projects-assessment.json`. Продукт не изменён ради снятия этой
изоляции, фиктивный проект и echo-терминал не подставлены. Полный рабочий цикл
остаётся задачей установленной допущенной пары после системных подтверждений.

## 16 сентября — живой Save удерживал прежнюю композицию

Private Release v3 (`27824b3`, source `1d56ba0a9364a4ff1a943914389df8f7e74d939f00d6fdcc6c60725cffe2496a`)
сохранил данные той же пары, но повтор 10 cold / 20 warm опять **FAIL** на первой
дальней ссылке. Короткий повтор с navigation observer подтвердил тот же
рабочий набор: 41 composition + 3 agent raster, 117 930 376 удержанных байт.
Теперь источник корректно ожидал admission, но показ целевой страницы не
состоялся (`snapshot_pending`); это не исправленный полный сценарий.

Memgraph настоящего Release PID 22159 после отказа показывает две композиции.
Текущая принадлежит `SceneCompositionTiles.published`, предыдущую удерживает
`DocumentWebCoordinator.onSourceChange` через захваченный `WorkspaceSceneItem`.
Это удержание достижимого объекта, не доказанный retain cycle. Консервативные
ссылки сканера через массивы значений не принимались за сильные Swift-ссылки.
Доказательства: `.build/seven-slices-release-v3-memgraph/assessment.json`,
`cohort-a.txt`, `cohort-b.txt` и исходный memgraph в том же каталоге.

При неизменных пикселях `refreshMountedInput` заменял draft/link callbacks,
но оставлял старый Save callback. Теперь он обновляет и `onSourceChange` у
того же владельца; принятый контакт сохраняет прежний обработчик до завершения.
Не добавлены новый cache, лимит, timeout, reload или замена браузера.

`.build/seven-slices-document-callback-negative/` воспроизвёл удержание старого
cohort в полной нативной сцене с открытым документом. После исправления
`.build/seven-slices-document-callback-fixed/`: **63 iPad PASS**, 0 skips и
runtime warnings, source до/после
`13e3d53c00b1d54949a55a5e97328207fe80ab52602751c735cad655a325bf4b`.
Проверены освобождение старой сцены при том же живом WebKit, Save, весь
DocumentProgramOwner/DocumentResourceLease и настоящий UI-поиск после обзора.
Следующая immutable Release должна заново пройти исходный большой документ;
этот узкий PASS не закрывает срез 6 или физическую приёмку.

## 16 сентября — Release выявил удержание старой сцены и отказ хвоста

Private Release v2 из `3266642`, source
`0c0baf19248de2a5eeb7e58e346402bba929b96a5528e562237fd229c0c19af6`,
обновил только прежний изолированный Mac–Simulator run с сохранением данных и
идентичностей. Общий 10 cold / 20 warm сценарий **FAIL**: десять первых страниц
установились (cold p95/max **488.589 мс**, min 405.325, median 440.334), но первая
дальняя ссылка показала `DocumentPreparationAdmission.Deferred`. Это не warm
результат и не успешная приёмка документа. Оригинальный PNG просмотрен.

Повтор `testColdOpeningAndDistantLinkPublishFreshNativeInstallations` с пассивным
navigation observer также FAIL. После принятия полного индекса распределитель
вытеснил его; затем 117 930 376 байт удержанных растров и 14 056 319 байт резервов
не оставили места для 14 709 094 байт нового индекса внутри прежнего passive
лимита 134 217 728. Источник стал ошибочным. Записи без потерь:
`.build/seven-slices-release-v2/runs/d3f8489d-d961-46b1-8f07-3cc0cb89a795/ipad-testColdOpeningAndDistantLinkPublishFreshNativeInstallations-863c0bf0-4407-433a-866b-4e9c6b68b8e7/`.

Две причины разделены отрицательными опытами:
- `.build/seven-slices-tail-admission-negative/`: временный отказ хвоста
  немедленно превращал ожидающую ссылку в unavailable. Уже выданный первый
  packet удалял page waiter; настоящий читатель/его индекс не учитывался.
- `.build/seven-slices-admission-and-retention/`: хвост после исправления PASS,
  но установленная новая плотность сцены не освобождала старую композицию.
  `WorkspaceSceneItem.equatable` игнорировал новые обработчики вместе с их
  захваченным cohort. `.build/seven-slices-retention-refresh/` подтверждает
  освобождение прежней композиции после удаления этой ручной мемоизации.

Нативные владельцы и их identity сохранены; удалён только заменённый обход
обновления SwiftUI. Подготовка учитывает удержанных читателей, хвост и страницы,
а не только незавершённые packet promises. Резерв, cleanup и отмена остаются у
существующего владельца; новые лимиты, таймеры, Retry или сброс кеша не добавлены.
`.build/seven-slices-paint-lifetime-final/`: **53 iPad + 13 Mac PASS**,
без skips/runtime warnings, source до и после
`1d56ba0a9364a4ff1a943914389df8f7e74d939f00d6fdcc6c60725cffe2496a`.
Проверены native lifetime, реальные WebKit и большие книги, восстановление и
отмена хвоста, установленный перенос, камера, обложка, быстрые UI-перелистывания
и поиск после обзора. Два предварительных selected-вызова были отвергнуты
из-за моих неверных имён UI-тестов; их полные квитанции не PASS. Новый immutable
Release ещё должен повторить исходный пользовательский отказ.

## 16 сентября — тихое уточнение неизменного рисунка

`.build/seven-slices-svg-settlement/` отдельно подтвердил завершение подготовки
после реального щипка и поворота; спокойные оригинальные PNG просмотрены.
Зависания в этом опыте нет. При этом плашка «Обновление…» была лишней:
потребитель смешивал новую плотность/область растра с новым содержанием.
Теперь он сравнивает именно источник установленных пикселей. Уточнение
неизменного рисунка не закрывает его плашкой; новый источник, начальная
подготовка программы и реальные ошибки по-прежнему имеют явное состояние.
Старая плотность не подтверждает новую готовность и не снимает её demand.

`.build/seven-slices-quiet-refinement/`: **26 iPad PASS**, без отказов,
пропусков и runtime warnings, неизменный source
`0c0baf19248de2a5eeb7e58e346402bba929b96a5528e562237fd229c0c19af6`.
Нативный набор проверяет сохранённые пиксели, pending source/crop/density,
действительную замену источника, input/runtime lifetime и видимую ошибку/Retry.
Настоящий UI-щипок в обеих ориентациях больше не показывает плашку; исходный
landscape PNG после жеста просмотрен. Это не измерение physical GPU или p95.

## 16 сентября — поиск после обзора и действительные границы жеста

`.build/seven-slices-page-navigation-probe/` локализовал зависание поиска:
сохранившаяся миниатюра страницы 0 получила живой подготовленный WebKit, а
настоящий page host остался `not_ready`. Отдельная отрицательная регрессия
`.build/seven-slices-thumbnail-negative-v2/` воспроизводит ту же подмену,
потерю снимка миниатюры и незавершённый физический переход. Исправление
оставляет миниатюру потребителем снимка; живой запрос выполняет только
полный физический лист. Новый кеш, повтор подготовки и тайм-аут не добавлены.

`.build/seven-slices-page-navigation-fixed/`: **62 iPad PASS / 0 FAIL /
0 skips / 0 runtime warnings**, source
`2946e96f0c145996f99d57cc8893a7b3537365657e3d38e508c791ff622aa792`.
Проверены весь DocumentProgramOwner, PageTurnSelection и три прежних UI-отказа.
Быстрое перелистывание теперь использует явный Simulator-профиль пальца и
начинает следующий контакт после наблюдаемой посадки, не случайной паузы 250 мс.
SVG измеряется после законченного поворота; порог одинакового масштаба по двум
осям не изменён. Просмотрен оригинальный landscape PNG: геометрия сохраняется,
но кадр сразу после щипка ещё показывает «Обновление…» поверх старой детализации.
Этот кадр не засчитан как восстановленная чёткость после остановки.
Диагностический NSLog и его launch argument удалены до положительного прохода.
Это целевая проверка, не новый полный PASS и не физическая приёмка.

## 16 сентября — сохранённый причинный контекст и общий повтор

Полный `.build/seven-slices-full-v2/` проверял `8d59938`, source
`d7700cc931b39f75d506695cfd89a78045fa4d6291716cabea95903708b268c7`:
694 Core, 49 Codex, 29 Archive, 15 AgentSDK, 12 Computation и 210 Mac PASS;
iPad **910 PASS / 3 FAIL**, без skips/runtime warnings. Остались быстрый
следующий лист, поиск с возвратом и SVG после поворота. Общего PASS нет.
Оригинальное видео поиска показывает страницу 3 и «Открываем страницу 1…»;
SVG-замер захватил промежуточную повёрнутую рамку 366×666, до окончания
системного поворота. Разбор хранится в `.build/seven-slices-full-v2-analysis/`.

Отдельно `.build/seven-slices-upgrade-probe.log` и
`.build/seven-slices-upgrade-sqlite-probe.log` воспроизвели отказ сохранения
допустимых компактных часов прежнего формата: одинаковый автор/значение и
разная накопленная история доставки ошибочно давали `content author context changed`.
Теперь контекст принадлежит регистру, а неизменность — авторской версии и
значению. Дублирующий контекст каждой сохранённой головы удалён; сброса,
переавторства, смены идентичности или отдельного старого пути нет.

`.build/seven-slices-causal-context/core.log`: **401 тест в 33 наборах PASS**,
294.237 с. Новые проверки включают две настоящие SQLite, компактное сохранение,
доставку в обе стороны, холодное открытие, продолжение редактирования и старое
эхо. Подмена значения одного автора отвергается; поздняя независимая человеческая
правка и отмена сохраняются. `.build/seven-slices-causal-context-native/`:
**29 iPad PASS**, без skips/runtime warnings; публикация исходника/состояния,
resize, отмена, удаление цели и актуальная геометрия. Оба маршрута проверили
неизменный source `8019197af559c9dc74ca7a47dc5621b3309a6e8550511740d3f8cf20e79fbeb1`.
Это не полный повтор новой версии. Уже потерянные исторические значения не
восстанавливаются; установленное пространство не использовалось как фикстура.

Граница UIKit/WebKit AX подтверждена отдельным минимальным приложением **без
Notebook**: `.build/seven-slices-direct-web-probe/`, 4/4 вариантов движения
сдвигают native WK на 50.5–59.5 pt, но child AX остаётся на прежнем месте.
Это не доказательство потери касания по настоящему видимому контролу; обход
WebKit в продукт не добавлен. Второй Mac доступен по SSH (read-only preflight,
macOS 27.0 / 26A5416b), но ещё не принят как участник рабочего цикла.
Физический iPad повторно виден через CoreDevice 16 сентября 04:04 UTC;
новая пара не установлена. Физические Pencil/голос, GPU/кадры/память, десять
повторов и 30 минут смешанной работы остаются открытыми.

## 16 сентября — реальные тонкие линии и один ресурс минификации

Исходный дефект подтверждён не только `drawHierarchy`, но и снимком
композитора Simulator (`.build/seven-slices-native-screen-probe/display.png`):
при масштабе 0.03 две центральные линии имели покрытие 0.015686 вместо
ожидаемых 0.21, диапазон десяти линий — 0.015686…0.364706.
Одного `CALayer.minificationFilter = .trilinear` для этого NPOT-снимка оказалось
недостаточно. Вариант с дополнением до power-of-two отклонён: он устранял
дефект, но увеличивал давление памяти и ломал переход большой страницы
(`.build/seven-slices-sampling/`, 84 PASS / 5 FAIL). В продукт он не вошёл.

Теперь владелец исходника готовит общую пирамиду уменьшения с заранее
допущенными байтами. Нативный потребитель выбирает уровень по фактической
установленной геометрии; ни повторного WebKit, ни изображения на каждый
camera sample нет. Исходный CGImage, канонический viewport и геометрия
сохраняются. Новый снимок композитора
`.build/seven-slices-mipmap-compositor-v2/display.png` проверен визуально и
численно: те же десять линий при 0.03/phase=0 дают **0.231373…0.266667**,
без исчезновения. Диагностическая пауза нужна была только для внешнего
снимка и удалена. Это Simulator iOS 27 (24A434), не физический GPU iPad.

`.build/seven-slices-mipmap-integration/`: **148 PASS / 0 FAIL / 0 skips /
0 runtime warnings**. Область: raster/web leases, нативная проекция, crop,
подготовка/публикация композиции, SQL-границы, возвраты, настоящие UI-сценарии
2/4/8 материалов и холодное сохранение. Пороги тонких линий и ресурсные лимиты
не увеличены. Отдельная асимметричная фикстура подтверждает тождественность
исходных пикселей, общие уровни разных потребителей, полный CPU/GPU-учёт и
отказ до выделения. Её 301×173 подготовка заняла 1.60 мс в одном Debug-запуске;
это не p95 и не измерение большого источника на устройстве.

Финальная выборочная проверка после удаления диагностической паузы и
отключения неявной анимации смены уровня —
`.build/seven-slices-mipmap-final/`: **15 Mac + 25 iPad PASS**, без пропусков
и runtime warnings. Включены реальная Mac-композиция/экспорт, камера,
WebKit/raster leases, тонкие линии и системный callback Speech. Квитанция
связывает именно эти неизменные исходники; это не повтор полного `--full`.

Для общей проверки системное разрешение Speech один раз **отклонено** через
настоящий диалог изолированного Simulator; доступ к микрофону также запрещён.
`.build/seven-slices-display-and-permission/`: 2 PASS, callback завершился
без начала записи. Временный bootstrap не оставлен в тестах или продукте.
Производственная пара и её разрешения не изменялись. Полная приёмка Release,
физический Pencil, системные GPU/память/кадры, смешанные 30 минут и второй Mac
этими результатами не подтверждены.

## 16 сентября — уточнение интеграции: текущие пиксели, ввод и граница минификации

После общего FAIL исправлены два дополнительных производственных пути:
неизменный запрос дочерней доски сравнивается с полным уже подготовленным
родительским окном, а видимая программа использует допуск подготовки сцены
во время камеры, не запрет для фоновой работы. Новое содержимое перестаёт
ждать подъёма пальцев. Pencil и контакт изменения содержания по-прежнему
закрывают подготовку. Исходный `SceneCompositionSQLTests` прошёл в
`.build/seven-slices-integration-projection-v1/`; пакет целиком был **43 PASS /
4 FAIL**, не общий PASS.

`.build/seven-slices-contact-v2/`: **32 PASS / 1 FAIL**, без runtime warnings.
Проверены появление нового материала до завершения камеры, владельцы ввода,
настоящие штрихи/ластик Simulator, редактор кода, черновик и диктовка без Mac.
Оставшийся тест ошибочно требовал щипок от контактов, в этом запуске явно
обозначенных Pencil. Теперь реальный Back завершает лист; холодный повтор
того же SQLite с обычными пальцами открывает его снова. Такой сценарий
прошёл в `.build/seven-slices-integration-ui-v1/`. Это не физический Pencil.

Прямые Simulator-контакты классифицирует один `NotebookInputGate`, а не
независимые проверки launch arguments в бумаге и пространственных чернилах.
Исходная проба `.build/seven-slices-pencil-probe.txt` показала пустой набор
`allTouches` при первом XCTest hit-test. Явно допущенная имитация пера теперь
принимается и в этом случае; настоящий iPad всегда использует реальный тип
UITouch. Диагностические NSLog в продукте не оставлены.

Нативные фикстуры приведены к фактически проверяемому сценарию: статический
SVG обязан иметь установленные пиксели, а не три WebKit и очередь четвёртого;
тесты растров создают настоящие растры; родительские плоскости действительно
монтируются, undo меняет paint, а не неизменную geometry identity. Явная
камера не заменяется автоподгонкой, отсутствующий материал не выдумывается
для выбора, ушедший лист читается из SQLite, а не из ограниченного рабочего
набора. Старые отказы сохранены; квоты, тайм-ауты и пиксельные требования не
ослаблены ради PASS.

В `.build/seven-slices-integration-ui-v1/` **6 PASS / 8 FAIL**. Найден реальный
конфликт: 14-point resize-rim чата перекрывал верхние/правые края кнопки 44 pt.
Header теперь размещает всю кнопку за пределами того же rim. В
`.build/seven-slices-controls-v3/` **11 PASS / 1 FAIL**: полный tap кнопки,
движение/размер чата и настоящая пометка на коде прошли. Оставшийся resize
материала сначала подозревался в неверном native leaf. Дополнительная проба
показала другое: центр верхнего левого угла пересёк компактную панель чата
`(18, 231, 172.5, 48)`, а при whole-window pinch второй палец `(763, 1121.5)`
попадал на Create и правильно оставался у native input. Экспериментальный
обход leaf/исключение собственного control region полностью удалены.
`.build/seven-slices-contact-v7/`: **2 PASS / 0 FAIL / 0 runtime warnings**,
с исходным продуктовым арбитражем. Настоящий drag использует видимую часть
44-point угла; щипок выполняется на настоящей созданной дочерней обложке,
не на кнопке в углу UIWindow. Портал найден по опубликованному стабильному ID,
а не по изменяющемуся порядковому индексу. Точная граница и непрерывность
по-прежнему проверяются `PortalPassageTests` (в controls-v4 прошли).

Сводный повтор `.build/seven-slices-integration-recheck/`: **41 PASS / 2 FAIL**,
без runtime warnings. Четыре селектора ссылались на уже переименованные тесты;
они не посчитаны пройденными. В `…-recheck-v2/` новые четыре имени и реальный
штрих прошли (**5 PASS / 1 FAIL**). Исходный штрих начинался под компактным
чатом; контакт перенесён на открытую бумагу, путь и число действий по-прежнему
проверяются. Оставшийся отказ портала — требование автоматического overview
после ещё одного произвольного щипка: родитель уже показан, а камера допустимо
оставалась у его обложки. Проверка теперь требует действительный выход в
родителя (тот же портал с точным ID снова установлен),
не навязывает лишнюю автоподгонку. Проба `…-integration-final/` дала 19 PASS /
1 FAIL: Back служит также возврату из обложки, поэтому его наличие не доказывает
нахождение в дочерней доске. Это лишнее предположение удалено; запись владельца
родительского портала и точная геометрия перехода остаются. Отрицательные
результаты сохранены.

Финальный фактический проход портала `…-portal-return/`: **1 PASS**, без
пропусков и runtime warnings, с приложенным исходным снимком возвращённого
родительского портала. Совокупность узких проходов не объявляется новым полным
`verify --full`; тонкие линии, Speech permission precondition и длительная
смешанная/физическая приёмка остаются явно отдельно.

Отдельная диагностическая замена только разрешения изображения на 2048×1024
вместо 2000×1000 дала **PASS** прежних строгих требований тонких линий: при
scale 0.03 min/max 0.21176/0.21961 вместо прежнего min 0.01569, для live и
portal. Проба находится в `…integration-ui-v1/ipad.xcresult`, полный отчёт —
`.build/seven-slices-integration-ui-analysis/power2/39E1EDFA-1BA3-444B-9C20-1F80D14E5CE0.txt`.
Это согласуется с документированным ограничением некоторых renderers для
[`CALayerContentsFilter.trilinear`](https://developer.apple.com/documentation/quartzcore/calayercontentsfilter/trilinear), но **не готовое общее исправление**:
подгонка теста к 2.048 удалена, его исходные размеры и пороги восстановлены.
Дополнительный per-view raster cache, reload и неучтённая память не добавлены.

Повторный read-only `devicectl` в 01:36 UTC сохранил paired/unavailable для
физического iPad. В **02:12 UTC** устройство появилось по USB: paired/connected,
DDI доступен; реальный `device info lockState` прошёл, passcodeRequired=false.
Доказательства — `.build/slice7-prerequisites/*-0212.*`. Это доступ к устройству,
не физическая приёмка. Рабочая пара и второй Mac не обновлялись. Полная физическая
приёмка и прежний отрицательный результат длительного смешанного сценария
ниже не отменяются этими узкими проверками.

## 16 сентября — полная интеграция выявила отказы; удаление при доставке исправлено

`.build/seven-slices-full/` на source
`86a3aeffeb4df8028a7541491bb0effba7bbd03e2c8a02e0cf140e45135d1fb7`
завершился **FAIL**, а не квитанцией общего выпуска. Прошли 693 Core,
49 Codex, 29 Archive, 15 AgentSDK, 12 Computation и 210 Mac; на iPad —
**863 PASS / 49 FAIL / 0 skips / 0 runtime warnings**. Результаты сохранены,
проверки не переписаны задним числом. Условия физической приёмки ниже остаются
отдельно открытыми.

Реальный дефект адресного удаления воспроизведён в
`.build/seven-slices-deletion-before-v2.log`: изменившееся `items/order`
сохраняло прежнюю авторскую версию. Причинное слияние правильно отвергало
такую доставку: `items/order: content author value changed`. Удаление теперь
публикует версии **двух действительно изменённых полей**, `exists` и `order`,
в той же адресной транзакции. Полный каталог и чужие тела не читаются.

`.build/seven-slices-deletion-after.log`: **31 Core PASS**, включая полный
непрерывный журнал доставки, повторный merge со старым каталогом, холодное
открытие обеих SQLite, отсутствие удалённого документа/состояния и сохранение
соседей. Нативный `AgentStateTests.testRemoteDocumentDeletionRemovesItsDurableOwners`
прошёл в `.build/seven-slices-integration-owner-repro/` и `…-owner-v3/`.
Второй пакет имеет **45 PASS / 3 FAIL**: оставшиеся отказы касались старого
требования нового geometry UUID после undo и прежнего принудительного
центрирования/масштаба страницы. Они не объявлены доказательством сбоя удаления.
Общего PASS пока нет; остальные выявленные отказы продолжают разбираться.

## 16 сентября — срез 7: Release книги принят, общая приёмка ещё открыта

Из чистого `c4b01e2`, source
`e8b8268b405839655d17a8a71dff4b73d6f501c4430a73d19392a74f21428839`,
собрана `.build/seven-slices-release/`. Preserving upgrade только private пары
`d3f8489d…` подтвердил побайтное сохранение содержания, идентичностей и доверия.
Рабочая установленная пара не менялась. Публичный `notebook_execute` создал
новый контрольный документ `1395d17e…`: 140 блоков, >6 MiB, 1680 формул, 35 SVG.

На iPad Air M4 Simulator / iOS 27 `24A434`, Xcode `27A266a`:
- `ipad-testTenColdOpenings…-984a098a…`: **1 UI PASS**, 0 skips/warnings.
  Десять холодных открытий: **p95/max 504.833 ms**. Двадцать тёплых переходов
  на дальнюю страницу и обратно: **p95 189.856 ms**, max 192.410 ms.
  Это native request → установленное каноническое input-ready представление,
  не запуск процесса, touch-to-photon или FPS. Исходные 10/20 записей сохранены
  в attachments `181AE7FA…json` / `EF8773A3…json`.
- `ipad-testBigDocumentFullLifecycle…-3bfa0135…`: **1 UI PASS**, 0 skips/warnings.
  Дальняя ссылка, возврат, настоящая клавиатура, Save, видимое новое содержание
  до закрытия, перезапуск и чтение сохранённого исходника. Оригиналы first/far
  и `493D3FC3…png` before-close просмотрены: формулы и текст чёткие, новая
  строка находится на странице. `4DA58E37…png` после холодного открытия
  показывает проверку сохранённой строки в настоящем редакторе исходника.

Time Profiler успешно записал каждый из трёх PID полного цикла. Mach-O и
arm64 dSYM совпали: `F32CF108-2348-3076-8E9A-8BBE89E808A0`. В основных двух
сегментах 2672/4619 ms статистического веса main-thread samples; обнаружены
**7 brief-unresponsiveness интервалов 110.986–235.122 ms**, не ноль зависаний.
В соответствующих стеках видны построение SwiftUI search sheet и запуск /
переключение системной клавиатуры. Это не доказательство недорабатываемости
приложения или исключительно системной причины. `.build/seven-slices-trace-analysis/`
содержит исходные XML exports и разбор; trace не измеряет GPU, кадры, память
WebContent или физический iPad.

Длительный сценарий `523d04d4…` остановился **FAIL за 45.127 s**. Фиксированная
точка «фона» после rotation попала в кнопку; камера проверки теперь использует
существующий `panFreeBoard` с наблюдаемой свободной областью и фактическим
delta с допуском 1 pt. Count и требования ввода не ослаблены. UI-only повтор
`4760eed1…` на том же приложении прошёл две итерации и остановился на третьей:
старые WebKit AX frames направили tap в `[206,284.5]`, не в показанную кнопку.
Настоящий контакт и отсутствие DOM click записаны в `E7BB8C97…`;
`.build/seven-slices-mixed-analysis/button-no-action.png` просмотрен.
Это незакрытая граница native projection → accessibility, а не потеря уже
принятого кнопкой события. **30 минут не пройдены.** Обход AX, private API,
перезагрузка программы и фиктивное обнуление метрик в продукт не добавлены.

Изолированный UIKit/WK пример `.build/seven-slices-enclosing-scroll-probe/`
также завершился **2 FAIL**: после второго реального pan дочерняя AX-рамка
не следовала фактически показанной поверхности. Обычный native ancestor и
публичный `UIScrollView.contentOffset` дали расхождение; оригинальный PNG
просмотрен. Эта проба не доказывает причину в конкретной версии WebKit, но
отвергает добавление ещё одной scroll-оболочки как готовое исправление.
Диагностическое приложение удалено только из выделенного Simulator.

Повторный `devicectl` в 00:30 UTC знает физический iPad как paired, но
`tunnelState=unavailable`, `ddiServicesAvailable=false`; реальный запрос
lockState отвергнут CoreDevice 4016 (trusted connectivity unavailable).
Это не доступное устройство для установки или измерений. Второй Mac
проверен по SSH с ранее доверенным host key, но не установлен и не сопряжён.
Физический Pencil, голос, кадры/CPU/GPU/общая память и 30 минут совместной
работы остаются открытыми условиями; срез 7 не объявлен завершённым.

## 16 сентября — срез 6: Save виден до закрытия, фоновый снимок не читает книгу

В `.build/slice6-before-v2/` **1 FAIL** воспроизвёл ненужную работу: после
готовности одного фонового листа начинался typesetting далёкого хвоста, хотя
читатель его не запрашивал. Теперь продолжение навигационного индекса принадлежит
текущей странице. Передача уже готового фонового WK текущему читателю продолжает
тот же источник ровно один раз. Отдельного состояния активации, кеша или
повторного render для передачи не добавлено. Фокус окна не подменяет наличие
текущего читателя; это разные основания ввода и подготовки.

`.build/slice6-cycle-v3/verification.json`: **1 Mac + 19 iPad PASS**, 0 skips
и runtime warnings, source
`f34e07768eec856b84dff8208717cc5b26c7357d513b54a51bc531795c85a358`.
Все проверки большой книги, Save через смену host и сломанного соседа,
адресная долговечность источника, receipt редактора и настоящий UI-цикл:
дальняя ссылка → назад → клавиатура → Save → читаемый новый текст → закрытие
pinch → завершение процесса → холодное чтение SQLite → открытие → обе ссылки.
Оригиналы before-close и `D779289A…png` cold-reopened просмотрены: новая строка
есть на бумаге, не в скрытом редакторе. Явный флаг повторного открытия fixture
сохраняет тот же изолированный каталог вместо повторного seed.

После добавления проверки неизменного runtime при правке соседнего текста:
- `.build/slice6-final/`: **30/30 Mac DocumentRuntime PASS**; iPad обнаружил
  три устаревших предположения проверки — полный индекс сразу после первого
  показа, квоту ровно трёх программ и готовность четвёртой как свидетельство
  завершения чужих checkpoint. Они заменены явным ожиданием нужного индекса,
  действующим общим допуском и настоящими квитанциями освобождения. Старые
  квоты не возвращены, требования пикселей/состояния/освобождения не ослаблены.
- `.build/slice6-final-v3/verification.json`: **39/39 iPad PASS**, 0 skips и
  runtime warnings; source
  `e8b8268b405839655d17a8a71dff4b73d6f501c4430a73d19392a74f21428839`.
  Полный DocumentProgramOwner, новый фоновый сценарий и повтор UI-цикла.
  Локальный Save текста сохраняет WK бумаги и соседней программы, её JS nonce,
  счётчик и несохранённое DOM-поле. Девять программ сохраняют видимые пиксели
  при ожидании, checkpoint при уходе и освобождают runtime/нативные картинки.

Ранние `slice6-before`/`slice6-cycle` имели слишком короткий первый блок, который
не отделял две буферные колонки от хвоста; исправлена фикстура. В v2 обнаружены
неверная зависимость продолжения от key-window и отсутствующий finger-профиль
UI-повторного открытия (контакт уходил в Simulator Pencil); оба устранены.
Ни один отрицательный прогон не объявлен успешным. Это Debug Simulator и Mac,
не p95, физический Pencil или окончательная приёмка Release. Рабочая пара
не обновлялась; седьмой срез остаётся открытым.

## 16 сентября — срез 5: полезная страница раньше далёкого хвоста

`.build/slice5-before/` воспроизвёл общий барьер: **1 FAIL**, первая страница
не готова, пока намеренно заблокирован MathJax далёкого блока. Подготовка
теперь продолжает один и тот же канонический поток вперёд. Первый запрос
принимает нужные страницы, оставляя два незавершённых столбца за границей;
полный индекс приходит после установки настоящих пикселей. Нет второй
пагинации, дополнительного WK или кеша книги. Полные исходники по-прежнему
кодируются один раз; очень большой одиночный блок готовится целиком.

Принятые страницы, текстовые адреса и авторские якоря при продолжении не
могут менять геометрию. Реальный Mac WebKit в промежуточном прогоне изменил
предпоследний столбец примерно на 4 pt: исправлена граница принятия, а не
ослаблена проверка. Ссылка на ещё не измеренный хвост ждёт индекс и повторно
проверяет владельца показа. Неизвестная страница не считается страницей без
программ. Фрагментный рецепт `/5` не выдаёт прежние растры за новые.

Проверки:
- `.build/slice5-final-v2/verification.json`: **16 Mac + 49 iPad PASS**,
  0 skips; source `d4d858ef5c302c653bfa15c79c25dd906baa10876f3264f0ac7e0146e920fe32`.
  Большая книга (140 блоков, >6 MiB, 1680 формул, 35 SVG), закрытая обложка,
  размерные/неразмерные и сломанные изображения, освобождение индекса,
  повторное измерение, плотность страницы, отмена и реальная UI-ссылка/возврат.
- После последней защиты неизвестного набора программ:
  `.build/slice5-prefix-programs-final/verification.json`: **31 Mac + 3 iPad
  PASS**, 0 skips; source
  `e8904ffa10d424883fa6faa9bd4cc111d8f6f1e8fe30a35ec4c6592ccfd73bfd`.
  Полный Mac DocumentRuntime, заблокированный хвост на обеих платформах,
  независимость бумаги и ввода от состояния программы. Повторная проверка
  математики считает новые блоки, а не прежний единый вызов на всю книгу;
  неизменный сосед по-прежнему не typeset-ится.
- `.build/slice5-web-tests-final.log`: **15 PASS**; `.build/slice5-core.log`:
  **4 Core test functions PASS**, включая параметризованные старые рецепты.

В первом широком проходе полезный показ при заблокированном хвосте занял
**0.078 s**, холодная подготовка большой книги в уже запущенном тестовом
приложении — **0.944 s**, пик учтённых производных выделений — **27,735,322 B**.
Это единичные Debug-замеры, не p95, запуск процесса или системная память.
Пиксели первой страницы до/после хвоста и дальнего возврата совпали точно;
повторное полное измерение после освобождения индекса сохранило их. Оригиналы
`A15AAB6F…png` и `AA8C87FD…png` просмотрены: резкие формулы/текст и настоящая
дальняя страница с обратной ссылкой. Рабочая пара не устанавливалась.
Полный цикл Save/холодного открытия и физическая Release-приёмка ещё открыты.

## 16 сентября — срез 4: завершение контакта не воскрешает удалённую цель

В `.build/slice4-before/` отмена сохранила чужую правку, но поздний lift после
агентского удаления воспроизвёл восстановление материала из старого снимка:
1 PASS, 1 FAIL (три нарушенных условия). Удалён заменённый путь записи рамки
через полный старый PageDocument/BoardDocument. Действующий контакт удерживает
авторскую версию ID, исходную рамку и мировую опору; адресная команда Core
проверяет их в транзакции. Нет нового распознавателя, реестра lifetime или
слоя активации над живыми контролами. Принятый фронт обновляет модель вместе
с соседями, изменёнными во время контакта; удалённая цель снимает выбор.

Итоговые неизменные исходники
`1ec8aca858d871a0239d11ea23f5232c9ba518b3848542159194d9602d6375a1`:
- `.build/slice4-frontier-after/verification.json`: **18/18 native PASS**,
  0 skips/warnings. Отмена, чужой исходник и чернила, удаление, повторное
  создание того же ID, старый lift/Pencil, два переноса и новый сосед.
- `.build/slice4-ui-final/verification.json`: **4/4 UI PASS**, 0 skips/warnings.
  Первый tap/slider/поле, pan/pinch фона, удержание SVG, связанного изображения
  и программы без текстового меню; перенос и удаление не затрагивают соседа.
  Экспортированные оригинальные снимки просмотрены: значение 760 и фокус
  поля сохранены при переносе, рамка совпадает с материалом.
- `.build/slice4-core-accepted.log`: **7 Core PASS**. Свежая чужая правка
  сохраняется, удалённая цель отсутствует и после холодного открытия.
  Адресный перенос страницы с соседним исходником 8 MiB занял **3494 SQL VM
  steps**, не читая/переписывая соседей и чернила; это объём SQL, не время UI.

Промежуточные `.build/slice4-lifetime/` и `.build/slice4-frontier-before/`
обнаружили оставшийся выбор и непринятый фронт нового соседа; оба исправлены,
регрессии включены в итог. Это Debug Simulator, не физический iPad или
системные FPS. Рабочая пара не обновлялась. Срезы 5–7 остаются открыты.

## 16 сентября — срез 3: поздняя правка не теряется при другом порядке доставки

GUI-197 воспроизведён на действующем Core: A — X10 human, B — Y11 agent,
наблюдавший A, C — Z9 human, конкурентный B. До исправления две проверки
в `.build/slice3-before-swift.log` дали 18 нарушений; в том числе настоящий
PageDocument возвращал `b` вместо `c` в части перестановок.

Общий владелец ContentFieldVersion сохраняет неизменные авторские контексты и
значения конкурентного фронта. Причинное отсечение предшествует человеческому
приоритету. Обычная последовательная правка остаётся компактной. Удаление
владеет существованием, а не переписывает исходник; производный порядок не
приписывается исходному автору. Адресная доставка документа больше не сливает
повторно поля, уже обработанные вместе с их значением. Значение конфликта
подчиняется прежней границе размера программы, не лимиту коротких часов.
Протокол связи 13 исключает прежнего peer до обмена; данные, идентичности и
ключи не меняются. Оба приложения потребуют совместимого обновления.

Итоговые неизменные исходники:
- `.build/slice3-accepted-core.log`: **217 Core + 4 archive PASS**, 130.984 с
  для Core. Перестановки и скобки A/B/C, повтор, холодное чтение, исходник
  страницы/документа и рамка SpatialElement, две SQLite и настоящие manifests,
  поздняя человеческая правка с отменой собственного оформления, удаление,
  два порядка actor tie, доставка конфликтных исходников по 100 000 символов.
  Профиль также включил существующие адресные/масштабные проверки затронутых
  часов, порядков, публикаций, undo и документов; это не полный verify.
- `.build/slice3-accepted-native/verification.json`: **16/16 PASS**, 0 skips,
  0 runtime warnings; source
  `2af53c9f0630a90cccd0d6b3a7496780582c65aaf787a876cc09c5058573fd7f`.
  Сохранность агентского содержания и чернил при resize, старый lift/Pencil,
  адресная публикация геометрии, отбор совместимого peer и реальный TLS loopback.

Промежуточные отрицательные прогоны сохранены. Они обнаружили синтетический
порядок из source-only пакета, потерю удержанного payload при повторном join
и недопустимое повторное авторство порядка после concurrent adoption; эти
пути исправлены, проверки не ослаблены. `.build/slice3-native/` отклонён из-за
ошибочного имени тестового класса; итоговый маршрут выше исполнился полностью.

Это Core и Debug Simulator, не физическая пара, замер FPS или оптимальная
задержка всего приложения. Потерянные до исправления исторические значения
не восстанавливаются. Рабочие приложения не устанавливались. Срезы 4–7 открыты.

## 16 сентября — срез 2: установленный runtime не зависит от выбора тайлов

На `029afb8` воспроизведён конкретный путь исчезновения: семь видимых владельцев,
последний — уже установленная программа без статического снимка; новый сосед
с более ранним ID вытесняет её из liveOwners. `.build/slice2-before/`:
**1 тест FAIL, 2 нарушенных условия** — план снимает программу и runtimeOwners.
Это воспроизведение причины, а не утверждение о каждом прежнем эпизоде Амира.

`SceneCompositionTiles` включает реально смонтированную и всё ещё видимую
программу в защищённые физические владельцы следующей композиции. Существование
runtime больше не является решением о качестве растров. Отдельного кеша,
слоя поверх сцены или второго владельца камеры нет. Источник ищется в текущем
workset, поэтому удаление и выход из видимости не воскрешают прежний материал.

`.build/slice2-after/verification.json`: **11/11 PASS**, 0 skips/runtime warnings,
source `e8f09a67fcf4f913c44e4734cb4f30b528dea6a285e122a96b5b1604b42e85b0`.
Регрессия сохраняет одного исполнителя при добавлении соседа и затем принимает
удаление цели. Прежние проверки подтвердили уточнение неподвижной сцены после
снятия давления, экранную плотность таблицы/пустых диапазонов, десять дальних
возвратов с освобождением native backing, переход в портал без перезапуска,
принадлежность уже представленных пикселей. Настоящий UI-сценарий сохранил
первый tap, slider, значение и фокус поля после pan/pinch; второй — SVG pinch
после поворота. Оригинал `69CF35FE…png` просмотрен: поле сохраняет `7860` и курсор.

Это Debug Simulator 523B6568… / iOS27/24A434. Численный drift ≤1 физического
пикселя во время движения, FPS/CPU/GPU и физический iPad этим проходом не
подтверждены; они остаются условиями объединённой приёмки. Данных рабочего
пространства и установленной пары изменения не касались. Причинное слияние,
новая отмена жестов и первая страница книги ещё не исправлены этим срезом.

## 16 сентября — срез 1: независимые материалы и первый ввод

На исходном c65c0d7 изолированное воспроизведение `.build/slice1-before/`
дало **2 FAIL**: четвёртый liveProgram не получал допуск за 250 ms при трёх
занятых из шести WK; настоящий сценарий 2/4/8 доходил до восьми материалов,
но не находил одну из четырёх кнопок. Исходные 2/4-снимки просмотрены.

В `SceneRenderResources` liveProgram теперь относится к уже готовимому вводу,
а не одновременно к пассивной работе и будущему резерву ввода. Общие лимиты
6 WK / 2 фоновых не повышены; постоянные программы не занимают последний
временный исполнитель. Отдельная трёхпрограммная квота удалена. Чистый
статический SVG подготавливает прежний адресный raster-производитель, после
чего остаётся нативное изображение без живого WK. HTML-контролы, ссылки,
анимация и непроверенная разметка остаются живыми. Конечное ожидание допуска
даёт локальный отказ/повтор, а не вечное обещание загрузки.

`.build/slice1-after-v2/verification.json`: **53/53 PASS** (49 native + 4 UI),
0 skips/runtime warnings, source `eb1bde32429bf1e3c496676c7bcbfdae9772a4416e9b00b743795de347eee517`.
Отдельно `.build/slice1-portal/verification.json`: **1/1 PASS** прежнего
перехода в портал и сохранения запущенных runtime. Первый `slice1-after/`
остановлен компиляцией: два тестовых обращения к удалённой квоте заменены
проверкой фактического общего допуска, старый API не возвращён.

Simulator 523B6568… / iPad Air 11-inch M4 / iOS27/24A434, Debug.
2/4/8 материалов проверены настоящими нажатиями, каждый счётчик становится
ровно 1, затем процесс завершается и холодный процесс читает сохранённое 1.
На восьми материалах одновременно видны четыре работающие кнопки, два SVG,
текст и отдельно ожидающий медленный источник; оригинал `C999F9CE…png`
просмотрен. Удержание/удаление SVG, pan с первого контакта, slider и pinch
после поворота также прошли; `FF5784B1…png` показывает нативный SVG после
подъёма и независимого соседа. StaticSVG-тест дождался **0 удерживаемых WK**
после готовности растра, проверил очередь и прежний byte budget.

Это устранение конкретного блокирования, не доказательство p95 ≤300 ms или
первого пикселя ≤100 ms: записанные UI-времена 1.09/2.18/4.35 s включают
последовательные секундные AX-ожидания и не являются измерением рендера.
Новый источник от агента, системные CPU/GPU/память, Release и физическая
приёмка остаются в последующих совместных проверках. Рабочий iPad, Mac,
их данные и доверие не менялись. Срезы 2–7 этим проходом не закрыты.

## 15 сентября — удержание и удаление web-материала, включая картинку-ссылку

Новый отзыв Амира после `ce3a2af` проверен на отдельном Simulator
`CBDE7503…` / iOS27/24A434. До изменения приложения пассивный SVG перемещался
двумя удержаниями и фактически удалялся, а удержание картинки-ссылки двигало
камеру вместо материала и включало выделение WebKit. Исходные снимки просмотрены;
`.build/material-lift-delete-before/`: **1 UI PASS / 1 UI FAIL**.

`NotebookSelectionGesture` больше не отвергает весь контакт `.webLink`.
Короткий tap остаётся нативной ссылке; удержание передаётся существующему
владельцу подъёма и записи положения. Первая поправка уже перемещала и удаляла
материал, но снимок `…-v1-artifacts/FD79EA4C…png` выявил одновременно открытое
меню выделения текста. Такой результат не принят. Подъём теперь исключает
конкурирующие UIKit-распознаватели только внутри принятого web-владельца;
общий безусловный запрет такого исключения заменён адресным правилом.
Нативные поля, соседние программы, камера и Pencil не блокируются этим правилом.
Нового владельца, replay ввода или второго пути удаления нет.

Окончательная узкая квитанция `.build/material-lift-delete-v3/verification.json`:
**5 native + 2 UI PASS**, 0 skips/warnings, source `1b82c3f9…`.
Первое удержание картинки-ссылки перемещает только её на (+45,+30); меню
WebKit отсутствует, новый короткий tap выполняет ровно один переход, корзина
удаляет установленный материал, сосед остаётся на месте с Count0.
Отдельный настоящий маршрут сохранил первый tap → Count1, slider и ввод
в прежнее поле после pan/pinch без повторного фокусирования. Оригиналы
`…-v3-artifacts/BFE62F4B…png`, `ED18544D…png` и `F4D71C5D…png` просмотрены:
подъём без меню, фактическое удаление и сохранённый курсор соответственно.

На промежуточном `…-v2/` прошли 16 проверок: в том числе удержание фона
программы после ввода, её удаление с сохранением соседа, пассивный SVG и pan
по картинке-ссылке. Это не отдельный полный допуск и не проверка физического
ввода. Рабочие материалы не перемещались и не удалялись, Mac и частная пара
не менялись. Новая поправка пока не установлена на iPad; физический маршрут
и общие условия GUI-200/202 остаются открытыми.

## 15 сентября — смешанный web-ввод установлен на рабочий iPad

По отдельному согласию Амира «Да, установить исправление» выполнено одно
обновление iPad на месте из чистого `ce3a2af`: source `a5675637…`,
подписанный Release bundle `e456c669…`, UUID `EBA2DD41-F468-3BAD-B354-CB9B75013EB9`.
Основание — узкая проверка ниже, **не** полный допуск выпуска. Версия по-прежнему
0.3.62/65; новый исходник подтверждается SHA, а не номером.

CoreDevice подтвердил установку на `9CF2C22D…` / iOS27/24A435, bundle URL
`730A3B38…/Notebook.app` и запуск PID1216. Data-container перенесён системой
`E7875677…` → `FF110B97…`; это учтено без повторной установки. Перед запуском
совпали digest активации `538ec5ff…`, весь перечень и метаданные файлов корня,
включая SQLite 41 181 184 bytes, WAL и SHM. Это не побайтовый аудит содержимого.
Удаления, восстановления архивов, сброса данных и нового сопряжения не было.
Mac-помощник не заменялся и не перезапускался; SHA бинарника `0cc59c27…`
и активация остались прежними. Частная пара не менялась.

MCP установленного Mac подтвердил `ready` / `connected` и текущую доску
`7E7A0000…0003`. Оригинал `screen-connected.png` (1668×2388) просмотрен:
«Тихое утро», КБЖУ и соседнее содержание снова показаны. Первый снимок
`screen-running.png` запечатлел пустую фазу запуска, не готовую сцену.
Квитанции — `.build/physical-ipad-ce3a2af-20260915-build/build.json` и
`.build/physical-ipad-ce3a2af-20260915-install/installation.json`; рядом
команды, сравнение данных и снимки. Физические pan/pinch/ввод этой установкой
не проверены; GUI-200/202 и полный выпуск остаются открытыми. Provisioning
действителен до **16 сентября 17:15:33 МСК**.

## 15 сентября — камера на смешанных web-материалах и сохранение фокуса

После установки `9e03c35` Амир воспроизвёл неподвижную камеру на «Тихом утре»
и «Порциях и КБЖУ». Read-only MCP подтвердил реальные исходники
`pinterest-quiet-morning` и `nutrition-portions-column`: подгонку размера,
ссылки на изображениях и динамические поля. Прежний признак «есть JavaScript
или контрол» отдавал WebKit весь прямоугольник. Сокращённая изолированная
фикстура воспроизвела отказ: pan (+45,+35) дал нулевой сдвиг обеих WK-рамок
(`.build/mixed-web-pan-before/`, исходное изображение просмотрено).

Этот путь удалён. Координатор принимает версионные области фактического DOM-ввода;
нативная проекция определяет владельца первого контакта без AX. Фон отдаётся
камере, поле/обработчик сохраняет ввод, ссылка сохраняет tap, но не блокирует
pan/pinch. Динамическое добавление/удаление обработчиков, `onclick`, once,
AbortSignal и движение полей обновляют карту без перезапуска runtime или опроса.
Настоящий жест дополнительно выявил потерю фокуса соседнего поля: фон попадал
в WKContentView до распознавания pan. Теперь такой фон получает сам viewport;
контролы и ссылки сохраняют исходную нативную доставку, без replay.

Окончательная узкая квитанция `.build/mixed-web-contact-accepted/verification.json`:
**2 native + 2 UI PASS**, 0 skips/warnings, source `a5675637…`,
Simulator `CBDE7503…` / iOS27/24A434 / Xcode27A266a. Настоящие pan по заголовкам
и картинке-ссылке дали (+45,+35), (−35,−25), (+30,+20) обеим рамкам при Count0.
Кнопка с первого tap дала Count1, slider изменился без движения камеры. После
ввода `7`, pan и pinch приложение (не повторно фокусируемое поле) приняло `8`
и `9` в прежнюю позицию. Снимок `175EF033…png` показывает фокус/курсор и `7860`
после pan; `F32F96AA…png` — обе карточки после свайпа по ссылке. Оригиналы
просмотрены, находятся в соседнем `…-artifacts`. Использовалась аппаратная
клавиатура Simulator; это не проверка всей экранной клавиатуры или IME.

На том же коде приложения ранее прошли 7 проверок владения контактом, 3 UI
пассивного SVG (hold, pan, pinch/rotation) и Mac-проверка сохранения runtime,
фокуса и незаписанного ввода (`…contact-final/`, `…contact-verified/`). Эти
проходы целиком не PASS: новые тестовые шаги возвращали неподдерживаемую JS-функцию
из `onclick=handler`, затем передавали геометрию неправильного Swift-типа.
Диагностический прогон различил причины; исправлены только тесты, приложение
по ним не менялось. Финальная квитанция выше относится к завершённому набору.

Пользовательское содержание и частная связанная пара не менялись. Амир отдельно
разрешил доставить эту поправку на рабочий iPad после узкой проверки, без замены
Mac и нового доверия. Это не общий допуск GUI-202: физический ввод, stale AX,
точность ≤1px, первый пиксель ≤100ms и остальные системные условия остаются
отдельными открытыми проверками.

## 15 сентября — явно запрошенное обновление физического iPad с SVG-правкой

После отдельного поручения Амира «установи» выполнено **только обновление iPad
на месте**, не допуск общего выпуска и не обновление Mac-помощника. Из чистого
`9e03c35` собран подписанный Release: source `808d87eb…`, bundle `13d0544d…`,
Mach-O UUID `BD9BBAB6-611A-3899-98AC-23A0B36198A6`. Источник совпадает с последней
узкой квитанцией SVG; это не полная приёмка. Номер остался 0.3.62/65, поэтому
происхождение определяется SHA и UUID, а не номером версии. Исправление `37bc089`
теперь входит в установленный бинарник.

CoreDevice подтвердил единственную установку `com.amirtlinov.notebook.preview`
на физический iPad `9CF2C22D…` (iOS27/24A435), новый bundle URL `3F3D43CF…`
и запуск PID1175. При обновлении система переместила data-container
`2A893F94…` → `E7875677…`: исходный отказ строгой проверки неизменного URL сохранён
как `initial-readback-refusal.json`, а не скрыт повторной установкой. Затем
сверены неизменный digest активации `538ec5ff…`, перечень файлов и метаданные
основной SQLite (41 136 128 bytes) / WAL. Изменились только метаданные SHM.
Это проверка сохранности по указанным наблюдениям, не побайтовое чтение всех
пользовательских данных. Удаления, сброса, восстановления архивов и нового
разрешения доверия не было.

Оригинал `screen-settled.png` (1668×2388) просмотрен: после запуска снова показана
прежняя доска с содержимым. Ранний `screen-running.png` относится к переходу
запуска, а не к готовому изображению. Рабочий Mac-помощник был выключен;
запущена **существующая установленная** `/Users/amir/Applications/Notebook.app`
(PID39739). Его binary SHA `0cc59c27…`, CDHash `b57d0103…` и активация не менялись.
После первоначальных `ipc_unavailable` / `read_conflict` чтение MCP вернуло
`ready`, связь `connected` и текущую физическую доску. Частная пара не менялась.

Квитанции: `.build/physical-ipad-9e03c35-20260915-build/build.json` и
`.build/physical-ipad-9e03c35-20260915-install/installation.json`, рядом журнал
команд, readback и изображения. Provisioning действителен до **16 сентября
17:15:33 МСК**. Удержание/pinch на установленном iPad ещё не приняты настоящими
физическими жестами; прежние Simulator PASS этого не заменяют. GUI-200/202,
системные измерения и общий допуск выпуска остаются открытыми.

## 15 сентября — SVG: удержание и pinch, отдельно от установленной версии

После сообщения Амира проверена граница версии: физический iPad всё ещё содержит
тот же bundle URL `1C181D82…/Notebook.app`, что квитанция установки `af9fbde`
(source `92b53f82…`, UUID `AB15B20B…`, 0.3.62/65). В этом исходнике
`PhysicalWebViewport` удерживает палец даже у пассивного SVG. Исправление
`37bc089` есть в текущей ветке, но в эту установку **не входило**. Сверено не
только совпадение номера версии: `.build/svg-hold-pinch-device-provenance/`.

Добавлены две настоящие UI-регрессии в `DrawingResponsivenessTests`:
первое удержание 0,45s перемещает SVG на (+80,+50), повторное — на (−40,−30),
при неизменных размере, камере, соседнем контроле и Count0; pinch на самом SVG
увеличивает внешнюю нативную WK-рамку до и после поворота, не выбирая рисунок.
Прежний pan/control-тест также прошёл: (+90,+60), (−50,−40), один эффект кнопки
и независимый slider. Нового пути ввода или изменения приложения не понадобилось.

`.build/svg-hold-pinch-v3/verification.json`: **3 UI PASS**, 0 skips/warnings,
source `6ec26401…`, Simulator `CBDE7503…`, iOS27/24A434, Xcode27A266a.
Два предыдущих отказа (`…reproduction-v1`, `…v2`) сохранены как ошибки проверки:
она искала WK соседа, законно ушедшего за экран после увеличения/поворота.
Корректирующих жестов по старому AX не выполнялось; условие присутствия невидимого
runtime удалено из pinch-теста, независимый ввод проверяется отдельным сценарием.

Просмотр исходных изображений обнаружил ещё ошибку снимка: `app.screenshot()`
после поворота использовал прежнюю портретную обрезку. Только pinch-наблюдатель
переведён на `XCUIScreen.main.screenshot()`; повторена только эта проверка:
`.build/svg-hold-pinch-screen-v4/verification.json`, **1 UI PASS**, 0 skips/warnings,
source `808d87eb…`. Полный landscape-снимок `7803EAE3…png` и портретные
изображения удержания/увеличения просмотрены. Артефакты — соседние каталоги
`…-artifacts`. Бинарник приложения `5fd2e841…`, собранный в17:28UTC, не менялся:
использована существующая инкрементальная Debug-сборка, компилировался UI runner.

Это проверка **пассивного** SVG в Simulator, не произвольной программы с кодом,
исправления stale AX, точности ≤1px, чёткости или физического ввода. Масштабирование
здесь означает pinch, не двойной tap. Частная связанная пара и рабочий iPad не
обновлялись; доставка исправления и физическая проверка остаются открытыми до
принятого допуска выпуска. GUI-200 целиком не закрыта.

## 15 сентября — штатная трасса первого касания без прогрева поиском

После отдельного согласия Амира на короткий **host-wide** Time Profiler получены
две штатные трассы Xcode27A266a: 46,810s и28,251s, суммарно75,061s при разрешённых
двух минутах. Захват завершён, файлы остаются локально. Начало подтверждено
документированным Darwin notification самого xctrace, а не его строкой лога.
Обе трассы относятся к неизменному частному приложению `bbd940e0…`, bundle
`e6474b82…`, Simulator523B6568…/24A434; **не** к новому исправлению истории.
Один номер версии или старое `sourceRevision` сохранённого manifest не используются
вместо SHA установленного bundle и происхождения сборки.

Первый диагностический проход `47604522…` сначала открывал поиск, затем выполнил
62→72 ровно десятью настоящими касаниями: **1 UI PASS**, без skips/warnings.
Но поиск уже использовал цепочку first responder: его19ms `pointerup→click`
не годятся для замены исходного первого касания. Поиск удалён из этого короткого
диагностического теста; приложение не менялось. Новый runner собран только
`ui-build`, test SHA `10029d83…`; стенд уже оставлен на доске с контролом.

Прямой проход после запуска `c9657d02…` — **1 UI PASS**, 72→82 десятью касаниями,
без поискового ввода/скрытого активирующего тапа, skips и runtime warnings.
Первый контакт `cecc4799… / 0` имеет47ms между JS pointerup и click; последующие
контакты — около1ms. От нативной квитанции отпускания до квитанции program_commit
прошло51,422ms, до native_projection —117,323ms. Время самого UIEvent и лаг его
нативного наблюдения сохранены отдельно; это **не** замена release→видимые пиксели.
Журнал не содержит перезапуска runtime после начала касаний. Исходные снимки
`82F57F92…png` (73) и `62082903…png` (82) просмотрены: значение меняется,
slider85 и прежний текст остаются на месте.

Системные стеки различили фазу задержки. На main thread PID31598 после отпускания
наблюдаются `_singleTapRecognized` → `becomeFirstResponder`: примерно1,7–13,7ms
занимают samples FocusBridge, далее видны холодные UITextEffectsWindow,
TextInputUILibrary и UISystemInputAssistant до примерно45,7ms. Click-handler
укладывается в дискретность JS-измерения1ms. В проходе после поиска холодная
инициализация input assistant в этом интервале отсутствовала. Это установленная
системная работа на пути первого контакта, не доказательство безопасного способа
убрать её в приложении. Не добавлены скрытый focus, отказ клавиатуры, перехват
DOM-ввода или очередная перестройка композиции. У исходного102,78–120,78ms нет
синхронной CPU-трассы: новая запись объясняет воспроизведённую фазу, а не задним
числом измеряет старый проход.

Артефакты: `.build/completion-system-contact-profile-v1/` и `…-v2/`, включая
`analysis.json`, исходные journals, CPU export и выборку `first-contact-cpu.json`.
TOC подтверждает Hangs100ms и реальные CPU samples. Однако сохранено предупреждение
об одной таблице без известного input source; таблица potential-hangs содержит
7 интервалов Notebook в проходе с поиском и3 при прямом запуске. Нет утверждения
о нуле задержек или полной системной приёмке. CPU-стек не измеряет показанный кадр,
GPU, frame-drop, память либо точность ≤1px. Исходный pixel FAIL остаётся открытым.

Сам драйвер исправлен: `--all-processes` больше не запускается неявно под видом
изолированного Simulator. Широкий режим требует `--allow-host-processes`, объявляет
Mac в квитанции и использует существующий `TraceStartNotification`; прежнее
ожидание текстового подтверждения xctrace удалено. Без согласия Time Profiler
сохраняет прежний per-launch/PID handshake. **79 driver PASS +18 trace-owner PASS**;
отказ без согласия происходит до обращения к стенду или запуска записи.
Полная приёмка и обновление пары не выполнялись; GUI-200/202 остаются открытыми.

## 15 сентября — устранён повторный расчёт источника в истории действий

Причина найдена не новым профилировщиком, а системным отчётом уже установленного
физического `af9fbde`: `Notebook.cpu_resource-2026-09-15-201120.ips` записал
90s CPU за 108s (83%), footprint208,47→215,17MiB, max282,33MiB. Это наблюдение
17:09:31–17:11:19UTC, не метрика окончательного среза. Все адреса приложения
символицированы штатным `atos` с dSYM точно совпавшего UUID `AB15B20B…`.
Из 48 samples 34 содержат `refreshCollaborationDetails`, 26 — подготовку
`CollaborationReadSnapshot`, 19 — `resultReferences` → `referenceRevision` →
полный Merkle-отпечаток. Отчёт также отмечает 13 потерянных samples.

Владелец снимка уже разделял ревизии контекстных ссылок, но результаты каждого
исторического действия заново вычисляли ту же ревизию доски. Теперь этот же
локальный словарь обслуживает и результаты, включая fallback удалённого элемента.
Он существует только во время подготовки одного неизменного снимка; новый
снимок заново читает изменённый источник. Старое прямое вычисление для каждого
результата удалено. Публичный API, writer, идентификаторы результатов, хранилище
и бюджеты не менялись; постоянного кэша и нового владельца нет.

Фиксированная серия на Mac arm64 Debug: 32 элемента, 64 исторических действия,
128 отдельных результатов, 10 подготовок включая первую. До исправления:
2085,83–2312,44ms, median2095,99ms; после: 34,33–34,99ms, median34,85ms.
Это ускорение конкретной подготовки, **не** доказательство release→pixels≤100ms
или нового физического CPU%. Регрессия сохраняет все 128 ID, текущую ревизию,
распознавание человеческой правки и отмену. **7 Core PASS**, включая компактное
чтение без загрузки 14MiB receipt и защиту от устаревшего описания действия.
Две ранние ошибки тестового fixture (компиляция и отсутствующий worldOrigin)
сохранены; сравниваются только завершённые baseline-v3 и shared-revision-v1.

Источник `def382b4…`: **4 native/UI PASS**, 0 skips/runtime warnings, в
`.build/completion-history-revision-sharing-v1/verification.json`. Настоящий UI
пять раз открыл и закрыл историю и использовал её действия; нативные проверки
подтвердили компактное чтение и человеческую доработку. Оригинал `93990ECB…png`
после закрытия истории просмотрен: чернила сохранены, панель доступна.
Xcode27A266a, отдельный Simulator `CBDE7503…`, iOS27/24A434.
Логи, оригинальный CPU report, символика и `history-comparison.json` находятся
в `.build/completion-measurement-diagnosis-20260915/`; изображения отдельно в
`.build/completion-history-revision-sharing-v1-artifacts/`.

## 15 сентября — различены отказы штатной трассы, выпуск не допущен

Неполная физическая трасса 13:23:49UTC остановилась через4,276s не из-за
доказанного дефекта Notebook. Системные crash reports Notebook PID838 и
SpringBoard PID38 совпадают по `SIGBUS/KERN_MEMORY_ERROR`: backing vnode был
принудительно размонтирован. Штатный host log показывает, что xctrace в этот
момент заменил DDI27A5237l на27A266a: unmount13:23:51, mount13:23:52,
оба crash13:23:53. После подтверждения нового совместимого DDI и нового PID1108
выполнен один объяснимый повтор: он отказал **до записи**, `Cannot find process`.
Это не PASS и не достаточная CPU/GPU/frame/memory трасса.

Отдельно разрешённая короткая проба всех процессов **только частного Simulator**
завершилась через10,616s, но экспортированный TOC включил и процессы Mac,
несмотря на явный `--device 523B6568…`. На инвентаризации анализ остановлен;
samples/стеки этой трассы не использовались. Созданные raw trace и TOC удалены
из-за превышения разрешённой области, команда, лог и квитанция
`simulator-all-processes-scope.json` сохранены в том же каталоге диагностики.
Этот all-processes маршрут повторять нельзя в предположении изоляции Simulator.

GUI-200 остаётся открыт для stale WebKit AX, первого отклика102,78–120,78ms,
геометрической точности и установленной чёткости. GUI-202 требует системных
измерений, окончательного единого среза, десяти повторов и30мин настоящей
совместной работы, затем физической приёмки. Эта задача не обновляла ни
частную, ни рабочую пару в ходе данной диагностики; предыдущая отдельно
разрешённая физическая установка `af9fbde` не стала допуском выпуска.

## 15 сентября — контакт компактного чата переживает исчезновение ответа

Причина пропавшего нажатия различена на прежнем private app `44d12c2a…`:
реальный короткий ответ Codex исчез во время четырёхсекундного контакта.
В `b685d5ac…` кнопка сместилась с y968 до1032pt; контакт (655,5;992) не открыл
чат. Изображения и AX совпадают в этом перемещении. Контрольный такой же
контакт без изменения превью, `faf51df6…`, открыл чат: **1 PASS**, 14,412s.
Это установленный дефект геометрии панели, а не гипотеза о WebKit AX.
Оригиналы и координаты: `.build/completion-compact-contact-v5-artifacts/`.

Сохранённый anchor существующего `NotebookChatWindowLayout` теперь принадлежит
измеренной панели управления. Карточки размещаются со свободной стороны,
не меняя положение кнопок. Старый общий VStack и анимации всей рамки по
ответам удалены; stateless SwiftUI Layout сохраняет тот же control subtree.
Жест и сохранение положения по-прежнему принадлежат окну. В приложении нет нового
input owner, отложенного воспроизведения контакта, таймера или изменения хранилища.

Узкая native-проверка: 8 геометрических тестов и 2 настоящих жестовых сценария
диктовки прошли в `completion-compact-anchor-native-v6`; сам v6 остаётся FAIL
из-за наблюдателя штриха. Исправленный `…native-v7/verification.json` —
**1 PASS**, 30,741s: запись, закрытие превью без смещения кнопок, drag панели,
обычный tap, прежний черновик, landscape→portrait и голосовое меню. Снимки
до/после поворота просмотрены. App-код v5/v6/v7 одинаковый, менялся только
наблюдатель; skips и runtime warnings отсутствуют.

Неудачные проверки не скрыты: v4/v5 читали ограниченный journal как счётчик
всех видимых обложек, хотя на изображении штрих сохранялся. V6 направил direct
контакт DEBUG-стенда на свободную доску, где его получили и перо, и pan.
V7 пишет на конкретной обложке, входящей в наблюдаемую адресную выборку,
без изменения камеры/чернил приложения. Диктовочный fixture отдельно согласует
свою synthetic authorization с уже подставленным authorize callback; разрешения
системного микрофона не менялись. Ранние keyboard-ошибки private-наблюдателя
останавливались до Send; ввод исправлен штатной клавиатурой, не записью в БД.

Собран development Release `bbd940e0…`, iPad bundle `e6474b82…`; прежний `upgrade`
обновил **только частную пару** с равенством data inventories, прежними workspace,
идентичностями и доверием. Run `d3f8489d…` продолжается в
`.build/completion-compact-anchor-release/runs/`, helper PID21443.
Тот же реальный контакт через истечение нового ответа — **1 PASS**, 41,841s
(`62afece2…`). Дополнительная проверка установки самого ответа, а не только
появления пустой панели, собрана исключительно `ui-build` (`…anchor-ui-v1`,
test SHA `a85a9923…`): **1 PASS**, 40,840s (`fb7ff697…`), 0 skips/warnings.
При нажатии (655,5;1056) превью истекло, чат открылся, полный ответ установлен,
черновик и count102 сохранились. App bundle и контейнер UI-only проходом не менялись.
Оригинал `B581CFD7…png` просмотрен; координаты и независимый ответ владельца
Codex находятся в `.build/completion-compact-anchor-contact-v2-artifacts/`.
Turn `01a0a601…` завершён: один запрос, один ответ, ни одного вызова инструмента.
Материал, Save, экспорт и ранее принятые действия не выполнялись повторно.

Закрыт именно этот дефект контакта GUI-200. Это не измерение ≤100ms или ≤1px,
не 30 минут и не итоговый Release. Stale WebKit AX, первый отклик102,78–120,78ms
и обязательные системные измерения остаются открыты; отказавшие измерители
без изменения объясняющего условия не перезапускались. Эта задача рабочую пару
не обновляла. Отдельная установка физического `af9fbde` по поручению Амира
зафиксирована в GUI-202 и не является допуском общего выпуска.

## 15 сентября — интеграция готового исправления ввода пассивного SVG

В основную ветку после `af9fbde` перенесён существующий `008bf9b` из
`codex/svg-camera-input`, без новой реализации. Установленный пассивный WebKit
больше не удерживает движение пальца только из-за наличия runtime; прежний
повторный запрет камеры по рамке элемента удалён. Программы с кодом,
обработчиками, ссылками и контролами сохраняют свой ввод.

На объединённом источнике `b2f83f93…` выполнены **4 PASS**, 0 skips и runtime
warnings: классификация 12 настоящих загрузок WebKit, нативная маршрутизация,
сохранение принятого состояния при смене плотности и настоящий UI-жест.
Первый drag по SVG перенёс обе нативные поверхности на (+90,+60), обратный —
на (−50,−40), не изменив их размеры. Кнопка дала ровно Count1, slider изменил
своё значение без pan, движения камеры не активировали соседа. Все три
оригинальных снимка просмотрены; расхождения с записанным движением не видно.

Квитанция: `.build/completion-svg-camera-integrated-v1/verification.json`,
оригиналы: `.build/completion-svg-camera-integrated-artifacts/`.
Xcode 27A266a, iPad Air M4 Simulator 24A434, отдельный `CBDE7503…`.
Первый запуск проверки был отклонён из-за чужой сборки; после её завершения
запущен один runner. Частная связанная пара и рабочие приложения этим срезом
не обновлялись. Это не PASS устаревшей AX-геометрии, точности ≤1px, задержки
первого ответа или системных метрик; условия выпуска GUI-200/202 остаются.

## 15 сентября — перенос длинного адреса в настоящем PDF

Из просмотренного живого export job `c14fe724…` выделен конкретный дефект:
`\texttt` печатал ID интерактивного блока одной неделимой строкой за пределами
бумаги. `MCP/src/document-tex.ts` теперь разрешает перенос между экранированными
символами адреса. Все символы, размер бумаги и шрифта сохранены; идентификатор,
исходник документа, API и данные не меняются. Прежняя неделимая строка удалена
и ресурс действующего markup XPC пересобран из того же владельца.

**14 TypeScript PASS**, `npm run check` PASS. Узкий настоящий Mac-сценарий
`testActualPDFJobOutlivesItsUserRunAndPublishesThroughTheNativeOwner` —
**1 PASS**, 3,070s, без skips/runtime warnings. Это SDK → адресная запись export
job → ограниченный markup XPC → подписанный TeX child → публикация реального PDF;
не подставная квитанция. Регрессия проверяет полный ID после переноса и реальные
bounds каждого символа в пределах страницы. Прежние проверки формул, трёх
ссылок, SVG-текста/изображения и независимого запуска во время публикации прошли.

Выбранная квитанция — `.build/completion-export-wrapped-id-v1/verification.json`.
Экспортированный оригинал `105253AC…pdf` (54324байт, SHA `b792daa7…`) и его
просмотр находятся отдельно в `.build/completion-export-wrapped-id-artifacts/`.
Изображение просмотрено: адрес полностью внутри рамки, формулы и SVG сохранены.
Это исправление и узкая приёмка владельца печати, **не** новая полная приёмка
частной/рабочей пары; установленный private helper по-прежнему старого app-среза.
Открытые GUI-200 и обязательные системные условия GUI-202 не сняты.

## 15 сентября — связный Save, экспорт, агент, отмена и восстановление

На том же private app `44d12c2a… / f8822813…` после исправления перекрытия
продолжен разговор `01a0a555…`, документ `D269DC29…`. Save установил
`Human source 1d13a2ed…`; публичный export run `45a3f95d…` создал ровно один
job `c14fe724…` для content revision `1@a4a8e3d6…`. Проверка файлов через
публичный `19a91aa5…`: PDF 52375байт / SHA `1644f3d3…`, формула осталась TeX,
SVG asset имеет собственный SHA, hyperlink ведёт к настоящему destination.
PDF просмотрен: длинный ID интерактивного блока **обрезан краем страницы**.
Поэтому это не окончательный PASS экспорта; дефект локализован в `document-tex`.

Прежний agent effect `65377810… / 62FA86FD…` продолжил человеческое1 до101,
настоящая кнопка дала102, CAS `038a5460…` получил `revision_conflict/notSaved`.
Undo `d3d6c9a1…` сохранил человеческую версию (`preservedCount1`), исходник
не менялся. Независимые resume исходных четырёх runs подтвердили по одному
эффекту, без повторного выполнения. Recovery `cd5fe86e…` — **1 PASS**, 37,029s;
настоящий Stop прервал turn `01a0a580…` до первой активности. Это подтверждено
владельцем Codex как `interrupted`, а не выдуманной группой «1 действие» в чате.

Helper остановлен по точному PID59691 и пути частной сборки; offline UI
`aec6695e…` — **1 PASS**, 32,924s: один outgoing UUID и отдельный черновик
пережили перезапуск iPad. Тот же binary/manifest запущен как PID4505 без смены
данных и доверия. Reconnect `461d0a7c…` — **1 PASS**, 18,822s: один настоящий
ответ, пустой outbox, прежний черновик, тот же conversation и видимые102 после
повторного открытия. Оригинал `3B104393…png` просмотрен. Codex подтверждает
один соответствующий user turn `01a0a582…` и один ответ без вызовов инструментов.
Артефакты находятся в `.build/completion-post-reboot-20260915/joint-*` и
private run `d3f8489d…` внутри `.build/completion-opened-paper-order-release/runs/`.

Отказы наблюдателей не удалены: `99d19b99…` оборван внешним лимитом240s при
разрешённых XCTest600s; новый recovery внесён в существующий точный список660s
(75 driver tests PASS). `b9c09115…` требовал «Остановлено · 1 действие», хотя
Stop пришёл до первого действия; ложное ожидание удалено, статус проверен у
Codex. `c062cc95…` не открыл панель первым контактом во время появления ответа;
видео показывает перемещающуюся компактную панель. После завершения ответа
панель открывается. Координаты контакта в том проходе не записаны: причина
потери касания **не установлена**, приложение по этой гипотезе не менялось.

Immutable snapshot заменил индексное чтение меняющихся AX children. Изменения
проверок собраны только через `ui-build`; приложение не пересобиралось.
Неудачные исходные прогоны остаются FAIL. Это продолжение реального материала,
но не единый окончательный прогон: камера/Pencil/AX, первый отклик и системные
измерения открыты; 30мин совместной работы не подменены ожиданием агента.
Рабочая пара не обновлялась, выпуск не допущен.

## 15 сентября — перекрытие открытого документа в настоящем разговоре

Частный маршрут `b60a6565…` создал через связанный Notebook–Codex разговор
`01a0a555…` документ `D269DC29…`. Он остановился перед человеческой правкой:
первый контакт не изменил count0. Просмотр исходного `3FDA96F7…png` **до**
контакта и последующего `created-first-tap-current.png` показал не кнопку,
а перекрывающую старую обложку `E13F835B…`; контакт выбрал именно её.
Повторных корректирующих жестов не было. Публичные чтения `524d4e19…` и
`fe5cd93b…` подтвердили центры2800/400 и2700/400, одинаковый zIndex1,
UUID-порядок обложек и неизменённое начальное состояние нового документа.
Это отдельный дефект открытой композиции, не доказательство потери WebKit-ввода.

Кандидат заменяет порядок открытой бумаги в существующей
`WorkspaceSceneProjection`: над закрытыми обложками и статическими диапазонами,
под ручным lift. Native surface и attention используют этот же временный ранг.
Ни placements, ни стек, ни камера не переписываются; после закрытия остаётся
прежний причинный порядок. Новый renderer, coordinator или AX layout-кандидат
не добавлены.

В `.build/completion-opened-paper-order-v4/ipad.xcresult` новая mounted-регрессия
прошла за2,693s: реально нарисованный текст, UIKit hit-test в document WebKit,
выбор того же документа для attention, ранг native pose и неизменные сохранённые
placements после закрытия. Исходный снимок `D01E7044…png` предыдущего прохода
тоже просмотрен. Весь v4 остаётся **2 PASS / 1 FAIL**: соседний lift/Pencil-тест
отказал при удалении собственного временного `runtime/input-frames.json`
(Cocoa513/EPERM), не на проверке попадания. Две ранние попытки нового теста
ошиблись в обходе UIKit-владельцев; наблюдение заменено адресным чтением
существующего surface registry. В v1 сборка не стартовала без Metal Toolchain
нового Xcode RC; штатный компонент27A266a установлен, защиты среды не менялись.
Частная development-сборка `44d12c2a…`, iPad bundle `f8822813…`, установлена
прежним `upgrade` с побайтовым равенством данных до/после, тем же workspace,
идентичностями и доверием. Рабочая пара не затронута. UI-only runner `78a1fd54…`
на этом приложении дал **ровно0→1 первым касанием** в тот же созданный документ,
затем настоящую правку с клавиатуры и Save. Исходник перед вводом сохранён
целиком: Cmd+Down переносит курсор за SVG data URI, после ввода проверяется
точное равенство прежнему тексту плюс маркер. Оригиналы `7A87A972…png` и
`9598F00E…png` показывают кнопку/count1 и установленный сохранённый текст;
последний просмотрен вместе с формулой, SVG и ссылкой. Публичное чтение
`3a79c0d1…` подтвердило content/state revisions1@a4a8e3d6… и count1.
Перекрытие открытой бумаги исправлено; AX после движения камеры этим не принят.

Весь `78a1fd54…` остаётся **FAIL**: после настоящего Send запроса экспорта
поток чата заменил AX children между индексными чтениями; индекс14 уже
отсутствовал. Наблюдатель переведён на один immutable snapshot, приложение
не пересобиралось. Продолжение читает тот же отправленный запрос, не повторяет
Save/Send/экспорт. Полный связный маршрут и общая квитанция выпуска ещё не приняты.

Перед созданием этого разговора guard остановил попытку `2743bb51…`, сохранив
прежний неотправленный контрольный черновик. С разрешения Амира ровно этот
синтетический текст заменён настоящими keyboard actions (`fc8cf2ae…`, 1 PASS),
без Send, подстановки данных или ослабления защиты произвольных черновиков.

## 15 сентября, после перезагрузки — физическое AX-расхождение и границы штатной трассы

Работа продолжена с `83a2e5a`, без изменения или установки приложения. На уже
установленном физическом `8af2a06 / c66cf36a…`, iOS27/24A435, отдельный UI runner
выполнил **один pan +430pt**. Native WK frame изменился с
−355,3317/172,3749 до74,6683/172,3749pt при прежнем размере458,8863×275,1117pt;
изображение последовало за поверхностью. Все четыре AX-рамки radio-контролов
остались прежними. Runner немедленно завершился
`StaleAccessibilityAfterNativeMovement`: **1 FAIL**, без skips/runtime warnings.
Pinch, поворот, корректирующие жесты и контакт по контролу после расхождения
не выполнялись. Оригинал `0E68CABB…png` просмотрен. Опись и точные данные:
`.build/completion-post-reboot-20260915/physical-observer/pan-receipt.json`.

Этот класс сбоя воспроизведён и на физическом устройстве, не только в Simulator.
Источники и версии сред различаются; это не сравнение идентичных сборок и не
доказательство попадания на физическом устройстве при старом AX. Причина внутри
границы WebKit, точность≤1px и физический Pencil остаются неподтверждёнными.
Новый layoutChanged, перепроекция содержимого или обход accessibility не добавлены.

После перезагрузки изменились внешние условия измерения: macOS27.0/26A428 вместо
26A5421a, доступен Xcode27.0/27A266a вместо Beta5/27A5237l. Новый штатный
Time Profiler на физическом iPad действительно записал106 CPU samples за4,276s,
но завершился из-за выхода целевого приложения раньше заказанных10s.
Это не интервал проверяемого контакта и не объяснение прежнего первого
отклика102,78–120,78ms. CLI exit0 не превращает неполную трассу в PASS.
`physical-rc-time-profiler.trace` и `system-measurement-status.json` лежат в
том же каталоге. GPU, память, frame-drop≤1% — **не измерено**.
Simulator attach по проверенному PID отказал с exit21 как в device-, так и
host-scope; GUI Instruments снова отказал с ScreenCaptureKit−3811. Эти способы
без нового объясняющего изменения среды больше не повторялись.

С разрешения Амира прежний частный Simulator523B6568… запущен без установки,
сброса данных или нового сопряжения. Возобновлены прежний Mac manifest и тот же
workspace488F89AC…; iPad bundle SHA1257a8c3… сохранён. Существующий UI observer
`65942e52…` дал **1 PASS**: выбранный разговор01a0a361… и неотправленный черновик
пережили перезагрузку. Это узкое наблюдение восстановления, не новый полный
совместный маршрут. Рабочая пара этой задачей не обновлялась; допуск выпуска
по обязательным системным измерениям по-прежнему отсутствует.

## 15 сентября — различён AX-сбой и проверено самостоятельное уточнение таблицы

Продолжение начато с чистого `06cde99`. Документный путь, API, writer, редактор,
экспорт и владельцы ресурсов не изменены. Частная установленная пара остаётся
на `07967c5`, source SHA `278c15d5…`, iPad bundle SHA `1257a8c3…`;
диагностические UI runners собирались существующим `ui-build` отдельно от app.

**Изображение / native / AX / контакт.** Первый контакт по свежему изображению,
run `842061ac…`, дал ровно59→60 при неизменном app PID19412. Но его начальный
AX уже восстановился; этот результат сам по себе не различает прежний сбой.
Публичное чтение `ff2441f9…` подтвердило сохранённое count60.

Следующий короткий опыт `a5179e97…` сделал один pan−60/+10pt и остановился:
WK126,75/415→66,75/425, изображение переместилось вместе с ним; все три дочерних
AX frame остались прежними. Whole-app snapshot, WK subtree snapshot и отдельные
запросы совпали между собой. Это не исправляется выбором другого корня AX-запроса.
Оригинал `096B4824…png` и JSON `3974CF2B…` просмотрены; pinch/rotation после
первого расхождения не выполнялись.

В различающем опыте `63af22eb…` тот же процесс снова остановлен после одного
pan, WK66,75/425→6,75/435. Из оригинального PNG `06ba808b…` выбран один контакт
(75,535pt), **не вычисленный из старых AX frames**. Runner ожидал только
проверенную точку в своём временном каталоге; состояние Notebook/квитанции туда
не подставлялись. Непосредственно перед касанием подтверждены неизменность
native frame и всё ещё прежние AX frames. Настоящий контакт дал ровно60→61;
оригинальный `FCC9A210…png` просмотрен. Публичный read `112b5e5d…` подтвердил
count61, slider85, прежний текст, stamp951. XCTest остался **FAIL/FrozenObservation
за31,579s**, не AX PASS; следующих корректирующих жестов не было. Все описи app
до/после совпали. Это локализует данный сбой в accessibility, а не в области
попадания. Конкретная причина внутри границы WebKit ещё не установлена;
новый layoutChanged, сброс кеша или новая композиция не добавлены.

**Самостоятельное восстановление.** На неизменном приложении `06cde99`
`.build/completion-stationary-clarity-06cde99-v2` дал3 PASS для pressure release,
capture remount и сохранности принятого текста/выделения при смене плотности.
Четвёртый, `AgentTableRenderingTests`, отказал на устаревшем наблюдении: любой
WK считался незакрытой страницей, а таблица должна была иметь только raster view.
Теперь тест различает DocumentWebCoordinator и установленный AgentWebCoordinator
точного источника. Закрытые document WK по-прежнему должны исчезнуть; таблица
имеет ровно одну установленную поверхность. Если сцена требует runtime,
пассивный снимок его не заменяет. Проверяются прежняя плотность снимка, CSS pixel
ratio живой страницы, **реальные смонтированные тонкие полосы**, неизменность
камеры/чернил/источника и runtime token при последнем zoom. Внешний UIKit layer
WK не принимается за нарисованный WebKit backing.

`.build/completion-table-observer-v3/verification.json`: **1 PASS**, 0 skips и
runtime warnings, source SHA `5ee98ad82489d6ec0db5b628e69e597c24df52ee34cfad0521da3a53786d9f37`.
Оригиналы `45C906EF…png` (0,7027) и `78A5A170…png` (0,62) просмотрены: тонкие
полосы различимы; cache density1,5298957, один live presenter, прежний runtime
`B7B411C6…/BB708756…`. Ошибки начального наблюдателя и промежуточной компиляции
сохранены, не заменены этим PASS. Изменён только тест, не приложение; бюджеты,
тайм-ауты продукта и пороги не увеличены. Это native-проверка с настоящими
смонтированными пикселями, не физическая приёмка жестов.

**Первый отклик.** `.build/completion-first-response-analysis-20260915/analysis.json`
разбирает прежний контакт `A3DAF7FC…` из серии `5173ef41…`, а не создаёт новую
трассу. JS сообщает53ms pointerup→focus,54ms pointerup→click и1ms обработки click;
принят program_commit, затем наблюдается native_projection того же состояния.
Native receipt и часы JS не смешиваются: задержка получения сообщения не равна
длительности обработчика. Чтобы назначить причину53ms-интервалу, нужна штатная
трасса. Прежний pixel result102,78–120,78ms остаётся **FAIL ≤100ms**.

**Физическая среда и граница выпуска.** Физический iPad доступен, iOS27/24A435
(Simulator27/24A434). Существующий read-only UI observer пересобран отдельно;
его xctestrun не содержит UITargetAppPath или зависимости от Notebook.app.
`.build/completion-physical-observation-20260915/inspect.xcresult`: **1 PASS**,
0 skips/runtime warnings; это активация/снимок уже установленного приложения,
не доказательство касаний/Pencil или AX-перехода. Оригинальный экран прочитан
также штатным `devicectl device capture screenshot`. Физический маршрут
изображение→AX→ручной контакт остаётся открытым.

По отдельной квитанции `.build/physical-ipad-update-20260915-install/installation.json`
другая задача ранее установила `8af2a06 / c66cf36a…`, binary UUID `274A80D1…`,
0.3.62(65); **эта задача установленную пару не обновляла**. Этот источник и
происхождение явно отличаются от частной сборки, даже при одинаковом номере версии.
Новый узкий штатный Time Profiler probe выбран на физическом устройстве вместо
Simulator: `xctrace` завершился21 (`Cannot find process for provided pid: 838`),
хотя `devicectl` видел тот же Notebook PID до/после. `.build/completion-physical-timeprofiler-20260915/receipt.json`:
**не измерено**, без повторов при неизменных условиях. Кадры/CPU/GPU/память и
frame-drop≤1% этим не приняты. Рабочая пара не получает новый Release до этих
обязательных измерений; общий связный маршрут, десять повторов окончательного
среза и30 минут не подменяются прежними PASS разных источников.

## 15 сентября — наблюдатель прекращает наведение по неподвижным AX-рамкам

Изменён только `Applications/AcceptanceUITests/NotebookAcceptanceUITests.swift`.
`fitControlMaterial` читает native WK frame и три дочерних AX frame из одного
snapshot. Если после настоящего корректирующего pan/pinch поверхность изменилась,
а рамки контролов остались прежними, он сохраняет одну JSON/PNG пару и бросает
конкретную ошибку наблюдения **до следующего жеста и до проверки успешного fit**.
Точность сравнения1pt соответствует прежней проверке native pan. Шесть попыток
по устаревшим координатам и послойные повторные geometry attachments удалены;
ограниченный подбор при согласованной геометрии сохранён. Приложение, WebKit layout
и владельцы сцены не менялись.

Использован существующий `notebook_acceptance.py ui-build --run
.build/scene-geometry-observation-release/runs/d3f8489d-d961-46b1-8f07-3cc0cb89a795
--evidence .build/control-fit-fail-closed-ui`, затем `ui --test-build`.
Сборка только runner заняла7,272s; в products нет Notebook.app. Test source SHA
`bda91b5014dac5cd7206adc7284f56f34a0d5d53cb7357960812e4242bb53337`,
неизменное приложение source SHA `278c15d5…`, bundle SHA `1257a8c3…`.
Описи установленного binary/container совпали до и после сборки и всех трёх
проверок. `source_inputs` и Python-драйвер не изменяли, приложение/пару не
пересобирали, не переустанавливали и не сопрягали заново.

Проверка наблюдателя `testControlFitObserverRejectsFrozenAXAfterNativeMovement`,
run `4c494140…`: **1 PASS**, шесть положительных/отрицательных случаев для
pan, pinch, неподвижности и субпиксельного изменения. Короткий настоящий
`testCameraAndFirstTouchControlsOnAgentMaterial`, run `c3c8fa2b…`, воспроизвёл
нужное условие: native frame `[51.25,405.5,717.5,369]` →
`[126.75,415,717.5,369]`, все три AX frame полностью совпали. **UI FAIL за17,420s**
с сообщением `Control-fit observation failed after 1 correction(s)`;
xcresult exit65, 0 skips/expected failures/runtime warnings. В журнале ровно
один корректирующий pan и ни одного жеста после отказа. Единственная
geometry JSON `B742C210…` и оригинальный PNG `728BCCF2…` сохранены в attachments
этого run; PNG просмотрен. Это подтверждает остановку наблюдателя, **не PASS
доступности приложения**. AX после camera остаётся открытым в GUI-200.

Предшествующий 17-цикловый `ffb98383…` дошёл до цикла15 с принятой клавиатурой,
но прерван существующим лимитом драйвера240s при rotation; xcresult не завершён,
экспорт attachments/metrics отказал. Это **не PASS**; video/logs и failed scenario
сохранены, лимит не увеличивали, сценарий не повторяли. Полный v3 на `df2758f`
намеренно остановлен SIGINT на Core в10:39UTC по новому приоритету Амира, до
Xcode/Simulator; `.build/notebook-integrated-plan-full-v3` также не полный PASS.
Проверенные документный цикл и отказ микрофона не повторялись из-за этой правки.
Физическое сопоставление изображения/попадания/AX, системные метрики и общая
длительная приёмка остаются отдельными условиями выпуска, не задачами этого observer-среза.

## 15 сентября — отказ микрофона не прерывает настоящий текстовый чат

Чистая `.build/scene-geometry-observation-release`, commit `07967c5`, source
SHA `278c15d51a46b75c7943a72ce61d5b9c3bffa3c1963a84ddc5894960f5536cdd`.
Preserving upgrade основного `d3f8489d…` и уже существовавшего mini `de6f0bd8…`
сохранил обе описи данных, manifests и идентичности. Нового пространства ради
этого повтора не создавали; основной неотправленный черновик не изменяли.

После отдельного подтверждения Амира mini workspace `06E68B26…` сопряжено
обычными UI обоих приложений. iPad сверил Mac `bc46ef9e…`, Mac — iPad
`9a9850b3…`; окно показало «iPad подключён», публичный MCP затем вернул
`ready/connected` именно этого пространства. Доверие не подставлялось в store.

Mac XCTest оказался sandboxed: запись скопированного приглашения и в checkout,
и в runtime другого приложения получила EPERM (runs `0a747a55…`, `c6510a1d…`).
Заменён этот путь, не разрешения: закрытый файл теперь принадлежит собственному
контейнеру UI runner. Каждая попытка имеет уникальный файл; evidence содержит
только UUID ссылки. Reader проверяет пару, размер, права и отсутствие symlink.
`Tests/NotebookVerification/run.py`: **75 PASS**; обычное Mac копирование
`5ce409e6…` и `7b0eaf01…`: по **1 UI PASS**, iPad join `8a24c267…`:
**1 UI PASS за 31,588 s**, без skips/runtime warnings. Прежний Mac confirm-test
`7e88e5c1…` остановился до нажатия: selectable Text имеет пустой AX label.
Это ошибка наблюдателя, не доказательство отказа trust; финальное подтверждение
выполнено через обычное окно с видимыми точными адресами. Этот test не объявлен PASS.

Микрофон запрещён штатным `simctl privacy revoke microphone` только для
`com.amirtlinov.notebook.acceptance` на Simulator `523B6568…`. Реальный
`testDeniedDictationRetainsDraftAndTextSend`, run `85176cdd…`, — **1 UI PASS
за 40,762 s**, 0 skips/runtime warnings. Сохранены полный черновик, доступная
кнопка отправки, компактное сообщение без пустого task header, одна настоящая
отправка и точный ответ Codex с маркером `MIC_DENIED_1DE6529F…`. Сообщение
об отказе можно закрыть; текстовые контролы остаются доступны. Оригинальные
PNG `8651B903…` (компактное сообщение) и `AAB48CC8…` (реальный ответ) просмотрены.

Это закрывает данный реальный сценарий отказа, но не общую приёмку: AX после
camera, первый пиксельный отклик, 30 минут, системные метрики и физический iPad
остаются отдельными открытыми условиями. Рабочая установленная пара не менялась.

## 15 сентября — непрерывный native pan и граница accessibility

Три небольших кандидата отклонены и полностью удалены. Помимо layoutChanged
проверен UIKit layout из обновления representable: source `94beb7d4…`, run
`5c604f4b…`, **FAIL за24,967 s**. После шести pan WK frame ушёл с x51,25
до−404,75; дочерние AX frames остались прежними. Третий кандидат обновлял
геометрию смонтированных PhysicalWebViewport после финальной матрицы сцены:
source `b5c8ec11…`, run `c61322a1…`, **FAIL за33,755 s** ещё при поиске.
WK уже x51,25/y405,5, а AX кнопки x0/y132,8; ожидание20 s не исправило это.
Два следующих preserving upgrade сохранили данные и доверие частной пары.
Проверка не переводится на вычисленные вручную координаты старого AX-кеша.

Малые воспроизведения находятся только в `.build`, без Notebook/model/writer:
- `webkit-native-ax-repro`: одиночные native frame/transform/layout перемещения
  **4 PASS** на каждом из двух iPad Simulator27RC. Первая диагностическая
  app имела4 orientation warnings; исходный результат не объявлен warning-free.
- `webkit-hosted-ax-repro`: UIViewRepresentable, UIHostingController, custom
  accessibility action, scale и snapshot — **4 PASS**, 0 runtime warnings.
- `webkit-gesture-ax-repro`: непрерывный настоящий pan оставил AX0/19pt при
  native50,5pt. Этот первый опыт также ошибочно ожидал все75pt запроса: начало
  движения до recognition не принято обычным UIPan. Его FAIL сохранён.
- `webkit-settled-ax-repro` сравнивает с фактическим native delta50,5pt, без
  ослабления допуска1pt: **3 PASS/2 FAIL**, 0 warnings. AX после hosting-layout
  и layoutChanged остановился на19pt; обычный WebKit layout и ещё два варианта
  прошли. Это не устойчивое исправление: контроль без явного layout в двух
  опытах разошёлся. Просмотренные оригиналы `F59CD4FA…`/`998AEAC4…` подтверждают
  реальное перемещение видимой кнопки, отличное от устаревшего AX frame.

Исходники, xcresult и screenshots сохранены. Все созданные только для этих
опытов micro-app/runner bundles удалены с обоих Simulator; production bundle,
пара и содержимое не менялись. Диагностическая коллекция первого probe зависла
в собственном simctl diagnose после завершения тестов; прерван только этот
проверенный дочерний процесс, не тесты. Следующие прогоны используют штатный
collect-test-diagnostics=never, как основной маршрут.

В рабочем коде не оставлены уведомления, принудительный layout, visitor или
новая система очередей. Сохраняются лишь17-цикловая регрессия и независимая
запись native/AX geometry. AX-переход остаётся открытым в GUI-200; ни отдельный
удачный probe, ни сборка не считаются его исправлением. Продолжается независимая
приёмка чата и сохранности, не зависящая от поиска контролов по AX-координатам.

## 15 сентября — первый пиксельный отклик и устаревшие AX-координаты

Чистый `b9f74af`, source SHA
`945e44e8c9cc0a467bd79975fb2293feb89c3b99c241d5f3a6c24fd6c1453d0e`,
собран в `.build/completed-input-release`; preserving upgrade прежнего run
`d3f8489d…` сохранил обе описи данных, manifests, идентичности и доверие.
ScreenCaptureKit снова вернул complete PNG точного окна Simulator 339571 /
PID60210, 958×1369. Никакие настройки/разрешения не менялись. Источник и SHA
скомпилированного helper — `.build/window-capture-recheck-20260915/helper.json`.

`testTenReadyControlTapsWithNativeAndDisplayedFrameEvidence`, run `5173ef41…`:
**1 UI PASS**, 0 skips/runtime warnings, count17→27 ровно по одному. 337
подлинных PNG связаны с десятью touch begin/end, trusted click, неизменным
runtime/PID и калиброванными Mach clocks. Все 11 состояний в неизменном count
ROI просмотрены, сохранены `ready-controls-window/review.json`, оригинальные
PNG/ndjson и `analysis.json`. **Пиксельный порог ≤100 ms не пройден:** первый
release→count 102,78–120,78 ms (FAIL), остальные девять upper bounds
47,80–79,40 ms (PASS). Touch-start→count считается отдельно; FPS и физический
iPad этим не измеряются. Причина первого медленного интервала не установлена.

Следующий long-run `fe80f4b3…` — **FAIL за226,961 s**, 15 полных итераций,
ошибка на16-й. Count27→43, все четыре новых полных маркера0/5/10/15 прошли.
Публичная независимая заметка продолжена во время работы: run`a1733bb4…`,
action`F0DADB6A…`, contentRevision3, saved/readConfirmed. Это не30минут.
Отказ теперь у camera-fit: повторные pan продолжали двигать уже перемещённый
контрол по прежним AX frames, затем проверка не увидела очередного движения.

UI-only observer `ff73f02d…` на том же app воспроизвёл проблему за21,715 s
до смешанных циклов. Все шесть принятых pan переместили native WK frame
с x51,25 до−338,75 по−65/−9,5 pt; frames дочерних button/slider/field во всех
семи наблюдениях остались прежними (button/field x140,624). Сохранены
`control-fit-observed-geometry`, реальные native contacts и журнал`39f93ca7…`.
Это установленный разрыв native projection→AX, не доказательство потери
принятого pan. Проверяется публичный layoutChanged после native rebase,
без смены фокуса и уведомлений на каждом кадре; кандидат пока не принят.

Кандидат layoutChanged проверен на source SHA `88e80812…`: run `7e9d25f5…`,
**FAIL за23,619 s**, до смешанных циклов. Native frames двигались, дочерние
AX frames оставались прежними; сохранён native scene journal `760054e1…`.
Уведомление удалено, а не оставлено как запасной путь. Следующий опыт проверяет
обычный UIKit layout самого WebKit при изменении его фактической проекции;
без изменения canonical bounds, перезагрузки или явного сброса AX-кеша.

Time Profiler повторён после восстановления WindowCapture: вновь нет
start notification, exit1 (`.build/simulator-trace-recheck-20260915`). LLDB
attach не получил DAP stopped; выражения не выполнялись, private app продолжает
работать. Системные/физические условия и общий выпуск остаются открытыми.

## 15 сентября — XCTest завершал синтез раньше доставки последних клавиш

Повтор 30-минутного сценария на чистом `8af2a06/c66cf36a…`, run
`ipad-testThirtyMinutesOfMixedInteraction-da224e52…`, завершился **FAIL за
91,134 s**, после пяти полных итераций. Кнопка прошла 3→9, но немедленный AX
read второй строки увидел неполный маркер. Это не 30 минут и не новый PASS.

Для установления причины расширен существующий, явно включаемый только в
private Simulator, `NotebookInteractionDiagnostics`: доверенные beforeinput,
input, key/composition, selection и принятые/native состояния одного load token.
Ни события, ни состояние приложения observer не меняет; прежние лимиты журнала
сохранены. Diagnostic app `.build/input-state-observation-development`, source
SHA `8d852b5dba7e3c117ce6db1329a857c0869d97161c75dc642b3b6232da413357`.
Повтор `89301c76…` остановился **FAIL за 25,730 s** на первом немедленном read.
Журнал `af9f7b36…` содержит все 38 символов и принятых записей нового маркера
`0-09428A9A-681F-4124-BEBD-01C732C89D43`, без native_apply, смены runtime или
отказа admission. Последний commit получен через **284,7 ms после возврата
XCTest.typeText**, то есть через 181,6 ms после первого AX read. Это время
получения диагностического события, не touch-to-photon или бюджет продукта.

Второе AX read и точное сохранённое состояние Mac совпадают; публичный run
`cc98110c-3f29-4dec-b376-001da151bf3a` completed/has_more=false. JSON
`000BECA0…`, просмотренный PNG `EC41BBF5…`, оригинальный ndjson, SHA/identity и
производная временная таблица сохранены рядом с `89301c76…`. Следовательно,
этот отказ — неверная граница наблюдения незавершённой доставки, не потеря
уже принятого текста. Более старые отказы не получают задним числом PASS.

UI-проверка сохраняет первое значение, затем ожидает полный маркер через
ограниченный predicate expectation (3 s), без повтора клавиш, перезапуска или
изменения исходника программы. Семь тех же смешанных итераций дают короткую
регрессию; длинный сценарий использует тот же метод, не отдельный путь жестов.
CPU-контракты observer: **7 PASS** (`.build/input-state-observer-tests-v2.log`).
UI-only diagnostic повтор `0364699b…`: **1 UI PASS**, семь полных итераций,
0 skips/runtime warnings; установленный bundle не изменился. Новые маркеры
`0-D1F61821…` и `5-C7E6A29C…` приняты полностью, 1629 native records, без
retire/native_apply; журнал `ecd3e67f…` сохранён в этом run. Общий чистый срез,
30 минут и физическая приёмка не объявлены завершёнными.

## 15 сентября — повторная установка одинаковых исходников сохраняет manifest

Чистый Release `8af2a06` имеет тот же source SHA `c66cf36a…`, что короткая
development-проверка. Первый upgrade `.build/accepted-input-release` сохранил
байты данных, но остановился до запуска пары: имя нового launch manifest
ошибочно определялось только SHA исходников и совпало с прежним. UI-сценарий
тогда не начинался. Failed-квитанция сохранена в `failed-upgrade-same-source`.
Перед повтором заново проверено совпадение текущих данных с обеими описями;
запущен только прежний точный private helper. Новый manifest принадлежит
конкретной передаче контейнера и имеет отдельный UUID, прежние manifests
не перезаписываются. Старый SHA-only путь удалён.

`Tests/NotebookVerification/run.py`: **71 PASS**; регрессия двух последовательных
установок одного source SHA проверяет неизменность обоих предшественников.
Настоящий повторный upgrade прошёл, описи данных совпали; run
`.build/accepted-input-release/runs/d3f8489d-d961-46b1-8f07-3cc0cb89a795`.
Приложения остаются неизменным чистым `8af2a06/c66cf36a…`; внешний драйвер
исправлен отдельно, его фактический SHA записан в `continuation.driverSHA256`.
Производственная пара не менялась.

CUA снова доступен. Отдельно в прежней неизменной development-сборке нажаты
шесть видимых русских экранных клавиш «привет»: слово показано в текущем поле
и целиком подтверждено публичным read `b9ff1645-b1a2-4e47-a6b2-16de901dfb44`.
Просмотрен настоящий Simulator со всеми клавишами; снимок
`.build/agent-input-frontier-development/public/actual-software-keys.jpg`.
Это отдельная программная клавиатура Simulator, не физический iPad.

## 15 сентября — сохранённая правка экспортирована; смешанный ввод обнаружил откат

После p95 тот же чистый `e99c235` прошёл
`ipad-testBigDocumentFullLifecyclePreservesActualSource-efa77678-9c48-4786-bf7a-0dd11e370908`:
**1 UI PASS**, 0 skips. Новый маркер
`Notebook UI edit 96778299-0D5D-4F4E-B726-384DEDBA6AF1` виден до закрытия
(просмотрен PNG `7C634F6B-3BC1-4185-AE82-0BC9BBBBFC04`), затем подтверждён
повторным открытием. Артефакты — в прежнем run `d3f8489d…` под
`.build/async-pairing-release/runs/`.

Публичный экспорт job `4100ffdf-e5ca-4477-86cd-d33ca130c217` сохранён именно
из `contentRevision 3@a4a8e3d6-4665-46d9-96ff-f9e7ab9da146`:
35 страниц, 2 331 848 bytes, PDF SHA
`caf7652ef83e41ac02ae621df50045c49597019a4bf888ace1c31d6036c3ee86`.
Маркер проверен в TeX и тексте PDF; сохранены 1680 выражений и 35 векторных
активов, проверены их SHA/bytes, действующие GoTo 1→34 и 34→1.
PDF страницы 1 и 34 просмотрены. Недоступная намеренная ссылка не стала
активной битой аннотацией. Аудит:
`.build/async-pairing-release/public/saved-edit-export-audit.json`.
Компилятор выдал 67 предупреждений о версии включаемых PDF; итоговый PDF 1.7,
warning-free экспорт не заявляется.

Первый смешанный run `ipad-testThirtyMinutesOfMixedInteraction-43a67229…`
**FAIL за 25,520 s**, 0 полных итераций: кнопка и slider сработали, но первая
строка клавиатуры сократилась до `0-7F-622-BF724A2C` и в UI, и в сохранённом
состоянии. 30 минут не засчитаны. Исправление продвигает существующий epoch
при admission адресного ввода и проверяет внутреннюю версию WebKit до
асинхронного применения native state; старый безусловный echo-путь заменён.
Passive/unfocused вычисление не считается принятой записью. Публичный
JavaScript API, единственный писатель и формат состояния не меняются.

`.build/agent-input-frontier-v3/verification.json`: **1 Mac + 65 iPad PASS**,
0 skips/runtime warnings, source SHA
`c66cf36a2c91d4a4ed939d26ac405ca3d4a6d8328f50e9164617150adac3a87c`.
Регрессии держат настоящий WKWebView и задержанный native callback,
проверяют более новый ввод, фокус/selection, density-only обновление,
повторный revision, последующее внешнее состояние и FIFO read за принятым
вводом. Три прежних attention fixtures теперь монтируют реальные native planes
с намеренно удержанным cohort вместо объявления подготовленных данных показанными.
Warning о захваченном mutable test flag устранён через существующий Signal.
v1 отклонён preflight выбора Simulator; v2: 1 Mac PASS, 55 iPad PASS/4 FAIL
(три немонтированных fixtures и недопустимый JS function-result в новой проверке).
Тот же SHA собран в неизменную development-копию Release и обновил прежнюю
частную пару без изменения данных/идентичностей/доверия. Настоящий
`testRepeatedNativeKeyboardInputPreservesExactTypedMarkers` — **1 UI PASS**,
0 skips/runtime warnings; run `4b62a464-7a6c-46e1-8eb8-84f657338c21` под
`.build/agent-input-frontier-development/runs/d3f8489d…`.
Оба полных новых маркера есть в первом AX-чтении сразу после typeText;
без дополнительного ожидания. JSON `03EFA8B3…`, `61BEFB1B…`;
PNG `80B4A9F8…` просмотрен. Последнее значение UI в точности равно адресному
сохранённому значению Mac, публичный read `a111212f-7744-4697-8da9-58b9bc6ac062`.
Это короткая регрессия ввода, не повтор 30 минут и не финальная чистая приёмка.

## 15 сентября — большой документ прошёл оба порога p95

Чистый Release `e99c235`, source SHA
`431328361128a6a8a3121a23daa8da74aa5a6deda957033db089081b7277738c`,
обновил прежнюю частную пару `d3f8489d…`: описи данных до/после совпали,
идентичности и доверие сохранены. Производственная пара не изменялась.
Контроль `d1bc3dea…` измерен до следующей правки: 140 блоков, 1680 формул,
35 SVG, более 6 MiB исходника; два прежних UI-маркера сохранены.

`.build/async-pairing-release/runs/d3f8489d-d961-46b1-8f07-3cc0cb89a795/`
`ipad-testTenColdOpeningsAndWarmDistantLinksMeetNativeInstallationBudgets-668723fb-2217-4fe3-8c3c-199ffe8b74ff`:
**1 UI PASS**, 0 skips; установленный bundle до/после совпал.
Десять новых процессов приложения/WebKit дали cold p95 **2895,64 ms**
(порог 3000); двадцать тёплых ссылок — p95 **254,02 ms**, максимум
257,06 ms (порог 300). Ресурсные бюджеты и подтверждения установки не ослаблены.
JSON: `B0F596CF-DA55-4037-AF60-AB9A15A92D50` и
`23E886FB-48D5-4D25-BAE5-7D25F370607F`. Последние cold/distant PNG просмотрены:
текст, формулы, SVG и обратная ссылка установлены на настоящей странице.
Это request-to-observed-installation Simulator, не FPS или touch-to-photon.

Отдельный новый mini-стенд `de6f0bd8…` ещё не прошёл UI-сопряжение.
Mac UI runner истёк через 240 s до входа в тест; sample PID 65643 показывает
`libsecinit_appsandbox` → XPC до main. Диагностика:
`.build/async-pairing-mac-runner-sample.txt` и mini-run
`mac-testCreateInvitationThroughMenu-7ad9d4f1…`. Прямой запуск точного private
helper показал обычное окно и после Copy — «Приглашение создано. Ожидается iPad».
Затем CUA native pipe закрылся при выборе окна Simulator. Защита системы не
отключалась, успех сопряжения не заявлен. Mini helper остановлен; продолжается
независимая проверка исходной частной пары. Общий выпуск пока не принят.

## 15 сентября — Keychain не задерживает UI и не публикует старое сопряжение

Security warnings полного Mac-прогона были реальным синхронным Keychain путём
на MainActor. `NotebookKeychainPairingStore` теперь actor; прежние синхронные
вызовы из запуска, UI и транспорта заменены ожиданием этого владельца.
`NearbySync` упорядочивает только credential mutations; каждая использует
последние сохранённые peers. Подтверждение сессии ждёт записи; повторный запрос
ждёт того же завершения. Старое намерение join и остановленная сессия не могут
публиковаться после ожидания. Shutdown дренирует принятую запись до завершения.
Идентичности, формат Keychain, ключи и условия двойного подтверждения не менялись.

`.build/async-pairing-ownership-v4/verification.json`: **25 Mac + 36 iPad PASS**,
0 skips/runtime warnings, source SHA
`0c8875dec99586c69977c1441a9071a3df701cb2522af2208b3fe1d95bd6d1d5`.
Проверены настоящие Keychain и TLS, прерванное потребление/отзыв, две
конкурентные ревокации, поздний startup после Stop, замена ожидающего join,
одна задержанная запись двух local confirmations и закрытие до её завершения,
а также прежние документные/чернильные границы shutdown.
Попытка v3 отклонена из-за ошибочного несуществующего селектора
`NotebookTests/NotebookShutdownTests`, не засчитана как успешный маршрут.

UI-проверки дополнительно ждут фактическую новую запись clipboard и сохранённое
подтверждение, не один click; Mac выбирается по точному пути аттестованного
приложения, а не общему bundle ID нескольких частных стендов. Это отдельное
test-only дополнение после v4; настоящая UI-проверка этой сборки ещё впереди.
Производственная пара не обновлялась, общий выпуск не принят.

## 15 сентября — общий прогон нашёл устаревшие Mac document fixtures

`.build/notebook-integrated-plan-full-v2`: **788 Core/Codex/worker PASS**,
включая настоящий read-only Codex scope, без пропусков; **47 MCP PASS**.
Mac завершился **203 PASS / 3 FAIL**, 0 skips, 3 Security runtime warnings.
Общий результат отклонён; до iPad стадия не дошла.

Три отказа локализованы в прежних предпосылках fixtures: состояния ожидались
от Markdown вместо программы, посторонняя запись состояния должна была
инвалидировать документ, выбор закрытой обложки должен был загрузить тело.
Проверки теперь используют настоящие interactive blocks, отдельно требуют
сохранить снимок при постороннем состоянии и потерять его при своём, а IPC
сценарий явно открывает документ через владельца presence/body admission.
Отрицательное условие «закрытая выбранная обложка не читает тело» сохранено.

`.build/mac-document-owner-fixtures-v1/verification.json`: **6 Mac PASS**,
0 skips/warnings, source SHA
`2c197fd4cfe245e3638b28a5e9d351eef042ec68025f3cc349b62e5a34c84466`.
Это исправление проверок контрактов, не изменение загрузки продукта.
Отдельные Security warnings в archive/pairing сценариях ещё расследуются;
они не исключены из условий полного допуска.

## 15 сентября — полный прогон: исправление ранней проверки идентичности

Первый общий прогон `.build/notebook-integrated-plan-full` на source SHA
`7fff61fafe6b8f566c202b0fb692300f181718198d99f550bebbafe7594bfb6a`
закончил Core без ошибок, включая обе нагрузки на 100 000 записей
(основная группа: 683 проверки, 998.998 s). Opt-in проверка настоящего
Codex scope была пропущена: её частный manifest не был передан.
Load fixture, 70 проверок verification и 18 проверок trace harness прошли.
Общий прогон **не принят**: PreviewInstaller получил 38 PASS / 1 FAIL,
следующие MCP/native/UI стадии не запускались.

Причина — устаревшее сравнение буквальной строки YAML с bundle ID.
Проверка теперь читает разобранную конфигурацию XcodeGen и подтверждает
пустой стандартный суффикс, каноническую iPad identity и прежние имена.
Продуктовые идентичности не менялись; фактические bundle/signature остаются
предметом release admission. Быстрые проверки установщика и release tools
перенесены перед тяжёлым Core, без удаления условий полной приёмки.
После исправления: **39 PreviewInstaller, 64 release tools, 70 verification
PASS** (`.build/preview-default-identity.log`,
`.build/release-preflight-plan.log`, `.build/full-preflight-order.log`).
Нужен новый неизменный общий прогон; предыдущая частичная проверка его
не заменяет.

## 15 сентября — остановленный ход не выдаётся за выполненный инструмент

Transcript получает существующие `CodexConversation.turnStatuses`. Изменение
только terminal status публикуется в том же WebKit, даже при неизменных сообщениях
и отсутствии активной работы. `interrupted` показывает «Остановлено», неизвестное
состояние — нейтральную строку, а не успех. Прежнее вычисление завершения хода
по окончанию инструмента удалено. Сортировка ключей не даёт порядку словаря
заново перерисовывать историю; раскрытые действия сохраняются.

`.build/chat-terminal-status-accepted/verification.json`: **12 iPad PASS**,
0 skips/warnings, source SHA
`525d8a6ca6beaa39a381095f96ae421673f02ce30776fcfd3d927544ce3156d2`.
Настоящий UIWindow/WebKit проверил один completed tool при unknown/interrupted/
failed/completed состояниях хода, status-only обновление, отсутствие shimmer
после Stop и сохранение DOM при перестановке ключей. Проверены также offline
Markdown/формулы и ссылки обсуждения. Частная Release-проверка той же реальной
истории выявила следующий дефект: после Mac restart загружался только один
последний turn, а раннее runtime-событие вообще исключало исторические статусы.
На настоящем экране вместо ложного успеха появилась нейтральная строка,
но прежний Stop ещё не был подтверждён; UI run `d3fc3781…` отклонён.

`CodexAppServer` теперь читает до 64 компактных turn metadata с
`itemsView=notLoaded`, без тел инструментов. Hydration заполняет отсутствующие
исторические статусы, не перезаписывает более свежие события и не передаёт
активность старому ходу. **18 Core/Codex PASS** в
`.build/chat-terminal-reconnect-core.log`: в том числе late-history против
свежего completed и исторический interrupted при runtime-событии. AX-проверка
заголовка использует фактический button раскрытия, не static text.
Новая чистая private Release-пара `.build/chat-terminal-history-release`,
source SHA `01810668a334e95e21647e2107f7882610abce66e02a2a5def1f75327c9d80fb`,
обновила те же данные/ключи. UI reconnect `2ce04274…`: **1 PASS**, 0 skips/warnings.
В том же настоящем чате после restart показан «Остановлено · 1 действие»,
сохранены единственный ответ, неотправленный черновик и человеческие `102`.
Общая приёмка выполняется отдельно.


## 15 сентября — системная трасса начинается по событию, не тексту журнала

`system_trace.py` теперь ждёт документированное `--notify-tracing-started`
через собственный libnotify descriptor/token. Регистрация предшествует запуску;
выход процесса, смена его идентичности и deadline по-прежнему запрещают STARTED.
Descriptor закрывается до допуска жеста. Старый разбор строки журнала удалён.
**18 PASS** (`.build/trace-start-notification-unittest.log`), включая настоящий
Darwin notify, чужое имя, точный token, закрытие ресурса и отказ по одному log.

Реальная Time Profiler запись частного Mac завершилась без строки `Recording
started` (`.build/profiler-private-peer-diagnostic`). Отдельная запись получила
настоящее уведомление через **1.9646 s** и завершилась с exit 0
(`.build/profiler-start-notification-diagnostic`). Однако фактический iPad PID
24470 в Simulator **не прислал событие за 20.096 s**; запись отклонена
(`.build/profiler-simulator-notification-diagnostic`). Исправление handshake
не является доказательством кадров/CPU/GPU Simulator или физического iPad.
Xcode 27 Beta 5 / runtime 27 RC использованы явно; гипотеза их несовместимости
не подтверждена одним отсутствующим событием. Пороги и бюджеты не менялись.
Отдельная проба host-PID без `--device` также не принята: xctrace завершился
с exit 21 `Cannot find process for provided pid`, хотя точный Simulator PID
38494 и его executable/start-time до и после совпали
(`.build/profiler-simulator-host-pid-diagnostic`). Этот путь не подставлен
вместо проверки нужного Simulator и не объявлен работающим обходом.


## 15 сентября — связная совместная работа и настоящее восстановление связи

Один созданный агентом документ `E63539DB-9C00-4889-82C6-46D643D927E8` и чат
`01a0a361-5821-7320-bcf7-cbe1362edff9` прошли продолжение: первое нажатие `0 → 1`,
агент `1 → 101`, человек `101 → 102`, устаревшая CAS получила `revision_conflict`,
Undo сохранил человеческие `102`. Следующий настоящий ход остановлен UI-кнопкой.
Затем остановлен только точный PID частного Mac, исходящее сообщение сохранено
на iPad, отдельный черновик пережил relaunch; после запуска того же Mac/manifest
ровно один новый native turn доставил ответ, не отправляя черновик.

Private Release `.build/search-contact-release`, source SHA
`185376ced96c00c7d379285360c0719d181040d7f7af51cadc40e1b1047a62b9`;
run `d3f8489d-d961-46b1-8f07-3cc0cb89a795`. Три последовательных UI-шага
в его `runs/<run>/` имеют суффиксы `6ae1d918…` (**298.391 s**), `05838cef…`
(**31.748 s**), `11d9ea45…` (**17.029 s**): каждый PASS, 0 skips/warnings.
Это продолжение существующей сущности после исправления проверок, не три
повторных создания и не утверждение о новом полном one-shot прогоне.
UI-build receipts: `.build/collaboration-search-owner-ui-v2`,
`.build/collaboration-outgoing-identity-ui-v2`, `.build/collaboration-reconnect-ui-v2`.
Они подтверждают неизменность установленного приложения. В diagnostic binary
была пробная `contentShape` поиска; она не исправляла причину и удалена из кода.

Реальная причина поиска: глобальный AX-запрос выбирал одноимённую фоновую
обложку вместо строки collection view. Исправлена область запроса, не жест.
Outbox считает уникальные job UUID, а не два AX-потомка тела/статуса.
Reconnect принимает точный маркер с завершающей точкой из реального prompt;
сам запрос не считается ответом. `Tests/NotebookVerification/run.py`: **70 PASS**.

Независимые `public/continued-*` и `public/reconnected-independent-audit-*`
содержат реальные resume без replay и terminal `has_more=false`.
После reconnect человеческая версия `3@a4a8e3d6-4665-46d9-96ff-f9e7ab9da146`,
creation saved/received/shown confirmed; Undo preserved=1/restored=0,
shown=not_required (`undo_without_visual_changes`). Attention SHA
`a5a12c7f6d576594b37097caf1a11f972c143bd78be5905957c47738238a0d65` неизменен.
Полная native-история в `public/reconnected-native-history.json`: единственный
новый ход после отключения, без повторной отправки. PNG после Undo/Stop и
`37625F24-0D65-4B8B-803D-C387E3CF4DB8.png` после reconnect просмотрены.

Граница Stop точная: native turn `01a0a390…` interrupted, но уже принятый
readonly JS run `b94a6f9b…` завершил пять чтений без эффектов. Это не отмена
всех durable операций. На снимке найден неверный заголовок «Выполнено» вместо
статуса остановленного хода; следующий срез исправляет его у владельца истории.
Production, общая, 30-minute и физическая приёмка здесь не затронуты.


## 15 сентября — готовность WebKit не повторяется при обновлении представления

Настоящий совместный сценарий выявил бесконечную последовательность
`load → ready → новый RasterLease → SwiftUI update → load`: iPad занимал CPU на
100%, пока уже готовый WebKit заново подтверждал ту же готовность. Новый callback
подменяет получателя, но не создаёт событие состояния; готовность по-прежнему
приходит от фактической подготовки нужной версии. Тот же растровый entry не
заменяет `@State` новым объектом без изменения пикселей.

Исходная регрессия `.build/live-readiness-replay-reproduction/ipad.xcresult`
получила **43 вместо 2** уведомлений после 40 одинаковых обновлений и перемещения.
`.build/live-readiness-event-final/verification.json`: **13 Mac + 47 iPad PASS**,
0 skips, 0 runtime warnings; source SHA
`b57c392226c9ffba4598c69bff170a63dea0721288039f817c1deaec7a940234`.
Проверены также реальные изменения state/capture policy и отказ захвата до
отложенной доставки прежнего события. Ошибочный запуск с несуществующим именем
Mac suite исполнил 0 тестов и не засчитан.

Частная Release-пара `.build/live-readiness-event-release`, source SHA
`70635745ba833397749c03c75bf6830e2f31b303c6ea20e09b2b2df8d7daec25`, обновлена
с сохранением прежнего пространства и доверия. Sample её фактического iPad PID
24470 (`/tmp/notebook-search-post-readiness.sample.txt`) показывает главный поток
в системном ожидании в 786/787 samples вместо прежнего непрерывного обновления.
Сквозной recovery-тест пока **FAIL** на первом выборе поиска; отдельное последующее
нажатие действительно показало нужную обложку. Это не принято за завершённую
совместную работу, и документ/чат не создавались повторно. Production-пара
не изменялась.


## 15 сентября — документный контакт не готовит невозможный drag

Тот же владелец attention сначала разрешает источник контакта, затем спрашивает
его владельца о допустимости и только после этого захватывает пиксели. `onLift`
отклоняет документный фрагмент до снимка; ссылка больше не оплачивает capture,
который всё равно отбрасывался. Обычный выбор контекста и допустимый drag
используют прежний путь, без второго hit-test или воспроизведения координат.

`.build/selection-source-admission-accepted/verification.json`: **8 iPad PASS**,
0 skips, source SHA `210ee5cc6f9d0d11019ed754a62ba5e9c0b6e1f37076694717a782361189b5ec`: attention admission, реальная дальняя ссылка и
возврат, два native drag и resize одного WebKit. В последнем тесте устранено
устаревшее ожидание пассивного ImageView: видимый элемент теперь имеет runtime.
Контакт начинается после адресной готовности его пикселей, а не только наличия
чужого кеша; сохраняются исходные проверки позиции, углов и цвета. Все изменения
источника, размеров и принятых перемещений проверены настоящими владельцами.

## 15 сентября — доступность содержимого через границу hosting

Полное копирование `EnvironmentValues` в `NotebookWorkspacePresentation`
скрывало вложенное дерево доступности при видимых и смонтированных native views.
Один label, внешний `contain` и явная передача массива native children это
не исправляли; эти обходы удалены. Через границу теперь передаются только
`NotebookAppModel` и текущая композиция, как у остальных физических владельцев.
Безымянная обложка получила содержательное название по виду предмета.

Обе исходные UI-проверки прошли без изменения жестов и ожиданий: частично
изогнутая обложка с чернилами и открытие меню/плагина над настоящим Pencil.
Оригиналы `workspace-ax-owned-environment/attachments/EFAAA2FA-13C8-4CAA-9B72-4CC7E84CEFF2.png`
и `EA5D910F-D37B-4163-AE11-3347A2215767.png` просмотрены: обложка/чернила/бумага
сохранены, управление меню читаемо. Отдельный финальный срез
`.build/workspace-ax-final/verification.json`: **10 iPad PASS**, 0 skips,
source SHA `dc32e4133ba2b333b6619f8e818f15126b9cfe1ef96cebc324bea98f091cf605`. Покрыты также захват обложки, native presentation и drag
при занятом ресурсе. Общая и физическая приёмка ещё не завершены.

## 15 сентября — ожидание растра принадлежит реальному запросу

У фонового снимка удалены 8-секундный таймаут допуска и опрос кеша каждые
20 мс. Один `SceneRasterCaptureRequest` передаёт последнюю область/плотность
тому же исполнителю; фактический WebKit completion удерживает точный `RasterLease`
до событийной доставки. Ошибка версии или закрытие завершают только свой запрос.
Предел исполнения WebKit остаётся 8 секунд после допуска; ожидание ресурса
его не расходует. Камера не перезапускает программу, submitted backing не
освобождается раньше настоящего callback.

Нативный сценарий удерживает все фоновые слоты **8,2 секунды** и действительно
перетаскивает обложку. Она сохраняет физического владельца и прежние пиксели,
а адресный источник уточняется сам после освобождения ресурса. Fixture использует
пассивный markdown: видимый интерактивный WebKit теперь законно получает отдельный
live допуск и не должен искусственно ждать фонового барьера.

Mac-проверка прежде требовала полный wide-gamut снимок плюс выходной буфер,
которые не помещаются в её 5 МиБ. Диагностика зафиксировала настоящий
`resource_limit`; XCTest маскировал его `InvalidTransition … failed(deinit)`.
То же воспроизведено до изменения. Проверка теперь подтверждает отказ полного
запроса и собирает **тот же 512×512 результат из точных 2× фрагментов**,
не повышая бюджет и не снижая разрешение. Все восемь источников последовательно
освобождают WebKit; ограничение сохраняется после каждой записи.

.build/scene-raster-events-accepted/verification.json: **13 Mac + 101 iPad PASS**,
0 skips; один неизменный source SHA
`06b0008270239edafa6b6179960193eca52d0bd117af96bce505f4f8c27c5d14`.
Покрытие: композиция, адресные отказы/ретаргетинг, последовательное освобождение,
закрытие ожидающего читателя, реальный native drag под ресурсным давлением.
Это выбранный ресурсный срез, не общая Release- или физическая приёмка.

## 15 сентября — передача физической проекции без отсоединения WebKit

В отдельной диагностической Release-паре (`document-input-diagnostic`, SHA
`d433471170211917164dc2d66d7a8fb7db4db7b53682c3a4893c89ceb2037941`)
страница 35 уже имела `installed=true, nativeInput=true` через 2,07 мс после
принятия подготовленной поверхности. Затем **монтаж невидимого соседа занял
53,34 мс**; первая проверка ввода смогла исполниться лишь через 77,95 мс.
На возврате тот же монтаж занял 0,02 мс. Это адресная диагностика через
существующий журнал, не p95 и не системные FPS.

`DocumentWebHost` теперь передаёт существующий `PhysicalWebViewport` целиком,
вместо переноса WebKit через новый отсоединённый wrapper. Старый host перестаёт
владеть проекцией в том же переходе. После фактического UIKit completion старую
бумагу принимает подготовительный контейнер установленной цели: сохраняются
окно, геометрия и непрерывный допуск ресурса, но не ввод старой страницы.
Следующая подготовка использует эту же проекцию; прежний idle reclaim остаётся.
Удалённые пустые проекции больше не остаются детьми host. Измерение готовности,
его частота и пределы ресурсов не изменены.

`.build/document-projection-handoff-final/verification.json`: **54 iPad PASS**,
0 skips, source SHA `2f9f6c2eb45c8b203b50ef5cc5d6a667a13ea3e7f976662be8b15e22782030d0`.
Проверены отсутствие промежуточного `window=nil` у WebKit, идентичность проекции
при реальном owner handoff и удалении старого host, отмена/смена цели, давление
ресурсов, сохранение принятого ввода и геометрия большого исходника.
Частная Release-пара на тех же исходниках прошла один полный переход:
**2812,71 / 250,31 / 220,11 мс** (открытие / дальняя / возврат).
Монтаж соседа уменьшился с 53,34 до 7,98 мс; задержка наблюдения ввода
после contentReady — 36,60 мс вместо 75,88 мс в диагностическом проходе.
Снимок дальней страницы просмотрен: тот же текст, формулы, SVG и возвратная
ссылка. Это **не новый p95** и не общий допуск. В
`document-projection-handoff-release/navigation-attachments`: cold
`116E0F52-5E92-4388-822C-29A8F8A8C67A.json`, far
`20572627-F692-40F1-8940-2A9ED4BB6037.json`, return
`2C4728BD-AC73-42AC-8100-E27B4635CC7C.json`, просмотренный PNG
`8DA2D33F-9FF7-4DFF-BD89-248654B47CAF.png`. Пара обновлена только внутри
прежнего private run с сохранением данных, идентичностей и доверия.

## 15 сентября — конечные точки обложки не занимают экранную очередь

Убран прежний путь почти прозрачного «прогревочного» кадра при progress 0/1,
на iPad и Mac. Конечную точку показывает уже существующая живая обложка/бумага;
подготовлены один настоящий снимок и общий CI shader. Экранный drawable
запрашивается только при настоящем изгибе, который продолжает нативный progress
камеры. Фиктивные progress 0.002/0.998 и warm opacity удалены, не перенесены в
новый renderer. Во время контакта снимок переиспользуется, сам изгиб не блокируется
запретом фоновой подготовки. Бюджеты/геометрия не изменены.

`.build/cover-endpoint-v1/verification.json`: **19 iPad PASS**, 0 skips,
source SHA `59b5fb2c8486b4a4fcbfd057230f2ee53601d4b59dd5f7dde1dbea35ddfee9b8`.
Проверены оба resting endpoints без подачи невидимых кадров, первый настоящий
изгиб во время принятого контакта, detach/reattach, непрозрачность, настоящий
document pinch и прямоугольники бумаги/обложки в обеих ориентациях.

Частная Release-пара `cover-endpoint-release`, тот же run d3f8489d… и прежние
данные/идентичности/доверие: один реальный проход дал **2745,75 / 297,18 /
270,11 мс**. Конфигурация текущей страницы началась через 129,23 мс вместо 1157,62 мс
в предыдущем проходе. Это **не p95**.
Артефакты `cover-endpoint-release/navigation-attachments`: cold
`72B7BB6D-0095-4D9C-B345-95E0342E7D49.json`, far
`22E6EBF3-07DF-4B1D-9628-7A89281EB8CB.json`, return
`80B6EB28-018A-4FD4-BB98-A1ED9BE40398.json`. Production не обновлена.

Следующий неизменный проход из десяти холодных открытий и двадцати тёплых
переходов завершил все страницы: cold **p95 2821,17 мс ≤ 3000**, warm
**p95 346,06 мс > 300**. Возвраты 217,67–252,25 мс. Проверка поэтому FAIL,
а не допуск выпуска; после canonical у дальней страницы остаются 38–78 мс
до наблюдаемого native input. В `cover-endpoint-release/p95-attachments`
массивы: `A1320321-C6C0-4096-9969-004BCA11E003.json` (10 cold) и
`43D78B0D-1B6D-4378-AEE9-7D2ADCCCDFEB.json` (20 warm).


## 15 сентября — кадр обложки принадлежит действительному запросу камеры

`CoverCurlMetalView` не заимствует drawable при повторном UIKit display без
изменения пикселей/геометрии/прогресса. Отсоединённый view сохраняет последний
запрос; новое окно возобновляет его событием. Временные CI/Metal references
ограничены autorelease pool одного render-вызова, drawable запрашивается после
построения графа. Освобождение занятого executor возобновляет последний pending
кадр, вместо повторного setNeedsDisplay при каждом отказе. Геометрия, shader,
два drawable и прежние ограничения ресурсов не менялись.

`.build/cover-frame-demand-final/verification.json`: **19 iPad PASS**, 0 skips,
source SHA `dec293f9b428275a8ffd8a0178256d736d607976915ce8dfe6519b1299f88d6f`.
Проверены отсутствие повторной подачи неизменного кадра, detach/reattach без
дополнительного update/тапа, приостановка подготовки при контакте, непрозрачность
и реверс обложки, настоящий pinch документа и совпадение бумага/обложка в обеих
ориентациях. Частная Release-пара сохранила данные/идентичности/доверие; один настоящий проход
дал 3614,50 / 287,42 / 227,68 мс (холодное / дальняя / возврат), не p95.
Секундная задержка до конфигурации страницы осталась. Артефакты
`cover-frame-demand-release/navigation-attachments`: cold
`CDC07FEA-F420-4D51-B0AE-F6BC5B98997E.json`, far
`23BFA85C-B6A7-4A61-ADA8-B83CDBED3F9F.json`, return
`8C706E6F-C327-4570-BA20-99D1840DCEE4.json`.

Дополнительные два отказа `.build/cover-frame-demand-v1`/`v2` повторены с прежним
production renderer из `0c2e359` в `.build/cover-frame-baseline`:
`WorkspaceCoverContinuityTests` ждёт прежний целый cohort/очередь, хотя видимый
web-источник уже обслужен независимым live runtime (pending=0, bg=2, ready receipt).
`testCoverInkTravelsWithThePhysicalCurl` не находит AX item до жеста. Просмотрен
подлинный видеокадр на 4 с (`cover-frame-demand-v1/attachments/fixture-at-4s.png`):
обложка и чернила видимы, **это не пустая сцена**, а отсутствие AX-предмета.
Экспериментальный переход теста к реальному pinch не исправил начальную AX-границу
и не оставлен. Общая приёмка этих условий остаётся открытой.


## 15 сентября — измеренный источник не участвует в последующей разметке страниц

Существующий DOM-индекс хранит первый физический прямоугольник каждого сечения,
его текстовые границы/первую baseline и inset блока. Убрано повторное чтение этих
значений в compile. После единственного измерения source flow отключается от
живого layout tree; сам DOM и пустой typography host остаются у того же source
lease и освобождаются прежним адресным путём. Запрошенный клон измеряется в этом
host с прежними CSS/шрифтами. Новый renderer или DOM-независимая разметка не созданы.
Список всех line rects больше не удерживается. Учёт одного индексного ребра
увеличен с 32 до 64 байт под сохранённые cuts; лимиты пула не увеличены.

`.build/document-detached-source-v1/verification.json`: **9 Mac + 14 iPad =
23 PASS**, 0 skips/runtime warnings; source SHA
`b5090742904e72b174b26378efce5577ea43ca6bb6087880f7c493d6a2d71e36`.
Проверены настоящий большой источник, точные glyph/vector координаты относительно
полного оригинала во всех размерах бумаги, list marker pixels, rowspan, Unicode,
реальные декодированные изображения, отмена/закрытие индекса и UI-ссылки туда/назад.
Новая регрессия запрещает любые чтения geometry/style исходного DOM при извлечении
первого и дальнего листов после detach, сравнивая с реальными cuts до detach.
Независимый pixel oracle только в тесте подключает настоящий оригинал обратно;
production никогда не использует этот путь.

Частный Release `document-detached-source-release`, тот же run d3f8489d…,
сохранил все байты данных, идентичности и доверие. 10 холодных открытий + 20
настоящих ссылок завершились без пустых страниц, но пороги **не пройдены**:
выборочный p95 открытия **3611,72 мс**, переходов **328,55 мс**. Возвраты
заняли 212–246 мс. В `p95-attachments` cold:
`BEBBA131-61C1-47A4-8254-B15EDCC1625A.json`, warm:
`99D3C34F-A743-4E65-B1C1-A0FA92C9FE43.json`. Этот результат относится к
неизменённой второй ревизии большого документа и не является физической приёмкой.

В медленных открытиях navigation journal показал около 1040 мс между регистрацией
страницы и запуском её MainActor-задачи. Системный sample, запущенный по настоящему
`physical_page_update` после `opening_body_requested`, обнаружил ожидание
`CAMetalLayer.nextDrawable` в `CoverCurlMetalView.draw`: 668 из 753 выборок главного
потока внутри semaphore wait. Свидетельства в
`document-detached-source-release/open-sampling/targeted-opening.sample.txt` и
`targeted-trigger.json`. Это диагностический, возмущающий исполнение проход,
не повтор p95 и не замер кадров/GPU.


## 15 сентября — живой handoff не монтирует уходящий WebKit повторно

На частной Release-паре `document-lazy-live-release` сохранены байты данных,
идентичности и доверие прежнего run d3f8489d… . Реальные ссылки прошли, однако
один проход дал 3255,46 / 372,28 / 816,96 мс (открытие / дальняя / возврат).
Без AX-обхода во время подготовки открытие заняло 3198,48 мс. Это не p95 и не
достижение порогов. Системный Time Profiler повторно не подтвердил начало записи;
workload остановлен до жестов, кадров/CPU/GPU этот запуск не доказывает.

Штатный navigation journal показал синхронный повторный монтаж уже ушедшего
WebKit до допуска новой поверхности. Он удалён: входящий renderer сохраняет
свой установленный host, исходящий явно отдаёт ввод и остаётся reclaimable idle.
Монтирование происходит только при следующей настоящей потребности. Прежние
ограничения принятых контактов, поколения и закрытия сохраняются.

Индекс по-прежнему обходит настоящий измеренный DOM и уступает браузеру через
один MessageChannel, но по выполненной работе: 4 мс либо 1024 узла, с проверкой
каждых 256. Отдельно записываются работа/ожидание индекса и классификация/
декодирование изображений; подтверждения шрифтов, геометрии и paint не удалены.
Manifest navigation observation теперь включает выделенного владельца страниц
и прежнего владельца программ, а не проверяет старый адрес hook.

`.build/document-source-slices-v2/verification.json`: 7 Mac и 17 iPad PASS,
0 skips/runtime warnings; source SHA
`e51fc046cd65ea3368d5169037a1278209bffc2a921de5ac365760e61d0cbeba`.
Проверены большой реальный WebKit, геометрия, декодирование, закрытие/ошибка
при передаче, live-переход и настоящий жест ссылок туда/назад. Дополнительно
12 JS checks и 14 navigation-driver checks PASS. v1 не запускал тесты: при двух
Simulator отсутствовал явный выбор; v2 выбрал прежний тестовый Simulator.
Частная Release-пара `document-source-slices-release` обновлена с сохранением
данных/идентичностей/доверия. Один реальный проход: 3957,97 / 384,22 / 769,40 мс;
это **не p95 и не достижение порогов**. Native/WebKit receipts лежат в
`.build/document-source-slices-release/navigation-attachments/`. Измерение исходника
одно: DOM 261, typesetting 654, классификация геометрии изображений 557,
реальное ожидание decode 0, индекс 558 (активная работа 75, очередь yield 477) мс.
Классификация вызывает первую обязательную геометрию: её нельзя просто удалить
как ожидание картинки. Возврат также тратит 343 мс на подготовку пакета и 251 мс
между отправкой frame и ответом JS; измеренный большой DOM остаётся connected.
Следующий срез удерживает этот же DOM/индекс по прежнему lease вне live layout tree.


## 15 сентября — дальние изображения не входят в load; non-curl без cross-dissolve

Markdown теперь один раз санитизируется в inert DOM fragment. До подключения
изображения получают `loading=lazy`. `waitForGeometry` по-прежнему ожидает
декодирование при зависимости разметки от intrinsic размеров; каждая показанная
страница явно переводит свои изображения в eager и ждёт настоящий `img.decode`.
`document.fonts.ready`, typesetting, проверки геометрии и две paint callbacks
не удалены. В WebKit font-ready promise также связан с окончанием document load
([FontFaceSet.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/css/FontFaceSet.cpp));
поэтому ненужная загрузка дальних фиксированных иллюстраций могла удерживать
первую страницу. Эффект на Release latency ещё предстоит измерить.

Дальняя ссылка передаёт уже подготовленную поверхность непосредственно через
`UIPageViewController.setViewControllers(animated:false)` и подтверждает её
настоящим completion. Удалён отдельный cross-dissolve с лишними 140 мс и
композиторной копией. Смежное ручное перелистывание и его curl сохранены.

`.build/document-load-policy-final/verification.json`: **7 Mac + 16 iPad =
23 PASS**, 0 skips/runtime warnings, source SHA
`56413ba5273812610f0dfb6bf8197906ea8a6f46f4a612f37f50285fae7ae666`.
Большой источник проверен в настоящих Mac/iPad WebKit: неизменное измерение,
геометрия и пиксели возврата, видимые декодированные SVG/формулы, дальний live
handoff без второго render, ошибка composite не отравляет live, реальные ссылки
туда/назад. `/tmp/notebook-document-load-policy-js-final.log`: 12 JS checks PASS.

v1: 7 Mac + 13 iPad фактически прошли, но квитанция верно отказана из-за опечатки
в дополнительном селекторе теста. Отдельный JS-прогон обнаружил устаревшую
изолированную extraction-фикстуру: её render scope не включал настоящий
`waitForProgram`; теперь она исполняет этот же production helper, не заглушку.
Это проверка корректности изменения, не достижение Release p95 и не допуск пары.


## 15 сентября — внимание подтверждает выбранные пиксели, а не исправность соседей

`DocumentPresentationScope.region` проверяет каноническую бумагу и точные
program receipts только для пересекающих выбранную область источников. Захват
синхронно снимает установленное нативное поддерево; полный page receipt и
полный снимок по-прежнему требуют всех программ. Неверный crop, устаревшая версия,
редактор вместо бумаги, переход и выбранная сломанная программа дают отказ.

`.build/document-region-attention-final/verification.json`: **20/20 iPad PASS**,
0 skips/runtime warnings; source SHA
`73535e31dd138fcc16f890fe8cdb551cd7fe7009dcbadd948f4b5094008e6199`.
Реальный документ с неисправным соседом позволяет захватить текст, но не сам
неисправный контрол. Проверены живые DOM-only изменения без commit, immutable
PNG, холодный root с чернилами и настоящий finger hold/drag с появлением области
в истории. PNG `gesture/EA9FB5FA-CF3D-4184-B763-3284A6DA79BE.png` просмотрен.

Первое native-ожидание преждевременно читало новый cohort до его физической
установки; теперь тест ждёт реальную installation. Отрицательные UI-проходы
v1–v3 не нашли Pencil leaf в AX, хотя отдельный запуск и нативная иерархия
подтвердили установленный видимый лист с чернилами и включённым PaperInputView.
Finger-тест теперь проверяет видимые чернила, не Pencil-only AX leaf; его
настоящий drag прошёл. v4 затем обнаружил старый `notebook-chat-toggle` в helper
истории: он заменён текущим путём companion → menu → history, без UI-алиаса.
Недоступность Pencil leaf в AX на этом Simulator остаётся отдельной границей
accessibility-приёмки, не объявлена исправленной. Это не полная приёмка выпуска.


## 15 сентября — видимость сама подготавливает программы; отказ соседа не блокирует бумагу

`DocumentProgramOwner`, `AgentOverlayView` и пространственный cohort больше не
выбирают три «разрешённых» элемента перед общим распределителем. Действительная
видимая область задаёт спрос всех контролов, неизменный `SceneRenderResources`
допускает исполнителей и будит очередь при освобождении. Ручной путь «Запустить»
удалён. Вне экрана отменяется ещё не начатый спрос; принятый runtime освобождается
после checkpoint писателя. Если необязательный снимок прежнего невидимого контрола
не помещается даже по количеству растров, он не удерживает executor перед новой
видимой работой. Фокус, принятый контакт и нативная камера сохраняют прежних владельцев.

Неготовая или сломанная программа имеет локальный статус. Ошибка освобождает её
WebKit, не отключая исправного соседа. Save подтверждает фактическую каноническую
бумагу; receipt действия над блоком — именно этот блок; receipt полной страницы
по-прежнему требует все источники. Реальный дальний live-handoff проходит и с
неисправной программой после отказа композитного снимка той же версии.

Неизменный `.build/visible-programs-v4/verification.json`: **30 Mac + 100 iPad =
130 PASS**, ноль пропусков и runtime warnings. SHA исходников
`38add50af6596eb459a4579b27f153ff9b7d631f7bf453befdddfb7ff6b07b1c`.
Проверены реальные WebKit, девять видимых программ и переход видимости без
активации, принятый state после возврата, очередь без места, нулевой raster limit,
Save/agent display при сломанном соседе, нативная обрезка, портал и проекция чернил.
Настоящий UI-drag первого slider дал `x=7`, `x²=49`; PNG `ui/A7409863-0705-4B49-B4C4-6CE2769B2262.png`
и `nine/7687B122-0D0B-48EE-A22E-DFFB63D24735.png` из этого каталога просмотрены.

v1/v2 остановились на ошибках компиляции новых тестов (затенённый аргумент и
неразвёрнутый WorldPoint?). v3: 30 Mac и 95 iPad PASS, три новых теста FAIL:
они преждевременно читали DOM/installation или ожидали прежний prefix-кворум
после смены видимости. Исправлены ожидания настоящего готового владельца, без
увеличения пула, тайм-аутов или допуска геометрии. v4 — итоговая проверка.

Это законченный локальный/UI срез, не полная приёмка. p95 большого документа,
актуальный экспорт после правки, совместный disconnect/reconnect, общий Release
и физические кадры/CPU/GPU/память остаются открытыми в GUI-200/201/202.

Правила выбора и квитанции — в [контракте выпуска](release-build-contract.md#выбор-проверки).
Ниже — результаты конкретных срезов; исторические команды и ограничения не
переопределяют текущий контракт.

## 15 сентября — независимые версии бумаги и программ (GUI-200)

`.build/document-page-state-final/verification.json`: **46/46 Mac, 56/56 iPad**,
0 skips/runtime warnings; source SHA-256
`922caec451efc5ac9643e10f3a4f075f5a8c4e30eec574a389e110cd365c81df`.
Глобальный stamp состояния удалён из ключа каждой страницы. Бумага не получает
программные state echoes; составное изображение зависит только от измеренных
программ этого листа. Геометрия больше не наблюдает ненужный state. Явное состояние
и его показ подтверждаются одним program runtime с проверкой текущей версии
после браузерного paint; admission к применению не выдаётся за shown.

Настоящий iPad WebKit подтвердил неизменные generation бумаги и entry ID снимка
соседа после двух разных программных правок. Внешняя правка counter не подтверждается
до его реального DOM/paint. Mac проверил отсутствие новой работы DOM/math/state
для изменения программы другого листа; остальные runtime/editor/resource тесты
также прошли. Первый настоящий drag slider без предварительного тапа изменил
x=3 → 7, x²=9 → 49; финальный PNG просмотрен:
`.build/document-page-state-final/slider/F26D1FC2-C5F6-422E-8818-43595746A123.png`.
Это ещё не автоматический допуск всех видимых контролов и не общая Release-приёмка.

## 15 сентября — непрерывный редактор и подтверждённый Save (GUI-200)

`.build/document-save-continuity-final-v2/verification.json`: **9/9 Mac, 76/76
iPad**, без пропусков и runtime warnings; source SHA-256
`9e24dd848b72bf886bd0ae5243c9889d496d0fd47209fcf9d7eac1d76052236c`.
Core: `swift test --filter 'document(SourceCAS|Edit|Draft)'` — **5/5**,
`/tmp/notebook-editor-core-v1.log`. Выбранный финальный маршрут отдельно
отклонил два ошибочных имени UI-тестов до исполнения; исправлены только селекторы.

Жизнь открытого документа удерживает модель, а не отдельный physical host.
Пересоздание представления и новая версия соседнего блока сохраняют тот же WK,
textarea, DOM-фокус, composing draft и выделение. Явный background/close читает
последний черновик без закрытия редактора; окончательный detach удерживает реальный
допуск до ответа DOM и передачи владельцу записи. Caret, selection и scroll
сохраняются в адресной записи черновика, в том числе при CAS-конфликте.

Save проходит saving → saved → installed. Readonly-редактор удерживает сохранённый
текст до установки его точного источника; нативный локальный статус предоставляет
этот текст и при отказе показа. Только фактическая каноническая установка завершает
обновление. Агентское изменение за незавершённым редактором не получает shown:
проверка использует настоящую SpatialWorkspaceView без дублирующей paper-поверхности.

Настоящие двойное касание, клавиатура и Save показали «Новая строка» до закрытия
документа; финальный PNG просмотрен:
`.build/document-save-continuity-final-v2/attachments/2FE9D377-C903-4EC6-8561-48B41E82FB37.png`.
Тот же набор проверил prose curl 1 → 2 → 3 → 2 → 1, дальнюю ссылку/возврат,
ресурсные отказы, быструю смену цели, закрытие и восстановление смыслового якоря.
Ранние v2/v3 выявили устаревшую fixture display receipt; её заменили реальным
монтажом сцены, не ослаблением канонического подтверждения. Это не экспорт после
правки, не измерение p95 и не приёмка установленной физической пары.

## 15 сентября — содержательная позиция чтения (GUI-200)

`.build/document-reading-final/verification.json`: **12/12 Mac, 9/9 iPad**, без
пропусков и runtime warnings; source SHA-256
`1af6a30523b06c3f4ad2ee55cc8a1438228fb37c07a596e0f31e8ec0b8650aea`.
Отдельно `swift test --filter documentReadingPositionSurvivesReopeningItsStore`
прошёл 1/1 (`/tmp/notebook-reading-core-final.log`).

Существующий измеренный DOM публикует компактный индекс текстовых срезов вместе
с канонической разметкой. Якорь хранит блок, отпечаток и вхождение текста,
положение внутри него; при удалении блока выбирается ближайший сохранившийся
по прежнему порядку (при равенстве — следующий). Локальная позиция, относительный
масштаб и смещение камеры сохраняются адресно через единственного SQLite-писателя.
Полная разметка удерживается только открытым документом, не словарём SwiftUI.
Разрешение якоря запрашивает новую страницу; фактическую позицию по-прежнему
подтверждает только нативная установка.

Настоящий WebKit на обеих платформах проверяет перенос прежнего текста после
вставки 80 абзацев перед ним. v3 обнаружил неоднозначность одинаковых абзацев:
одного отпечатка и ближайшего абсолютного смещения недостаточно. Адрес теперь
различает порядковые вхождения одинакового текста внутри блока; старый путь
не оставлен. Модельная регрессия отдельно проверяет переразметку, промежуточную
старую страницу, закрытие/открытие, zoom и адресное восстановление из SQLite.
Это ещё не UI-приёмка всего сценария Save/экспорта; она продолжается следующим
срезом вместе с жизнью редактора. Пороги производительности и физическая пара
этим набором не подтверждаются.

## 15 сентября — первый обычный свайп по тексту (GUI-200)

`.build/document-paper-scroll-final-v2/verification.json`: **5/5 iPad**, без
пропусков и runtime warnings; source SHA-256 `b55b48e457800835be4a4aa3af6260b46f6c05457270cc4e6e5f8b92d25c6049`.
Старый неизменённый prose-сценарий прошёл 1 → 2 → 3 → 2 → 1 с OCR содержимого.
Проверены также дальняя ссылка/возврат, двойное касание и настоящий ввод с
клавиатуры, геометрия обложки/бумаги при повороте. Нативная регрессия проверяет
отключённую прокрутку загруженного WebKit и работающий scroll внутри textarea.

Причина прежнего отказа первого свайпа — не ожидание соседней страницы:
в `.build/document-prose-curl-owner-split` она была готова, но внутренний
`UIScrollViewPanGestureRecognizer` WebKit забирал контакт. Однократное выключение
его `isEnabled` не задавало политику scroll view после загрузки. Физическая бумага
теперь задаёт `isScrollEnabled = false`; curl и камера остаются у нативных владельцев,
внутренний редактор не лишается прокрутки. Временные трассировки удалены.

Первый совмещённый прогон `.build/document-paper-scroll-final` был прерван:
XCUITest завис внутри `waitForExistence(5)` при IPC-запросе клавиатуры больше двух
минут (`runner.sample`, `inputui.sample`, AX server-not-found). После перезапуска
только тестового Simulator тот же неизменный набор прошёл. Это не восстановление
runtime посредством таймера/кэша и не установка на физическую пару.

## 15 сентября — независимые программы и составной допуск снимка (GUI-200)

Финальный неизменный срез `.build/document-owner-split-v5/verification.json`
прошёл **46/46 Mac и 92/92 iPad**, включая настоящий дальний переход и возврат,
без пропусков и runtime warnings. Source SHA-256:
`79bd027ee5b623ff050cebb68de735b9d75b733e2e58653b9ff26068647c5576`.
Проверены также одиночный raster slot для простой бумаги, сохранение допуска
до синхронных наблюдателей публикации и адресное освобождение смонтированного,
но не выбранного соседнего листа. Принятый curl защищает этот лист до завершения.

`DocumentProgramOwner` теперь действительно владеет программами: перенесены
runtime-словарь, сохранённые изображения, применение состояния, checkpoint-задачи,
отмена и их завершение. `DocumentPagePresentationOwner` владеет бумагой,
подготовкой цели, композиционным снимком и нативной передачей. Общая
последовательная задача, ожидавшая запись любой невидимой программы перед
подготовкой независимой цели, удалена. Нативная регрессия удерживает callback
записи программы, проверяет готовность дальней бумаги до его ответа и
освобождение программы только после подтверждения её точного состояния.

Снимок получает допуск всех одновременно существующих слоёв — бумаги, срезов
программ и результата — до первого захвата. Исполнители используют переданные
резервы; публикация превращает их в изображения без повторного запроса тех же
байтов. Зарезервированы также все cache slots. Синхронная необязательная
подготовка больше не обходит ожидающую обязательную стадию; разделение и
передача уже полученных резервов сохраняются.

`.build/document-owner-split-v3/verification.json`: **90/90 iPad**, в том числе
настоящие касания дальней ссылки и возврата. Без skip/runtime warnings;
PNG дальней страницы просмотрен. Проверки охватывают ProgramOwner,
DocumentResourceLease и SceneRenderResources. Исходники:
`0566d4d0f0c6932f214deda938c4ec604e18e27cc63d03b1c4bc09208d063e28`.
Mac-v1 выявил недостаточный резерв: настоящий `CGImage` от WebKit имел
64 бита на пиксель. Для WebKit на Mac допуск учитывает этот формат до захвата;
лимит пула и цветовая точность не менялись. Mac-v2 прошёл **46/46**, включая
прямую проверку actual backing против выданного резерва. Финальный общий v4
остановился на старой проверке, которая ждала отказ ровно через те же восемь
секунд, что и исполнитель. Вместо расширения тестового ожидания исправлен
контракт: очередь derived-ресурсов больше не расходует срок исполнения.
Новая регрессия удерживает настоящий резерв 8,25 с, затем тот же WK завершает
ту же версию без Retry. Ошибки старых проходов сохранены.

Предыдущий v1 прошёл 46/46 до изменения допуска; v2 остановлен при компиляции
новой проверки из-за порядка именованных аргументов. Это исправлено, прежний
отказ сохранён. Производственная пара не обновлялась, большие Release-повторы
и остальные пункты общего плана продолжаются в существующих задачах Linear.

## 15 сентября — событийная готовность и живая дальняя страница (GUI-200)

Следующий законченный срез выполнен поверх интегрированного `e1c20f8`, в той
же рабочей папке и ветке. `DocumentWebCoordinator` завершает ожидание точной
версии событием, отменой или определённой ошибкой. Удалены отдельные циклы
готовности через 5 мс в владельце документа и 20 мс у производителя снимка.
Допуск WebKit остаётся у ресурсов; прежний срок выполнения координатора
начинается после фактического допуска, включая запуск оболочки. Старый флаг
`renderIsReady` без канонической квитанции не прекращает этот срок.

Для дальней ссылки на лист без программ подготовленный вспомогательный WK
сразу устанавливается в целевом контейнере и после нативного завершения
становится текущей бумагой. Два существующих координатора меняются ролями;
полноразмерного промежуточного снимка и второй JS-установки цели нет.
Идентичность завершённой потребности сохраняет цель до обновления SwiftUI.
Текущий ввод не отзывается ради подготовки; curl и срезы встроенных программ
сохраняют необходимый им снимковый путь.

### Выбранная проверка

Неизменные исходники:
`0309aa22cfc04fcd440033490fb5ea6436f1f5ee06ef802d82d2cb86f1404e45`.
`.build/document-live-handoff-v4/verification.json`: **45/45 Mac, 80/80 iPad**,
без пропусков и runtime warnings. iPad включает 79 native-проверок и один
настоящий UI-сценарий касаний дальней ссылки и возврата. Проверены исходная
геометрия и переиспользование измерения, передача того же WK/generation,
отсутствие закреплённого bridge-снимка, отложенное обновление текущей страницы,
замена цели при единственном доступном WK и отмена очереди при закрытии.
Пять новых проверок событийного ожидания выполнены на обеих платформах.
Проверка срока без канонической квитанции использует синтетически допущенный
WK; она не выдаётся за пользовательский жест.

Выбраны Mac `DocumentPresentationWaitTests`, `DocumentRuntimeTests`,
`DocumentTargetSnapshotPreparationTests`; iPad `DocumentPresentationWaitTests`,
`DocumentProgramOwnerTests`, `PageTurnSelectionTests`, `DocumentResourceLeaseTests`,
`DocumentShellPreparationTests` и UI
`DrawingResponsivenessTests/testDocumentLinksOpenTheMeasuredDistantPageAndReturnToContents`.
Команда `./verify.sh --only --test ...` и точные входы сохранены в квитанции.
Simulator: `CBDE7503-A0F7-4B92-85B5-626B9375E0FA`.

Предыдущий v3 дал 45/45 Mac и 80/81 iPad. Дополнительный обычный свайп
`testProseDocumentTurnsToDifferentTextAndBack` не перевёл первый лист на второй
за установленное время. Тот же неизменённый тест воспроизвёл **0/1** на чистом
`e1c20f8`: `.build/document-live-handoff-curl-baseline`. Сбой не скрыт изменением
жеста, ожидания или критерия; он остаётся открытым в GUI-200. Поэтому PASS v4
не является приёмкой обычного свайпа. Начальный v1 вообще не запускал тесты:
при двух загруженных Simulator требовался явный ID. v2 ранее прошёл 4 Mac и
54 iPad проверки; финальный результат относится к v4, а не их сумме.

### Частная Release-пара и большой документ

Из того же SHA собрана диагностическая Release-пара:
`.build/document-live-handoff-release/build.json`, `developmentBuild: true`,
`workingTreeUnchanged: true`. Обновлена только существующая изолированная
пара `d3f8489d-d961-46b1-8f07-3cc0cb89a795`, workspace
`488F89AC-396A-4750-887A-5505223664BC`, Simulator
`523B6568-8878-4FB5-B150-F2A577A3772F`. Квитанция продолжения подтверждает
`dataBytesPreserved: true` и `sameRuntimeAndIdentities: true`.
Рабочие Mac/физический iPad и исторические архивы не изменялись.

`testBigDocumentFullLifecyclePreservesActualSource` прошёл **1/1 за 107,152 с**:
холодное открытие → дальняя ссылка → возврат → правка настоящей клавиатурой →
Save → видимый сохранённый текст до закрытия → закрытие → холодное повторное
открытие → адресное чтение. Квитанция —
`.build/document-live-handoff-release/runs/d3f8489d-d961-46b1-8f07-3cc0cb89a795/ipad-testBigDocumentFullLifecyclePreservesActualSource-bcfdbe09-8db9-4d0e-90fb-fbdc4f7cff20/scenario.json`.
Просмотрены PNG дальней страницы и результата Save. Маркер
`Notebook UI edit B8FBF3A7-E437-4F41-8EE3-91A913A54A0F` виден вместе с прежним
маркером и формулами; адресное чтение подтверждает тот же `part-0`.

В одном проходе нативные request→installed интервалы: открытие **3482,91 мс**,
дальняя страница 35 — **439,93 мс**, возврат на 0 — **725,92 мс**.
`sourcePreparationMeasurement` остаётся **1** во всех трёх записях;
оболочки переиспользованы. Холодная подготовка: fontsReady 1051 мс,
typesetting 637 мс, sourceDOM 281 мс, fragmentIndex 67 мс.
Это не p95 и не системное измерение показанного кадра. Контрольный документ
сохранил предыдущую UI-правку, поэтому сравнение с одиночным Release-v3 не
считается строгим benchmark неизменного содержания. JSON:
`.build/document-live-handoff-release/lifecycle-attachments/5F93C588-598B-4E78-8A11-B1EB14BBC787.json`.

Ресурсный срез целиком не объявлен завершённым: отделение подготовки и её задач
от checkpoint программ, составной допуск и остальные UX-сценарии остаются
в существующих задачах Linear. Пороги, десять повторов, 30 минут совместной
работы, системные CPU/GPU/кадры/память и физическая приёмка не подтверждены.
Бюджеты не увеличивались; производственная установка не выполнялась.

## 15 сентября — единая ветка и разбор рабочих копий (GUI-204)

По прямому запросу Амира оставлены одна локальная и одна удалённая ветка
`codex/notebook-ipad-reliability` и одна рабочая папка — корень репозитория.
Удалены **77 worktree, 7 локальных и 5 удалённых веток**. Перед удалением
проверены ancestry всех именованных веток, эквивалентность 12 detached-коммитов
через `git cherry` и содержимое незакоммиченных файлов. Отдельных потерянных
коммитов не найдено. 38 лишних копий полностью покрывались текущим деревом
и его историей; остальные содержали главным образом прежние версии,
диагностику и промежуточные записи. В корне сохранён текущий общий срез.

Из отдельной копии подготовки документов перенесены **38 файлов исходников
и тестов точного Release v3**, а не её более поздняя незавершённая версия:
`759dea3e732c668dfc39f4a5d49b5025d772b8a27e77156a8fdf2110b6b16469`.
Включены компактное hash-bound чтение действий и индекс SQLite, явный спрос
страницы, адресное освобождение ресурсов, асинхронная очередь допуска,
сохранение владельца ввода и проверка видимого результата Save до закрытия.
Контракты чтения и фрагментов приведены к выбранной реализации.
Полная побайтовая сверка всех 841 входов общей копии и Release v3 показала
только три отличия: маршрутизатор проверки, его тесты и `full.sh` (GUI-203).
Продуктовые исходники и UI-сценарий совпадают; состав сверки сохранён в
`product-source-comparison.json`.
Поздний прототип архива канонических фрагментов не включён: его общая Mac
проверка не прошла. Прежние реализации не добавлены как параллельный fallback.

Из-за реального риска потери уникальных незакоммиченных черновиков перед
удалением создан **один архив 4 078 872 байта**, без сборок и зависимостей:
`/Users/amir/Documents/Notebook-worktree-recovery-20260915.tar.gz`.
SHA-256: `1378a1e01abd9ff070fcab2e57ce182ca9f2d85082ed77cd5cdbffa4fe354dbd`.
Он содержит binary patches относительно записанного HEAD, новые файлы и
manifest всех 78 исходных копий. Хэши сверены; перед удалением каждой копии
повторно проверено, что её содержимое не изменилось. Это возможность
восстановить черновик, а не дополнительная рабочая ветка.

Опись, побайтовый состав интеграции и результаты удаления:
`.build/worktree-consolidation-20260915/`.

Первый общий прогон дал 55/55 Mac и 132/132 iPad, но его итоговая квитанция
правильно отклонена: во время тестов другая активная задача начала следующую
доработку передачи страницы. Её дельта сохранена отдельно в
`.build/document-live-handoff.patch`; владелец временно восстановил проверенную
базу и согласовал паузу. Непроверенная следующая доработка не включена в
консолидацию. Повтор выполнен на неизменном общем срезе.

### Проверка интегрированного среза

Неизменные 841 inputs:
`116b60b13b41161c68af9595eec72288c76f3d2624ab7fe3bfa720840c0e7803`.
Selected-v2: **55/55 Mac native, 132/132 iPad native, 47/47 MCP,
10/10 Node, 70/70 проверки маршрута и 64/64 проверки выпуска**.
Native — без пропусков и runtime warnings. Команды завершились успешно,
source-before/source-after/текущее дерево совпали. Отдельно выбранные
**115/115 Core** проверили чтение действий, миграцию, SQLite, публикацию,
доставку и публичный протокол. Логи и результаты — в каталоге этой консолидации.

Эта область не разрешает выпуск всего широкого diff: `checked_verification`
отклоняет применение native-квитанции к изменённой общей UI-фикстуре без
выбранного жестового селектора. Ограничение не обходилось, receipt не менялся.
Доказательство настоящего пользовательского цикла выбранного продукта —
сохранённый Release v3 ниже. Дополнительный полный Swift-прогон остановлен
после шести минут на нагрузочных сценариях со 100 000 записями; полного PASS
у него нет. Для консолидации не повторяется вся длительная приёмка.

Упрощение GUI-203 и существовавший общий продуктовый срез фиксируются вместе
по запросу Амира. Непроверенная следующая доработка остаётся у своей активной
задачи и будет продолжена поверх этой же ветки после commit/push.

### Настоящий сценарий и граница результата

Выбранный продуктовый Release v3 ранее прошёл **1/1 actual Simulator UI**:
большой документ → дальняя ссылка → возврат → редактирование → Save с видимым
новым текстом до закрытия → закрытие → холодное повторное открытие.
При консолидации просмотрены оригинальные PNG Save и reopened editor;
они содержат тот же сохранённый marker, а не пустую страницу.
Квитанция сценария:
`/tmp/notebook-document-protocol-evidence/release-v3/runs/d3f8489d-d961-46b1-8f07-3cc0cb89a795/ipad-testBigDocumentFullLifecyclePreservesActualSource-9e8fdbbd-e3e7-41e5-9a41-e7c69b77c786/summary.json`.
Это сохранённый UI-прогон указанного продуктового среза, не новая физическая
приёмка финального commit. Десять открытий v3 **не прошли порог**:
cold p95 **4312,01 мс > 3000 мс**. Системные метрики, 30 минут совместной работы
и итоговая приёмка GUI-199/200/202 остаются открытыми. Установленные приложения,
пользовательское содержание, ключи и независимые исторические архивы не менялись.

## 15 сентября — упрощение выборочного маршрута (GUI-203)

`./verify.sh --only --profile verification` прошёл: **70/70** проверок выбора
и квитанций, **64/64** проверок выпуска. Неизменные build inputs:
`06cf3a88a69e1cd01e052c9b63d1582fb332e007f88eda23e7c9c8727aab0048`.
Квитанция: `.build/verification-simplification-gui203/verification.json`.
Это проверка инструмента выбора/выпуска, без запуска Xcode, приложений и UI.

Для одной правки `document-shell.html` план теперь выбирает четыре native-набора
и прежнюю команду JavaScript-контрактов вместо 28 наборов. Ближайшие native-тесты
находятся по имени файла без новой записи в карте; неизвестные области остаются
видимыми. Полный маршрут лишён шести проверок написания Swift-кода, но сохраняет
runtime/UI и настоящий безоконный Mac-запуск. `bash -n` и `git diff --check` прошли.
Правила явной области сведены в контракт выпуска; исторические результаты
сохранены и не являются дополнительными правилами.

Изолированный commit этого изменения пока не создан: оно пересекается с
незавершёнными изменениями маршрута, тестов и документов в рабочем дереве.
Результат относится к указанным входам, не к чистому commit, полной приёмке
или исправлению пустой страницы после Save. Установка пары не выполнялась.

## 14 сентября — исправления аудита, промежуточные результаты

Работа GUI-199/200/201/202 выполняется от `012921b7e8b6ac739c7492071f4ade91e23941e9`.
Эти результаты не являются полной приёмкой или разрешением установки.
Описанные ниже стендовые проверки сами по себе не разрешают обновление рабочей пары.

### Дополнение на 20:51 МСК — общий контрактный срез пройден

Неизменный `7a5631cdc3d34c3cf4897e9b99d8affe7cfa204c01ec401b7113dcec7d55e444`:
**109/109 iPad native +6/6 Mac native**, без пропусков и runtime warnings.
Семь iPad групп покрыли ресурсы, две исходные ошибки, lifecycle, реальный
WK/handoff, ссылки и выбор страниц; на Mac выполнен DocumentRenderSessionTests.
Тела обеих новых регрессий побайтно совпадают с отрицательным срезом0/2.
Исходники после прогона совпали с исходными835inputs. Квитанция:
`.build/bigdoc-v19-resource-rca/positive-native-v1/native-receipt.json`.

Общий срез включает finalnav, исправленный строгий барьер Far→return,
версионное удержание Picture и candidate-v4 подготовки ресурсов. Независимый
review закрыл R01 (заряд/атомарная передача временных данных) и R02 (сохранение
ожидающего второго host при закрытии измерительного). Восемь новых resource
контрактов прошли. Законно закреплённое окно четырёх страниц и его влияние на
задержки остаётся риском для actual сценария; бюджеты не повышались.
Private Release v20 строится из этого точного среза. Полный пользовательский
цикл, p95, системные метрики и обновление физической пары ещё не приняты.

### Дополнение на 20:23 МСК — доказанная причина пустой страницы после Save

Изолированная v19: source `a8ddbd4924f128d9e3a77b8e0f510bd62659508255281c692133fa348113e807`,
сборка на revision142b9f2. Обновление сохранило данные побайтно и прежние
идентичности. Actual `e86a91fe-8ef5-44d2-bdf2-2c8640f43df1`: **0/1 UI**,
104.658s, без пропусков и runtime warnings. Открытие, дальняя ссылка, возврат и
реальный ввод выполнены. После Save строгая проверка ждала введённую строку
на текущей бумаге до закрытия; она не появилась. Root просмотрел настоящий
PNG: пустая страница и сообщение подготовки с Retry.

Observer72d2c7bb…, seq531: source_announcement нового A708… требует13841816байт,
при pinned133240928 и reserved103305 в passive quota134217728. Доступно873495.
Все четыре удержанных растра имеют прежний source token1@EC2…, тогда как
новые presentation entries уже не могут их использовать. `trim` сохранял
Picture по номеру страницы; источник после отказа сохранял resourceLimit,
возвращая его ещё46раз без новой попытки allocation. Это доказанная причина
Save-блокера; отдельный v18 snapshot_pending ей автоматически не объясняется.
Точные holders и журнальные хэши: `.build/bigdoc-v19-resource-rca/cause-and-contract.json`.
Исправления lifecycle и ограниченного ожидания ресурсов готовы; native и
полный повтор ещё не завершены.

Отрицательный срез `6c65ad6857fb3fd257c991c9cc52afc0bf5c0c4efcea972e4f3280d2c2482478`
с двумя новыми тестами и неизменным продуктом v19 дал ожидаемые **0/2**:
после замены источника5233280байт Picture остаются закреплены; настоящий WK
после освобождения блокирующих ресурсов остаётся без canonical page и возвращает
resource_limit. Нет ошибок подготовки fixture/unwrap, пропусков или runtime
warnings. Исходники до и после совпали. Квитанция:
`.build/bigdoc-v19-resource-rca/negative-native-v1/negative-receipt.json`.
Независимый review новой очереди выявил ожидание после материализации неучтённых
временных буферов; этот пробел устраняется до положительной сборки. Ранний
candidate-v2 не считается проверенным исправлением.

Публичное чтение через actual private v19 Mac подтвердило точный marker
`Notebook UI edit 8581F897-3E67-4A70-8521-17BB864A544E`, введённый перед
визуальным отказом Save. Run `df12409f-7a4e-43a8-8d5b-f084d7f779fb` completed,
effects пусты; human sourceVersion actorEC2…/counter2, cursor104931.
`.build/bigdoc-v19-public-read/verified-source-witness.json` доказывает запись
и репликацию, а не установленные пиксели. Текст тестового сценария не утрачен.

Непрозрачный editor root и независимый помощник проверили по оригинальному
D2886B48…PNG: соседние абзацы не видны через поле. Узкий `fd95139` отправлен;
область доказательства в `document-editor-opacity-verification.md`.
Native навигации910467…:68/69PASS. По test activities, PNG и прочитанному JS
единственный отказ классифицирован как преждевременный барьер теста передачи:
Far snapshot готов, скрытый WK ещёpage0. Новый барьер требует canonical paper,
native input и отсутствие fallback, сохраняя итоговые page/token/identity asserts.
Это исправление теста; риск input в промежутке передачи отдельно не принят.

Единичные native длительности v19: cold5260.28ms, distant4233.18ms,
return7772.74ms. Привязка перепроверена по requestID/cause/pageIndex оригинальных
XCTest attachments (20:26 МСК); ранее cold и return были переставлены при
переносе статуса. **Не p95 и не системная трассировка; пороги не пройдены.**
Производственная пара не обновлялась. Просьба установить как можно скорее
исполняется после обязательных условий приёмки, с сохранением данных и доверия.

### Дополнение на 19:53 МСК — повтор выявил отдельный отказ возврата

Усиленный actual v18 `695f3ceb-e904-4195-b383-d05504bf069b`: **0/1 UI**,
185.122s. Открытие и дальняя ссылка прошли; возврат остановился до редактирования.
Native journal seq302 фиксирует `snapshot_pending` для принятой цели0, с
непустым demandID и `taskCancelled=false`; перед этим соседи33/36 получили
`resource_limit`. Эти события не объединяются в одну доказанную причину.
Root просмотрел снимок после отказа: всё ещё Chapter133…136 и счётчик1/37.
Контракт intent/actual исправляется у native page controller и модели.

Диагностический сбой сценария отделён: после30s ожидания тест дополнительно
запрашивал `app.debugDescription`; сбор полной AX-иерархии занял примерно90s.
В следующем UI-срезе отказ сохраняет bounded native records и настоящий PNG;
условие наличия фактически установленной страницы осталось прежним.

Независимая проверка сохранения прошлого успешного цикла через два публичных
MCP-инструмента завершена: `nb.document({id,blockID:"part-0"})` вернул точный
маркер, введённый в Simulator, `sourceVersion.human=true`, actor iPad/counter1.
Запуск completed, effects пусты. Квитанция: `.build/bigdoc-v18-public-read/verified-source-witness.json`.
Это доказывает запись и доставку текста на Mac; показ новой страницы до закрытия
и временные пороги этим чтением не подтверждаются.

### Дополнение на 19:47 МСК — полный цикл выполнен, готовность не достигнута

Actual v18 `13fb85af-0e31-4acd-b00d-12a7985ffe89`: **1/1 UI PASS**,123.342s,
без пропусков и runtime warnings. Реальные ссылки0→35→0, редактор с экранной
клавиатурой, Save, закрытие, завершение приложения, повторный запуск и чтение
точной введённой строки выполнены. Source/build — тот же `1504a412…`,revision142b9f2.
Единичные native-измерения: cold5167.731ms, distant4121.595ms,
return6543.031ms, reopen4150.323ms. **Это не p95; временные критерии не пройдены.**

Ограничение этого PASS: тест закрыл документ после исчезновения редактора и
не требовал появления сохранённого текста на ещё открытой странице. Журнал
содержит `resource_limit` при подготовке соседей и повторно для текущей
страницы0 нового источника после Save. Точный этап отказа и удерживающий
ресурсы владелец ещё не установлены. Усиленный повтор требует видимого
сохранённого текста до закрытия; вывод о живом показе пока открыт.

Root просмотрел оригинал `6085C372-A84D-4575-BDF1-4CAD33E84B51.png`:
сохранённая строка видна в повторно открытом редакторе, но соседний Chapter1
просвечивает сквозь textarea. Причина в `.source-editor` background alpha0.7.
Фон исправлен на непрозрачный в рабочем дереве; установленный v18 не менялся,
повторная визуальная проверка относится к следующей сборке.

### Дополнение на 19:33 МСК — доказанный приоритет и оставшийся блокер возврата

Полный actual v17 маршрут `0f489cfe-6633-4719-8b68-fd6f710a7d6b`:
**0/1 UI**,93.503s. Открытие4323.208ms и дальняя ссылка4619.477ms выполнены;
возврат не получил canonical/capture. XCTest завершился ошибкой remote AX,
но native journal независимо показывает незавершившуюся страницу0 и дальнейшее
игнорирование цели. Тип underlying error старый журнал не сохранил.
Root просмотрел фактический экран после отказа: Chapter133…136 остались,
счётчик уже1/37. Ошибка скрыта в host ещё не показанной страницы. Редактирование
и повторное открытие этим маршрутом не проверены.

Контроль влияния XCTest `d0f570bf-94dd-455f-99d2-d3810ffd436d`: **1/1 UI PASS**,
без skips/runtime warnings; восемь секунд без AX-обхода после открытия,
измерение по собственному native recorder — **5018.070ms**. Тихий интервал не
вычитался и не использовался как время установки. Это диагностический
единичный результат, не p95. Основная cold-задержка не исчезла. Исходный PNG
просмотрен, формулы и текст чёткие.

Приоритет принятой страницы, неизменный `ad0a9697…`: **50/50 native PASS**,
0skips/runtime warnings. Старый владелец на том же fixture получил ожидаемый
**0/1 FAIL**: queued page1 вместо demanded page4 до освобождения реального
второго WebKit admission. Native receipt и хеши source-before/after сохранены
в `.build/document-navigation-priority-v1/positive-v1/native-receipt.json`.
Независимый обзор пяти связанных файлов замечаний не выявил.

Собран документный v18, source `1504a41289cc91b82f5bb420443cf333fe6449b670533172e41519bc9fb9501e`,
834файла, build revision142b9f2, developmentBuild. Он содержит v17 + приоритет,
ограниченный opt-in классификатор терминальной ошибки и полный UI-маршрут.
Не связанные изменения доставки в эту сборку не вошли. Новая полная проверка
маршрута ещё впереди; source/error/presence projection не объявлены принятыми.

### Дополнение на 19:15 МСК — последовательная приёмка большого документа

По уточнению Амира первым полностью закрывается маршрут открытия большого
документа, дальней ссылки, возврата, редактирования, закрытия и повторного
открытия. Короткий реестр причин, гипотез и очереди — в
`implementation-2026-09-13.md`. Незаконченная полная приёмка не подменяется
количеством контрактных PASS. Root — единственный Xcode/Simulator runner;
не более двух помощников заканчивают ограниченные начатые участки.

Actual v17 `ipad-testWidgetTextReplacementUsesNativeSelectionMenu-52be9067-7a80-4d96-a851-35226c824ae8`:
**1/1 UI PASS**, без skips/runtime warnings. Нативный caret → меню → Select All
→ ввод сохранил точную строку `Native selection 60ce778e-0251-4ddf-95b5-63d99fc89297`
в immediate и subsequent AX. Одно последующее нажатие изменило count12→13,
текст сохранился. Это проверка поведения, не измерение отклика≤100ms.
Исправление доступности companion при клавиатуре отдельно зафиксировано и
отправлено как `142b9f2`; установленный v17 по-прежнему имеет исходный
build revision `8832ee3` и hash `f5a5b4a0…`, более поздний commit ему не приписан.

Коррекция независимого визуального чтения: последние формулы на дальней
странице **полные**, исходный PNG и реальные размеры это подтверждают.
`.build/document-inline-math-v17-rca/review.json` сохраняет причину исправления
прежнего ошибочного вывода. Перекрытие Source136 перемещаемым companion —
отдельное наблюдение; доступ к строке проверяется реальным перемещением окна.

### Дополнение на 19:03 МСК — фактические этапы документа и текста

V17 big document: **1/1 UI PASS80.277s** на ссылках0→35→0, source/runtime/
coordinator сохраняются. Измерения отдельных переходов: cold4858.831ms,
distant4312.939ms, return9004.406ms; **пороги не пройдены, это не p95**.
Return request→demand8771.055ms, demand→installed233.352ms. Native journal
показывает `passive_target_not_ready`: перед принятой целью0 выполнялась
подготовка старого соседа34. Исправляется явный приоритет принятой навигации.
`.build/bigdoc-v17-readiness/actual/analysis.json` связывает новые фазы,
идентичность и неизменные source/PNG. Reader первоначально спутал старую
launch-configuration revision с actual native revision; проверка разделена,
native hash/session/device guards сохранены. First/return PNG побайтово
одинаковы; все три просмотрены. Независимый reviewer отметил обрезание формул
справа на дальней странице; причина ещё проверяется.

В native text scenario первые long-press оказались постановкой курсора.
Исходное действие XCTest било в верхний угол поля+5pt; явный контакт на строке
переместил курсор. Следующий настоящий tap по курсору открыл системное меню,
Select All выделил весь текст. Затем immediate AX не содержал последний
символ; прежний FAIL сохранён (`ipad-testWidgetTextReplacementUsesNativeSelectionMenu-6ae57fc5…`).
Независимый публичный run `f47de8b8-8a11-44c7-a979-facf2ca13b16` подтвердил
полную фактическую строку и human stamp229, count12. Проверка теперь сохраняет
immediate/subsequent AX и требует точный окончательный текст без повторного
ввода; это не измерение100ms отклика. `.build/widget-native-text-v17-final-character`.

### Дополнение на 18:53 МСК — установленный v17 и клавиатура

Изолированная пара v17 собрана из неизменного `f5a5b4a0…`, обновлена с
побайтовым сохранением данных и прежних идентичностей. Публичный context
подтвердил `ready/connected`. Рабочая установленная пара не обновлялась.

`testCompanionRemainsReachableWhileWidgetKeyboardIsOpen`:
**1/1 UI PASS**,24.454s, без skips/runtime warnings. Actual compose заканчивается
на763pt, клавиатурная панель начинается на843pt; нажатие открывает чат,
рисовальная поверхность остаётся820×1180pt, текст поля сохранён. Исходные
PNG просмотрены root и независимо; `.build/keyboard-companion-v17-independent-review`.
Пустое окно со spinner на снимке сразу после нажатия — только наблюдение
начального состояния загрузки, не проверка получения содержимого разговора.

Настоящий long-press и замена текста через системное меню **0/1 UI FAIL**,
26.030s (`ipad-testWidgetTextReplacementUsesNativeSelectionMenu-b487a5fa…`).
Фокус и клавиатура есть, меню Select All не появилось. На исходном PNG после
long-press нет прежних синих ручек выбора всего виджета; AX Selected сам по
себе не доказывает нового выделения. Причина оставшейся границы исследуется;
полный конфликтный сценарий не объявляется прошедшим.

### Дополнение на 18:45 МСК — сохранение владельца открытой страницы

Положительный срез `.build/document-current-gap-v1/positive-v1`, source
`2c6fa2637c95dfac6807c0283edd1996c28433d8b47f5eff5bc1df02d64bc4bb`:
**39/39 native iPad Simulator PASS**, без skips/runtime warnings,128.168s.
Проверены промежуток без текущей страницы, сохранение именно того же WK и
JS-состояния, закрытие с оставшейся миниатюрой, leases и активация ссылок.
Source-before и source-after совпадают; `native-receipt.json` связывает
результаты и исходные attachments. Независимое runtime-ревью замечаний не нашло.
Это контракт владельца, а не ещё одно измерение исторического20.4s возврата.

Для установленного повтора заморожен интегрированный v17,834файла, source
`f5a5b4a0c672572a815427ce0da29e40b0847ea1db47937a797f124cf218ddd0`.
В него входят исправления selection ownership, keyboard safe area, Mac producer,
срока жизни страницы и пассивные измерения стадий WebKit. Probe прошёл Swift6
semantic check; исходная ошибка преобразования optional CGFloat сохранена
отдельно и исправлена. Сборка и настоящие касания ещё не являются PASS.

### Дополнение на 18:30 МСК — проверенные квитанции совместной работы

После UI FAIL агент сам завершил настоящий разговор. Root прочитал четыре
его прежних запуска через публичный `resume` (без повторения программы) и
сверил исходную SQL-квитанцию, настоящий объект ошибки, эффект CAS `notSaved`,
undo и текущее состояние. **CAS отклонён с тем же expectedA**, undo
`restored=0/preservedCount=1`; count12 и фактический составной текст совпадают
с исходной ошибкой XCTest. Внимание осталось count11, исходный PNG просмотрен,
SHA `266792e0d5b77fed458325a5148e10c4808c0f153d9800a2d0d294839c166320`.
`.build/collaboration-v16-conflict-public-audit/verified.json` содержит хеши
всех ответов и проверяющего кода. Saved и receivedByIPad подтверждены;
shownOnIPad остаётся `awaiting_display`. Неизменный human результат виден в
последующих исходных PNG/AX, однако это не изготовленная квитанция показа undo.
Полный UI-сценарий по-прежнему FAIL на замене текста. Попытка отдельной отмены
пришла после завершения: stop отсутствовал, **отмена не выполнялась**.
Наблюдение уже завершённого разговора — отдельный1/1UI PASS.

Mac producer v6: **18/18 native PASS**,0skips/runtime warnings,27.158s,
`.build/document-target-preview-owner-v6/verification/mac-summary.json`.
Исходники приложения/ Core те же, что v5; исправлены только ошибочные fixtures.
Очередь, отмена, настоящие ошибки WebKit и сохранённые lease pixels входят
в выполненную область. Итоговая пара и реальный публичный повтор впереди.

### Дополнение на 18:24 МСК — обнаруженные границы ввода и жизни документа

Настоящий v16 конфликтный сценарий дошёл до записи агента и human count11→12,
но остановился до CAS/undo: `Cmd+A` не заменил содержимое поля, фактический
текст стал `Human edit <nonce>Agent ready <nonce>`. Nonce
`fb8d76f1-fc3a-4770-9fbc-d4396e58eb87`, thread
`01a0a078-a7ff-7c71-ace1-5b87a5f672da`. **0/1 UI, 163.542 s**,
`ipad-testConcurrentHumanStateRejectsStaleAgentWriteAndSurvivesItsUndo-ae17e95f-3aed-46bd-b9a9-972226c25532`.
Восстановление через настоящий long-press поля также FAIL: меню выбора текста
не появилось, выбран весь виджет. Публичный context создал новую ссылку на
`acceptance-controls` в момент этого long-press (context `E2534C30…`).
Это дополнительный реальный маршрут для готового исправления selection ledger;
повтор на новом приложении требуется. Ни CAS, ни undo этим проходом не доказаны.

Отдельная проверка доступности чата с клавиатурой дала ожидаемый **0/1 UI**:
`ipad-testCompanionRemainsReachableWhileWidgetKeyboardIsOpen-818302cb-7839-4ae6-a457-085ad6ab56ac`.
Кнопка заканчивается на1080pt, клавиатура начинается на898pt; доска не изменила
размер. `NotebookRootView` больше не исключает компактный чат из keyboard safe
area; геометрия доски остаётся отдельной. Положительный установленный повтор
ещё не выполнялся.

Нативный промежуток `retire → yield → drain → select`: первый v2 дал3PASS/1FAIL
с нелокализованным `InvalidTransition`. Следующий test-only diagnostic v3
подтвердил **другой ObjectIdentifier у фактического WK** после промежутка;
затем чтение JS нового ещё не готового runtime вернуло WKErrorDomain4.
`.build/document-current-gap-v1/negative-v3-diagnostic/native-attachments`.
Старое passive-ready значение не является доказательством готовности этого WK.
Исправляются срок жизни full document presentation и строгое ожидание actual
canonical surface перед проверкой JS. Предыдущая неясная ошибка не объявляется
задним числом доказательством той же причины.

Mac producer v5: **16 native PASS / 2 FAIL**,0skips/runtime warnings.
Один fixture передал referenceRevision вместо требуемой contentRevision и
завершился до запуска publisher; cleanup маскировал setup error. Второй читал
ещё не загруженное тело закрытого документа. Эти fixtures исправляются с
сохранением checks очереди, ошибок и конкретных retained red/blue pixels.
Результат v5 не является PASS очереди под нагрузкой.

### Дополнение на 18:08 МСК — реальные жесты и владение вводом

Private v16: настоящий pan из свободной области, два первых нажатия кнопки
9→10→11, slider и ввод с экранной клавиатурой прошли **1/1 UI, 44.985 s**.
`ipad-testCameraAndFirstTouchControlsOnAgentMaterial-5709e518-a4ed-4f53-a149-2cfdd977b0f1`.
Первый маршрут начинался в 16 pt от края экрана и не передвинул сцену;
он сохранён как FAIL. UI runner выбирает свободную точку с отступом 44 pt,
сохраняя проверку точного смещения, исходную продолжительность жеста и
геометрию исключённых элементов. В успешном проходе AX показал смещение
(-30, +21.5) pt при запросе (-30, +21.25), затем (+25, -15) pt.
Это проверка геометрии, не доказательство покадрового совпадения SVG.
Pinch этого сценария попал на готовый slider и изменил его значение;
изменение масштаба камеры этим действием не подтверждается.

Отдельный реальный pinch 0.8 на закрытой обложке прошёл **1/1 UI**:
`ipad-testClosedDocumentCoverPinchChangesSceneScaleWithoutOpening-4c2c0dec-d88c-49d3-ab37-7dd186b08b1c`.
Ширина 590.487→476.520 pt, пропорции сохранены, документ не открыт.
Root просмотрел оригинальные PNG до/после: заголовок чёткий, обложка цела.
Десять повторов и совместный сценарий controls после этого масштаба ещё впереди.

Новый публичный запрос изображения созданного агентом документа после
пользовательского count 1 завершился ready за **524.265 ms**. PNG 1091×1543,
SHA `9dddd7c13c183e14a0edc85d894144803c60a34caa72bad225e62c390e988ebe`,
просмотрен; `.build/collaboration-v16-public-audit/render-response-2.json`.
Это отдельный запрос `006747F2-8CA7-4C88-8415-5048F2EB1A23`, до нового
исправления Mac producer; прежняя ошибочная квитанция v15 сохранена.

Выделение: old native **0/2 PASS**, оба контракта воспроизвели параллельный
захват контакта готовой программы и потерю исходного владельца при reparent.
Исправление `NotebookSelectionGesture` использует существующий контактный
ledger: неизменный положительный source `ea5f6369…` прошёл **7/7 native**,
0 skips/runtime warnings, 40.260 s. Между отрицательным и положительным
срезами меняется только этот файл приложения; тесты одинаковы.
`.build/scene-selection-input-owner-v1/positive/verification`.
Настоящий UI-контракт отсутствия побочного выделения на новой паре ещё открыт.

### Дополнение на 17:55 МСК — v16 и первый реальный ввод

Private Release v16 собран из той же проверенной копии `bb61dd79…`:
`.build/public-sdk-acceptance-v16/build.json`. Обновление сохранило байты данных
и идентичности пары; публичный context вернул ready/connected. Рабочая пара
и физический iPad не обновлялись.

Продолжение настоящего разговора открыло ранее созданный документ и выполнило
первый тап кнопки: **1/1 UI PASS, 28.223 s**, count 0→1, отсутствует 2.
Оригинальные PNG и XCTest событие просмотрены root и независимым рецензентом:
`.build/collaboration-v16-first-touch-independent-review/review.json`.
Публичное чтение после жеста подтвердило count 1, `human:true` и версию состояния
`1@ec2ab92d-5490-4fa3-948d-0d90762d9d96`. Квитанция saved/received/shown
действия создания относится к прежней версии создания, а не к новому тапу.
Новый показ подтверждают именно PNG/AX; сохранение и доставку состояния —
последующее чтение документа. Первичный v16 запуск остановился до тапа:
восстановленный документ не содержит счётчик доски, ожидавшийся тестом.
Исправлен только diagnostic UI runner; полный E2E сохраняет проверку доски.
Предыдущие FAIL не заменены этим частичным продолжением.

Большой документ: **1/1 UI PASS, 83.342 s** для открытия и двух настоящих ссылок,
но **скорость не принята**. Нативные request→installation: холодное открытие
5082.318 ms, дальняя страница 4038.652 ms, возврат 20415.843 ms.
`.build/bigdoc-v16-readiness/{records,analysis}.json`.
Первые две установки используют тот же coordinator/runtime/source; возврат
создаёт все три заново и повторяет измерение содержания. Предварительная
гипотеза — промежуток удаления старого и объявления нового текущего host;
дополнительный жизненный контракт и наблюдение готовятся. Это три отдельных
образца, не p95. Порог 3000/300 ms не выполнен.

Mac-опыт `.build/document-target-preview-native-v2` подтвердил ошибку срока
до admission: запрос встал в очередь через 10.2 ms, завершился `pending` через
8012.2 ms, ресурс освободился лишь через 8274.1 ms. Из пяти тестов три PASS,
два FAIL: ожидаемый queued negative и неправильная тестовая проверка return
`setActivationPolicy`. Фактический accessory режим без видимых собственных окон
снимок получил за 522.9 ms; плотность 1 совпала. Исправляется producer lifetime,
а не увеличивается внешний timeout. Это ещё не доказательство причины
исходного v15 тайм-аута при реальной нагрузке.

Регистрация browser-проверок: `.build/document-browser-profile-v3/receipt.json`,
65/65 контрактов маршрута и 9/9 Node cases. Перенос одинаковых проверенных
исходников допускается; пропуск любого из трёх browser scripts отвергается.

### Дополнение на 17:38 МСК — общий нативный срез документов

Неизменная копия `.build/document-input-images-native-v1/source`, SHA
`bb61dd79e7a13018e10b2950948a05596039f3735b20058263d4fec5cf6990ad`,
прошла **72/72 iPad native**, без пропусков и runtime warnings, 99.188 s.
Это десять выбранных наборов геометрии, готовности изображений, оболочки,
ссылок, программ и удержания ресурсов; точная область хранится в
`verification/completed.json`, результат — в `verification/ipad.xcresult`.
Из этой же копии собирается изолированная Release v16 для настоящих жестов.
Нативный PASS не закрывает первый тап, дальнюю ссылку или пороги задержек.

Отдельный положительный опыт канонических bounds завершился **68/68 PASS**,
0 skips/runtime warnings (`.build/document-canonical-size-native-v2-positive`).
Между его отрицательной и положительной копиями единственное изменение
приложения — `PhysicalWebViewport`; старый путь возвращал DOM 0×0 до окна.

Mac preview: два настоящих нативных захвата v15 с диагностическим тестом
прошли, 481.418 ms для свежего текста и 154.401 ms для точного исходника
созданного счётчика. Текст и счётчик на оригинальных PNG просмотрены;
требуемая, оконная и фактическая плотность в обоих случаях равны 1.
`.build/document-target-preview-native-v1/attachments`. Это опровергает
постоянный отказ самого содержания, но не объясняет прежний реальный
8.577-секундный тайм-аут. Проверка очереди и состояния окна продолжается.

Справка JavaScript теперь явно описывает UUID `run_id` и обязательные версии
доски и пространства при создании документа. Девять контрактов публичного API
прошли, включая покрытие 19 операций и возможностей прежних 21 инструментов:
`.build/sdk-create-owner-help-tests.log`. Проверка новым независимым агентом
на итоговом установленном срезе остаётся открытой.

### Дополнение на 17:24 МСК — реальные результаты продолжения

Исходный разговор v15 завершился после обычного разрешения Notebook на этот
чат. `resume` его запусков подтвердил единственную принятую транзакцию
`4F5DCE76-BC6E-41A0-86F2-E28474CA57F8`, созданный документ
`AD1BEA1A-55B2-408C-83EF-B28E9553F78E` и доставку на iPad. Повторное публичное
чтение внимания после завершения вернуло байт-в-байт прежнее изображение
`e5f2c8deb91e431a507e1d6fb292d13bca71ab58053067ae15bfab9021be791d`;
на просмотренных исходных пикселях count 8, после реального нажатия — 9.
Доказательства: `.build/collaboration-v15-public-audit/public-review.json`.
Наблюдение завершённого разговора — 1 UI PASS; это не отменяет предыдущий
тайм-аут полного E2E на ожидании разрешения.

Отдельное продолжение открыло созданный документ поиском и двойным нажатием.
Настоящая кнопка существует и доступна для hit-test, но её первое нажатие
**FAILED**: count остался 0, появился контур выделения блока и контекст 1.
Снимки до/после просмотрены; выполнение 48.462 s. Сценарий
`ipad-testUseCreatedDocumentFromTheExistingRealConversation-5a5a75a2-da68-483c-b4dd-cb8bc783ca42`
сохраняет XCTest, AX, события и видео. Предшествующий запуск того же продолжения
не дождался загрузки transcript и не дошёл до документа; он также сохранён.
Это открытый дефект ввода v15; подготовленные source-исправления ещё не
проверены на новой установленной паре.

Mac-снимок этого документа: реальный запрос `E32247A0-DC35-4490-8CC4-3051F340E53D`
перешёл из pending в ошибку `render_error: pending` через 8.577167 s.
Повтор вернул ту же окончательную квитанцию. Причина незавершённой подготовки
проверяется отдельным нативным опытом; увеличение тайм-аута не является исправлением.

Опыт с канонической геометрией подтвердил настоящий DOM viewport 0×0 вместо
240×320 до установки WKWebView в окно: 1 ожидаемый отрицательный FAIL,
0 skips/runtime warnings. `.build/document-canonical-size-native-v1-negative`.
Исходная 66/1 проверка common shell и последующая 2/2 диагностическая проверка
не подменяются этим доказательством: причина того редкого отказа не была записана.
Исправление владельца bounds проверяется на отдельной неизменной копии.

Противоречие `source_pixels` вместе с причиной `source_pixels_unavailable`
устранено при создании нового `AgentPinnedSource`: `8832ee3`, commit и push.
Три Core-теста (в одном два аргумента) прошли; изображение/ссылка сохраняются,
исторические записи не переписываются. Лог `.build/pinned-source-visual-contract-tests.log`.
Маршрут documents теперь включает новые проверки shell/image/viewport/opening;
63 проверки самого маршрута PASS. Полная приёмка и физическая установка не выполнены.

### Дополнение на 17:04 МСК — нативная передача и совместный сценарий

Создание нового разговора по квитанции зафиксировано и отправлено в
`f294c08`. Только три файла этого поведения вошли в коммит; другие изменения
сохранены. Его native-проверка — 11 PASS в ранее указанной общей копии.
Настоящий v15 открыл новый разговор `01a0a02c-299a-74a1-9a43-3dcf4d5f27c5`,
выделил область и отправил сообщение. Пока Codex выполнял ход, реальное
нажатие изменило count 8→9 ровно один раз. Исходный E2E **FAILED** на ожидании
ответа: агент ждал штатного разрешения Notebook MCP. Доступ к этому инструменту
на весь тестовый чат принят отдельным настоящим UI-сценарием: **1/1 PASS**,
14.668 s, 0 skips/runtime warnings. Это не завершение исходного E2E.
Параметры запроса сохранены в его XCTest attachments; начальный запрос был
чтением `nb.help`, не доступом к файлам, сети или глобальной конфигурации.

Slider-origin pinch v15: **1/1 UI PASS**, 25.877 s. Снимки до/после просмотрены:
значение 74→50, count 8 и текст не изменены, AX-геометрия виджета совпадает.
`.build/v15-control-geometry-ui-v1/actual-slider-review.json`.
Это владение реальным жестом виджета, не измерение FPS/пиксельного смещения
или pinch, начатого на пустой доске. Предшествующий FAIL подготовки сохранён:
полноэкранный inward pinch начинался на панелях управления; actual controls
были видны, за область helper выходили пустые HTML-поля.

Common-shell/input native-копия
`fb8bb6241299a9e13866add053eb5dc1501aea46f3374a34e405ddd9099427f0`:
**66 PASS / 1 FAIL**, 0 skips/runtime warnings. Все 17 DocumentProgramOwner,
включая три новых admission-контракта, прошли. Не прошла передача уже готовой
общей среды в `testCurrentPageAdoptsTheSameReadyCoordinatorWebAndAdmission`;
сохранены все шесть assertions этого случая, причина исправляется.
`.build/document-common-shell-native-v1-positive/{summary.json,tests.json}`
и `verification/ipad.xcresult`. Независимое ревью также выделило отдельную
непроверенную границу доставки DOM-активации после native touchesEnded;
её нельзя считать закрытой этими admission-тестами.

### Дополнение на 16:42 МСК — v15, показ страницы и фактический ввод

Private Release v15: `cbd37fdf475a527bf83389d6fcd98e88ca9bf9def2110c754e12e738c9200f2b`,
base `f6cf783d371cd1297de32520ea1d70a344bbf6dd`. Upgrade сохранил данные и
идентичности. Публичный context подтвердил ready/connected. Это диагностический
срез, а не окончательная приёмка. Физическая пара не обновлялась.

Перед сборкой завершены независимые native срезы: передача живой страницы и
освобождение её ресурсов **30/30 PASS**, создание нового разговора по квитанции
**11/11 PASS** на общей копии `6647965a09ccf2e2e4ef9044c5f049513e5867d4e90651626e09d5329b426c41`.
Адресный запрос тела при принятом открытии: **38/38 native PASS**, 0 skips/runtime
warnings, плюс **4/4 CPU**; отдельный старый путь воспроизвёл ожидаемый FAIL.
Квитанции: `.build/document-paper-handoff-native-v6-integrated/final-review.json`,
`.build/document-opening-v5/receipt.json`.

Первое реальное открытие v15 показало страницу за **5905.997 ms** против
7147.430 ms в одиночном v14. Запрос→подготовка сократился с 721.311 до
118.748 ms. Это один образец, не p95; порог 3000 ms не выполнен. Интервал
ожидания pageReceipt WebKit составил 702.677 ms, последующее native принятие
разбивки — 0.146 ms. Этот интервал включает очередь WebKit, установку страницы,
два requestAnimationFrame и доставку ответа, не измеряет отдельно задержку rAF.
Исходные страницы v14/v15 просмотрены: тот же текст и формулы первых трёх
глав, без обрезания; первый SVG находится в следующем блоке.
`.build/bigdoc-v15-readiness/receipt.json`.

UI сценарий остановился **до** тапа по дальней ссылке: ссылка видна на снимке,
но отсутствует в доступном дереве WebKit. Отдельный диагностический runner
сохранил открытое приложение и выполнил настоящий тап по видимой ссылке
(160, 178 pt). Переход не произошёл; вместо него появился контур выделения
текстового блока и счётчик контекста. Оба оригинальных PNG просмотрены.
`ipad-testInspectDisplayedDocumentAndTapVisibleFirstLink-4a84fa52-85f8-4a5a-bde8-c39dd7396714`
под `.build/public-sdk-acceptance-v15/runs/4c1fd55e-5621-4b53-b490-d688e2cf9249/`.
Это подтверждённый отказ пользовательского действия, не только AX-query.

Кодовый разбор выявил необновляемое разрешение ввода у уже установленного
WebKit при переходе entry.isInteractive false→true. Самые ранние значения
этого флага в сбойном v15 не записаны; причина исправляется и будет проверена
на том же runtime без пересоздания, а затем настоящим тапом. Установленное
изображение само по себе не подтверждает рабочий ввод. Дальние и тёплые
переходы v15 пока не приняты.

### Дополнение на 16:21 МСК — v14, передача страницы и владение касанием

Private Release-пара v14 использует 820 неизменных входов,
`78ce2faa655f96ce43eb2388e639d5971213f17248c6234baeda7dfdbe8462ec`,
base `f6cf783d371cd1297de32520ea1d70a344bbf6dd`. Upgrade сохранил данные
и identities. На этой же копии завершён профиль очереди сохранения:
**32/32 native PASS**, 0 skips/runtime warnings; `.build/persistence-fence-native-v1/receipt.json`.

Настоящее открытие контрольного документа v14 заняло **7147.430 ms** — один
образец, не p95. Запрос→подготовка 721.311 ms; допуск WebKit→готовность общего
shell 2478 ms; подготовка исходного документа 2814.237 ms, внутри неё
`fontsReady` 1613 ms. Последняя фаза включает layout и не доказывает ожидание
сетевого шрифта. Полная адресная карта: `.build/bigdoc-v14-readiness/records.json`.
Дальняя ссылка теперь действительно открыла страницу **36 из 37**, но показала
ошибку immutable source/state. Журнал подтвердил уничтожение прежнего paper WK
между снятием старого host и установкой нового. Передача того же WK между host
проверена **29/29 native PASS** (`.build/document-paper-handoff-native-v2-positive/`);
дополнительный lifecycle освобождения при отказе запаркованного WK ещё проверяется.
Это не завершённая приёмка большого документа и не выполненный порог 3 s.

Два самостоятельных цикла настоящего касания поля и печати уникальной строки
на v14 прошли **1/1 UI PASS**, 29.150 s, 0 skips/runtime warnings. Оба immediate
и subsequent AX-чтения содержат полные строки; исходные PNG показывают
чёткий виджет, клавиатуру и курсор. `.build/v14-input-observation-ui-v1/visual-review.json`.
Отдельный camera/controls сценарий v14 остановился раньше печати: первое
нажатие не изменило счётчик. Координата XCTest находилась левее более позднего
AX-frame кнопки, но в видео есть разрыв 5.512 s и нет достаточной привязки
кадра к DOWN. Причина этого конкретного нажатия **не установлена**.

Для конфликта двух пальцев и живого виджета подтверждена другая причина:
камера допускала уже принадлежащее элементу касание. Исправление хранит
владельца контакта до end/cancel; обычная бумага сохраняет допуск камеры.
**5/5 native PASS**; отрицательная копия **4 PASS / 1 ожидаемый FAIL**,
0 skips/runtime warnings. `.build/native-contact-ownership-v1/native-result.json`.
Настоящие жесты после этой правки ещё не проверены.

Сквозной chat-сценарий v14 остановился до отправки сообщения. Создание
подтверждено Codex и адресным `thread/read`, но новый пустой чат отсутствует
в `thread/list` даже со всеми sourceKinds; это не потеря самого чата.
Harness ошибочно уходил обратно в каталог после открытия по квитанции.
Независимое review также нашло преждевременное открытие старого чата из View;
теперь pending-представлением владеет контроллер, а новый ID выбирается только
по квитанции. Добавлены точная AX-идентичность разговора и контракт с задержанным
сохранением. Native/UI этого исправления продолжаются; реальный ход агента
в этом сценарии пока **не начался**. `.build/collaboration-v14-creation-rca/`.

### Дополнение на 15:38 МСК — ссылки, очередь сохранения и настоящий ввод

Исправление актуальности обработчика ссылки проверено на неизменной нативной
копии `18244f052e6daa7ec4d95bcb5a0c64e1a776466eb459744a6cc24fc44bba4606`:
**27/27 PASS**, 0 skips/runtime warnings. Прежний код отдельно воспроизвёл
устаревающую ссылку и подпись загрузки шириной 20 pt: **2/2 ожидаемых FAIL**.
Новый обработчик использует текущего владельца после каждого suspension,
при этом сохраняются тот же WK/DOM, token и каноническая квитанция. Подпись
полностью видна при ширине 320 pt и переносится при 120 pt; оба PNG просмотрены.
Квитанция: `.build/document-page-attempt-diagnostics-v2/final-review.json`.
Это native lifecycle/layout, не приёмка настоящего касания дальней ссылки.

Причина ожидания writer.flush в журнале v13 подтверждена отдельным FIFO-опытом:
прежний код ждал будущие записи, а не только уже принятую границу. Интервал
11.494476 s находится в `.build/navigation-bigdoc-v13-rca/review.md`.
Исправление регистрирует границу до приостановки, отменяет только ожидание
и сохраняет принятые записи. Пять общих контрактов прошли; независимый review
не нашёл оставшихся замечаний. Исполнение нативного профиля продолжается.

Настоящий v13 keyboard diagnostic после обычного поиска и касания поля:
**1/1 PASS**, 23.283 s, 0 skips/runtime warnings. В оригинальном PNG и AX
видна экранная клавиатура высотой 279 pt и фокус поля. Квитанция просмотра:
`.build/v13-controls-preconditions-ui-v2/keyboard-visual-review.json`.
Уникальность проверяется по кнопке внутри виджета: три вложенных WebView
являются предками одного control, а не тремя копиями материала.

Следующий camera/controls сценарий **FAILED** на первом чтении значения поля
после второй печати. До этого два настоящих нажатия изменили count 6→7→8,
slider менял видимое значение, первая уникальная строка прочитана успешно.
Позднее публичное чтение v13 вернуло обе полные уникальные строки; последние
кадры показывают вторую печать. Это не доказательство мгновенного отклика
или отсутствия гонки. Исходный FAIL сохранён; harness теперь записывает точные
expected/immediate/subsequent значения и времена, оставляя непосредственный
assertion строгим. Свидетельства: `.build/controls-v13-input-rca/`.

### Дополнение на 15:18 МСК — настоящий v13, холодная задержка и отказ дальней ссылки

Подписанная private Release-пара v13 собрана из 815 неизменных входов,
`84c60388e2bcd0ccd61e57ebabf9b31dfb61c94e308d8b9494a063e6fd715cc8`,
base revision `f6cf783d371cd1297de32520ea1d70a344bbf6dd`. Upgrade сохранил
точные байты данных и прежние identities. Это development evidence,
не окончательная общая приёмка.

Настоящий UI-прогон `ipad-testTenColdOpeningsAndWarmDistantLinksMeetNativeInstallationBudgets-a25a75f0-ae4b-4ff5-9162-43fa6a522aef`
завершился **FAILED**, 535.126 s. Из оригинальных XCTest attachments получены
десять уникальных записей холодного открытия страницы 0: **6289.288–8031.085 ms**,
nearest-rank **p95 = 8031.085 ms**, выше порога 3000 ms. Одиннадцатое открытие
для подготовки ссылок исключено из этого p95. Финальные assertions общего
теста не были достигнуты: первый переход к дальней главе остался без свежей
установки, затем XCTest потерял remote AX element. **Warm samples: 0**.
Сводка: `.build/bigdoc-v13-readiness/{records.json,receipt.json}`.

Измерение источника заняло 2549.839–2861.807 ms; это вложенная часть общего
интервала, не всё время открытия. Browser phases нельзя прибавлять к нему.
Оставшаяся задержка требует разложения между admission, загрузкой WK,
передачей фрагмента и канонической готовностью. Основной исполнитель просмотрел
первую страницу и настоящий кадр video на 530 s: текст и формулы чёткие,
после ссылки всё ещё 1/37. Кодовый разбор выявил захват начального pageCount
обработчиком ссылки, который не обновляется при сохранённых token/пикселях;
исправление актуальности callback готовится без перезапуска runtime.

Пассивный navigation journal показывает важную границу: десять холодных
завершений не доказывают десять завершений поиска. В семи случаях поиск ещё
ждал writer.flush, когда следующее настоящее двойное касание уже видимой
обложки отменило прежний reveal и открыло документ. Найдены и долгие ожидания
flush при Back; их причина исследуется отдельно. Изначальный collector
отклонил журналы из-за сравнения исторической revision сохранённого manifest
с revision новой сборки. Повторная строгая collection различает два источника
происхождения, сохраняя оригинальную ошибку и файлы; 11 журналов находятся в
`.build/navigation-bigdoc-v13-rca/collected/`. Это `observed_unassessed`,
не автоматическое доказательство отсутствия задержек.

Предыдущий keyboard diagnostic v12 не достиг касания поля: сохранившееся место
было обложкой документа. Финальные кадры это подтверждают; промежуточный пустой
кадр не объявляется постоянным дефектом. В новом harness все четыре сценария
controls сначала переходят к точному материалу через обычный поиск. Настоящий
повтор клавиатуры впереди; модель/DOM/готовность не подменяются.

### Дополнение на 14:31 МСК — реальный экспорт v12 и продолжение UI-приёмки

Изолированная подписанная Release-пара v12 собрана из полного среза
`df2fe47a6d7b9c29a4c0cb40e520a25ba861c466f90e4ef594077e79051c184b`.
Upgrade сохранил точные байты данных, прежние identities и trust:
`.build/public-sdk-acceptance-v12/runs/4c1fd55e-5621-4b53-b490-d688e2cf9249/run.json`.

Через публичный API этой установленной пары большой неизменённый документ
успешно экспортирован: job `861cb514-271b-4878-8e72-41951136b71e`, состояние
`saved`. Свидетельства `.build/big-document-export-v12/{receipt.json,review.md}`.
Проверены исходные возвращённые файлы и их хеши: PDF 1.7, 35 страниц,
35 иллюстраций и подписей, 1680 формул, обе дальние ссылки. Подписи больше
не перекрывают изображения, обрезанного текста не найдено. Независимый
просмотр охватил все страницы; основной исполнитель также просмотрел
первую страницу в 144 dpi. Финальная фаза xdvipdfmx без предупреждений о
версии PDF; ранние предупреждения XeTeX сохранены. Это один настоящий
успешный экспорт, не десять повторов и не полная приёмка.

Повтор UI после исправления компактного notice первоначально не запустился:
общий verification lock занимал внешний процесс. Он не прерывался. После
освобождения слота запущен новый UI-only runner для установленного v12;
**1/1 PASS, 0 skips/runtime warnings**, 43.368 s. Run:
`ipad-testDeniedDictationRetainsDraftAndTextSend-606a1e25-8e89-4f42-8570-7ea503eb59b8`.
Основной исполнитель просмотрел все четыре исходных PNG: compact notice
занимает высоту двух строк, пустой header отсутствует, draft и настоящий
ответ читаются, dismiss возвращает обычный composer. В harness каждый реальный ответ имеет уникальный
маркер запуска, поэтому прошлый ответ не может удовлетворить проверке.

Runtime-source v7: **37/38 native PASS**, 0 skips. Ошибка applyState и её
видимый Retry проверены по настоящим пикселям. В terminal-тесте после
здоровой перезагрузки установлен другой entry того же источника; момент
захвата и установки относительно отказа ещё разбирается. Отдельно найдено
запоздалое уведомление `ready=true` после перехода в `ready=false` при той
же навигации. Независимый review подтвердил недостающую проверку текущего
состояния в доставке; её нельзя считать доказанной причиной смены entry.
Подготовлены отдельные отрицательный и исправленный native-срезы.

### Дополнение на 14:48 МСК — закрытый срез чата, два новых воспроизведения документа

`f6cf783` отправлен в remote: шесть файлов dictation/composer и их контракты.
Чужое переименование параметра test fixture осталось вне commit. Минимальный
native-срез дал 32/32 PASS, окончательная компактная геометрия отдельно
проверена в установленном v12. Независимый review четырёх PNG и 13 настоящих
видеокадров не нашёл блокирующих дефектов в этой области:
`.build/chat-v12-visual-review/{review.md,receipt.json}`. VFR-видео не является
доказательством latency/FPS или работы аудиозаписи.

Настоящий большой документ открылся в первом новом процессе, но второе
нажатие результата поиска оставило прежнюю сцену. Прогон **FAILED**, 59.224 s:
`.build/public-sdk-acceptance-v12/runs/4c1fd55e-5621-4b53-b490-d688e2cf9249/ipad-testTenColdOpeningsAndWarmDistantLinksMeetNativeInstallationBudgets-0cf821cd-aaa6-426f-9543-a6acc21f682b`.
Первая запись request-to-observed-install — **7067.554 ms**, из них
demand-to-content-ready **6411.369 ms**, content-ready-to-observed-install
**2.505 ms**. Это один образец выше порога, не измеренный p95 десяти повторов.
Первую страницу основной исполнитель просмотрел: текст и формулы читаемы,
ссылки доступны, 1/37 соответствует нативной разбивке.

Для следующего воспроизведения добавлены пассивные длительности стадий
подготовки источника. Swift 6 semantic PASS на 122 замороженных входах,
оба inline JS scripts синтаксически разобраны. Это ещё не новое измерение
установленного приложения. Независимый review harness также запретил повтор
ранее принятого UUID warm-записи, требует возрастающее requestedAt и текущий
видимый page host. Пороги не изменены; целевой период наблюдения 5 ms больше
не описывается как гарантированная максимальная задержка планировщика.

Runtime-source исправленный неизменный native-срез `9b65a4a7…`:
**70/70 PASS** (39 runtime, 31 allocator), затем **10/10** повторов terminal
перехода той же сборки, 0 skips/runtime warnings. Каталог
`.build/runtime-source-failure-native-v12-positive/`, повторы
`ten-terminal-repeats/`. Отрицательный queued-ready тест воспроизвёл
`[true,false]` после отказа, исправленный даёт `[false]`. Отрицательный
equal-density тест трижды выбрал прежние красные пиксели после удержания
старой квитанции вместо новых зелёных. Immutable publication order теперь
владеет выбором при одинаковой плотности; access остаётся у LRU eviction.
Тест терминального отказа удерживает конкретный снимок реально установленной
живой поверхности и проверяет его установку после отказа вместе с локальной
ошибкой и освобождением WebKit. Независимый review не нашёл новых замечаний.
Вызов публичного delegate завершения процесса в тесте не выдаётся за OS kill.

### Дополнение на 13:58 МСК — настоящий текстовый чат и отказ микрофона

На установленном private v11 два настоящих UI-сценария завершены:

- `testRealChatReplyAfterPairing`: **1/1 PASS**, ввод, Send и настоящий ответ
  Codex на iPad. Каталог run: `ipad-testRealChatReplyAfterPairing-7c9660d1-5e54-4a02-a141-87c02bfe9fd9`.
- `testDeniedDictationRetainsDraftAndTextSend`: **1/1 PASS** на отдельном
  diagnostic UI-only runner `.build/chat-idle-notice-ui-v1`. Настоящее нажатие
  диктовки при denied microphone создало сообщение владельца аудио; draft,
  Send, переход в compact и обратно, настоящий ответ и dismiss проверены.
  Каталог run: `ipad-testDeniedDictationRetainsDraftAndTextSend-459c172e-f97d-4ca8-9f7d-8cd4bc6038e8`.

Оба каталога находятся в `.build/public-sdk-acceptance-v11/runs/4c1fd55e-5621-4b53-b490-d688e2cf9249`.
Независимый просмотр исходных PNG подтвердил весь текст ответа, controls и
видимую software keyboard. Это не проверка клавиатуры внутри WK-программы.
Видео первого теста имеет **55.768334 s PTS gap**; непрерывность/latency/FPS из
него не выводятся. XCTest ожидал idle около55.91s, у конца ожидания Simulator
сообщил ошибку устаревшего pasteboard item. Это корреляция, а не доказанная
причина без системного sample внутри интервала. Полный разбор сохраняется в
`.build/chat-v11-visual-review/`.

На compact PNG найден пустой44pt header и избыточная80pt высота notice.
Новая правка связывает header с существующим status, измеряет bounded caption
и учитывает промежутки всех реально видимых секций. Она ещё требует нового
Release UI прогона. Изолированный минимальный voice-срез поверх `f77abfc`,
шесть собственных файлов: `.build/voice-minimal-commit-v2/verification/`,
**32/32 native PASS, 0 skips/runtime warnings**. Последующее уточнение4pt
межсекционных промежутков не включено в этот результат.

Actual signed-XPC export v11 завершился **FAILED**: `compiler_unavailable`,
«Нельзя проверить память SVG-компилятора». `.build/big-document-export-v11/failure-receipt.json`.
Реальный CPU-пробник воспроизвёл500/500 случаев `proc_pidinfo=0/ESRCH` при ещё
истинном `Process.isRunning` до notification. Старый receipt не содержит errno,
поэтому это доказательство дефектного пути, не ретроспективное измерение errno
того запуска. Новый общий memory owner SVG/TeX отличает absent task от failed
probe и ждёт единственного terminal owner при прежних deadline и budget.
`.build/compiler-memory-exit-v1/receipt.json`: **17/17 CPU PASS, 0 skips**.
Повтор через новую подписанную пару обязателен; прежний PDF не засчитан.

Runtime-source v4: **36/38 native PASS**, 0 skips/runtime warnings. Новый
window screenshot тест прошёл и сохранил реальные непустые пиксели; прозрачный
снимок v3 исключён. Два after-ready теста повторили успешное снятие live/lease
и остановились на combined retained-entry/AX assertion. Same-binary видео
показывает retained pixels, читаемую ошибку и Retry; точный entry/AX ещё
проверяется, результат не повышен до полного PASS.

### Дополнение на 13:44 МСК — новый чат и экспорт в проверке

Native voice/chat source `fad033c591c4cdb9ace9e2bf95740d5acc560c118eb9c918b657d54181b0cbf1`:
**38/38 PASS, 0 skips, 0 runtime warnings**, свидетельство
`.build/chat-background-audio-native-v3/verification/verification.json`.
Независимый просмотр восьми PNG подтвердил доступность controls; девятый
`companion-chat-pearlescent-work` оказался полностью прозрачным и исключён
из визуальных доказательств. Исправляется владелец window capture теста;
снимка idle-error notice среди этих вложений нет.

В 10:37 UTC официальный `simctl privacy … revoke microphone
com.amirtlinov.notebook.acceptance` отменил только случайный grant предыдущего
XCTest у private Simulator app. Код завершения 0 и точная область сохранены в
`.build/chat-v10-visual-diagnosis/revoke-accidental-microphone-grant.json`.
Speech grant не сбрасывался: эта служба отсутствует в списке simctl privacy.
Разрешения рабочей пары не менялись.

Private **v11** Release source
`c10908c9481ac6e8ea4c390d93e03ea1a655ec89f8d9354e1d061c95ce481b2b`
собран; upgrade сохранил точные данные и прежние identities/trust. Квитанции
`.build/public-sdk-acceptance-v11/{build.json,runs/4c1fd55e-5621-4b53-b490-d688e2cf9249/run.json}`.
В этот срез входят Core `f77abfc`, исправления dictation и PDF block flow;
параллельные новые исправления runtime-source в него не входят.
Настоящий текстовый чат и signed-XPC export выполняются; PASS пока не заявлен.

Отдельная проверка движка и вёрстки PDF завершена:
`.build/export-block-flow-v1/{receipt.json,review.md}`. Все 35 assets/Form
сохранены, 1680 формул и обе ссылки совпадают, 316 destinations. Все 35
подписей получили зазор 5.907 pt вместо перекрытия 8.539 pt. Финальный PDF 1.7;
70 предупреждений ранних проходов XeTeX сохранены, у финального xdvipdfmx их
нет. Это engine/layout proof, не подмена подписанного XPC-маршрута.

### Дополнение на 13:28 МСК — проверка Core, новая пара и текстовый чат

Отдельный `f77abfc` отправлен в remote. Проверены ровно семь файлов поверх
`78224cc`, без зависимости от других незавершённых изменений: **92/92 PASS,
0 skips**. Свидетельство `.build/core-minimal-commit-v1/receipt.json`, source
`df139bc2…`. Допуск текущей SQLite больше не читает тела посторонних досок;
существующая миграция, схема и версия допуска атомарны. Свежая база создаёт
всю схему в исходной bootstrap-транзакции и сохраняет границу checkpoint.
На интеграционной копии дополнительно прошли **46/46 MCP**. Исходный полный
прогон был **759 tests / 5 FAIL / 1 opt-in skip**, все пять отказов покрыты
последующей адресной проверкой; это не новый полный PASS. Контроль 100000
страниц дал **6423 SQL VM / 13 изменённых адресов** на отдельно указанном
предыдущем срезе, до последней правки fresh bootstrap.

Private **v10**: `.build/public-sdk-acceptance-v10/build.json`, source
`be3f3c6ad96e64650d232ec2d818a230bafae3a2cf427521cbae1bba76c5a2e8`.
Чистая Release-сборка прошла после объявления всех 292 выходных путей
SVG-компилятора. Sandbox не отключался; общий каталог Helpers создаёт один
производитель. Неудачные v8/v9 сохранены. Upgrade v7 → v10 сохранил точные
байты данных, идентичности и сопряжение; рабочая пара не обновлялась.

Настоящий `testRealChatReplyAfterPairing` создал Codex-чат, но **FAIL до Send**.
Автоматический `dictation.arm` запросил Speech и microphone; стандартный
interruption handler XCTest нажал Allow. После просмотра журналов private
Simulator-приложение остановлено в 10:06:51 UTC. Запись показывает сохранённые
панель и черновик: исчез весь ряд Send из-за idle-ошибки Speech, а не сам чат.
`.build/chat-v10-visual-diagnosis/contact-sheet.png` и исходный xcresult/video
в каталоге private run сохраняют воспроизведение. Новая реализация запрашивает
доступ только из явного включения, отделяет notice от controls и отсекает
опоздавшее начало распознавателя. Ручная диктовка не зависит от допуска Speech.
Тестовый runner отклоняет неожиданные системные диалоги вместо default grant.
Первый native срез: **37 PASS / 1 FAIL**, без skips/runtime warnings; новый тест
слишком рано ожидал доставку сразу после сохранения. Исправленное ожидание
сначала проверяет durable job, затем отдельную доставку; повтор выполняется.
Реальный текстовый ответ через новую сборку ещё не принят.

Public export большого неизменённого документа через v10 сохранён:
`.build/big-document-export-v10/status-response.json`, job
`2f0e3599-68ec-4d6f-8b08-2a726f0ad54f`. PDF **35 страниц / 2329279 байт**, SHA
`ccec6edd95b6449a9eb2d36d884f368078a822483706ad08696e487012f51c79`:
35 SVG/Form invocations, 1680 дробей, 2 annotations; символов за краем страницы
не найдено. Просмотр первой страницы подтвердил кириллицу (pdfplumber убрал
пробелы при извлечении) и обнаружил подпись в строке рисунка. Исправляются
границы блочных абзацев и версия PDF 1.7; окончательный export ещё впереди.

Новый runtime-source native срез: **30 PASS / 1 FAIL**, включая rejected
Promise, pressure recovery и отсутствие повторных admission своего источника.
Прежнее глобальное admission-generation не было счётчиком открытий WK.
Гипотеза о двух rAF как причине pressure не подтвердилась. SVG demotion в одном
прогоне не дождался фактической установки; диагностический повтор наблюдал её
уже при ready. Независимое ревью выявило terminal failure после ready и три
перехода capture retry/provenance; исправление и проверка продолжаются.

Десять static pan/pinch: 11010 video PTS совпали с decoder/packet inventory,
но интервал временного основания 387.130 ms и codec uncertainty оставляют
пиксельную оценку **INCONCLUSIVE**, не PASS≤1px. Public ScreenCaptureKit probe
запускается, но точное окно Simulator 70×143 выдаёт только Suspended, без
complete frame. CUA по-прежнему возвращает -3811. Это не отказ разрешения;
системные настройки/права не обходились. Настоящие XCTest/Simulator записи
продолжают работать. Полная приёмка и физический выпуск остаются открыты.

### Дополнение на 12:40 МСК — причины зависания и пустого перехода

Повтор экспорта на прежней неизменной сборке воспроизвёл зависание на шестом
из десяти запусков. Системные samples показали `Process.waitUntilExit` в
`CFRunLoopRun` уже после завершения дочернего compiler. Новый владелец ждёт
единственное асинхронное завершение процесса и независимо ограничивает чтение
его pipe; ожидание не зависит от потока Swift executor. Неизменный срез
`4f3d039246678478feddcdc224130af6332a060686cb9514174610ff7ac84578`
прошёл **2/2 нативных XPC/PDF tests и 10/10 повторов positive test** на одном
binary, без skips/runtime warnings. Свидетельства:
`.build/export-async-completion-native-v1/{verification,ten-repeats}`.
Исходный шестой timeout и samples сохранены в
`.build/export-pipe-diagnosis-v1/native-ten-retry`. Экспорт большого документа
из обновлённой пары остаётся отдельной непроверенной частью.

Строгая проверка готовности портала выявила реальный тупик: дочерняя программа
попадала в список живых владельцев, хотя миниатюра не допускает такой runtime.
Поэтому статический producer пропускал её, а живой consumer отсутствовал.
Допуск runtime теперь ограничен физическими элементами текущей доски.
Повтор `.build/portal-installed-source-native-v3` дал **6 PASS / 5 FAIL**;
все 11 исходных ожиданий marker readiness завершились. Пять оставшихся
сценариев ещё не приняты. PNG подтверждают пустой возврат в миниатюру;
проверяется передача retained pixels отдельному потребителю при незавершённом
уточнении. Ожидания жизненного цикла runtime и геометрический измеритель
маркера также исправляются без ослабления прежнего порога.

Изолированный адаптер Codex зафиксирован и отправлен как `78224cc`.
Проверка точного девятифайлового среза: **47 module tests PASS** и отдельный
реальный probe подписанного Codex — **1 PASS**. Квитанция
`.build/codex-scoped-library-v1/receipt.json`; ошибка ранней подготовки копии
записана отдельно, её baseline tests не считаются проверкой изменения.
Новый разговор в Simulator ещё требует обновления пары.

Новый camera measurement owner проверил исходные записи полностью через
AVAssetReader; без общего временного свидетельства они честно остаются
`inconclusive`. Подготовлен следующий настоящий static run с наблюдаемой
монотонной меткой. Диагностика позднего nativeText также готова: она читает
фактические native bounds, source versions и установленное покрытие, не
меняя layout/focus. Это инструменты следующей проверки, а не приёмка UX.

Повтор на 12:48 МСК: `.build/portal-fallback-native-v4`, source
`35e65050240dac3ddc6e96fa4a97f56f8379fa6507545f8f2cc148bc2743f245`,
дал **21 PASS / 2 FAIL / 0 skips**, без runtime warnings. Все **11 Portal**
и оба новых fallback/remount контракта прошли. Root просмотрел четыре PNG
тёплого возврата в portrait/landscape: marker сохранён до и во время контакта,
та же когорта удерживает ту же запись изображения. Геометрический порог
остался прежним — 2 pt; это не измерение требования камеры ≤1 px.
Два FAIL принадлежат recovery при raster admission и лишнему повтору после
render failure. Их причины исследуются вместе с обнаруженным разрывом
runtime-local error → composition status. Вся suite ещё не PASS.
Квитанция просмотра: `warm-return-visual-review.json` в каталоге прогона.

### Дополнение на 12:16 МСК — границы доказательства и новые причины

Нативный iPad-прогон неизменного среза
`96eaa446bbe7b2ec5263a9fb2280b330bd8d65dbb999813b64a0c414c1a949bb`
дал **50 PASS / 7 FAIL / 0 skips**, без runtime warnings. Все девять новых
`NotebookReferenceNavigationTests` прошли; семь сбоев относятся к
`PortalPassageTests`. Этот набор ещё ожидал первое опубликованное покрытие
как готовое изображение и единственный runtime после явного focus. Проверка
переводится на фактически установленный источник и ограниченный набор
предварительно готовых программ; геометрические и ресурсные assertions
сохраняются. Исходный FAIL не заменён:
`.build/navigation-export-native-v1/ipad-verification/ipad.xcresult`.

В настоящем Codex установленного приложения воспроизведён сбой запуска:
JSONEncoder экранировал `/` как `\/` в значении `-c`, которое CLI читает как
TOML. Исправлен scalar encoder; реальный `initialize/config/read/thread/list`
прошёл. Acceptance connect теперь обнаруживает унаследованные MCP-серверы
в коротком bootstrap и отключает их в конечном процессе; plugins/apps
отключены только для стенда. Тот же scoped config и private cwd передаются
в thread/start/resume. 19 Scope/Connection проверок и реальные concurrent
`CodexAppServer.tasks()` прошли. Между config/read и внутренним reload CLI нет
публичной атомарной фиксации чужого глобального файла — эта граница явно
сохранена. Реальный разговор через обновлённое приложение ещё впереди.
Свидетельства: `.build/codex-scope-fix-v1/`.

Экспорт в настоящем XPC уже создал PDF с SVG, gradient/clip/filter,
кириллицей, формулами, TikZ, siunitx и тремя Link annotations. Первый общий
прогон завис после готовности PDF до ответа владельца; его timeout остаётся
открытым. Тот же positive test отдельно прошёл за 3,477 с, затем после
canary — снова PASS. Найдено отдельное неверное повторное использование
одноразового XPC lease самим negative test; оно исправлено без изменения
ожидаемых sandbox-отказов. Это ещё не успешный экспорт большого документа
из чата. Артефакты: `.build/export-pipe-diagnosis-v1/`.

Два настоящих camera-прогона по десять циклов (static/live) завершили XCTest
PASS на одном immutable binary. Пиксельный итог остаётся **INCONCLUSIVE**.
FFmpeg RGB decode смещал цветовые центры относительно PNG; публичный
AVAssetReader исправил этот источник погрешности и проверил все 4475/4399
кадров и PTS. Обнаружен второй дефект измерителя: одинаковые позы разных
повторов ошибочно сопоставлялись только по геометрии двух опор. Исправляется
временная привязка; полученные ранее границы ошибки не являются доказанным
смещением приложения. Исходные результаты сохранены рядом с
`measure_joint_native_v1` в `.build/camera-acceptance-pipeline-v2/build/`.

Независимый просмотр controls r6 оставил открытым **V-R6-01**: заголовок
nativeText появляется примерно на 0,592 с позже кадра, где его область уже
видима. Это разность PTS видео, не resource-ready latency. Прямая причина
(живой TextEditor или неполное установленное покрытие) пока не доказана;
готовится наблюдающий trace следующего настоящего pinch.
`.build/controls-independent-r6/review.md` и `owner-analysis.md`.

Поддерживаемая перезагрузка только приватного Simulator завершилась с
побайтовым сохранением проверенных файлов пространства, manifest, bundle и
container ID: `.build/private-simulator-reboot-v1/preservation.json`.
Системный Pasteboard wait после неё ещё не проверен реальным вводом;
ScreenCaptureKit `-3811` сохраняется. Экранная клавиатура, временные пороги,
системные кадры и 30 минут работы остаются открытыми.

### Дополнение на 11:41 МСК — ввод, адресная навигация и экспорт

В 11:42 МСК r6 завершил **1/1 XCTest PASS**, два полных прохода реальных
кнопки/ползунка/поля после pinch и последующего pan. Первый named drag
не сдвинул сцену (before/after PNG совпадают побайтово); это не доказательство
первого pan. Новый harness выбирает свободный старт и проверяет фактический
frame delta элемента. Count 4 → 5 → 6, slider
65 → 47 → 65; оба ввода подтверждены, последняя PNG просмотрена root.
Run `ipad-testCameraAndFirstTouchControlsOnAgentMaterial-9073a626-0988-4abc-aa96-85278ffa068c`,
источники только UI runner `.build/acceptance-ui-only-v7-r6/`, установленное
приложение — прежний v7. Нативные bundle inventories совпали; `summary.json`
не содержит skips/runtime warnings. Это функциональный PASS, не измерение
задержки: перед вторым вводом XCTest ожидал около 29 секунд.

Следующий реальный chat run `d7ab092e-4709-4831-85da-a05a487fadaa` остановился
до отправки: compose открыл каталог, тест не создал/не выбрал разговор, Send
был disabled. На экране также «Не удалось прочитать чаты. Подключение
проверяется…»; адаптер исследуется отдельно. Снятый во время focus wait sample
`.build/public-sdk-acceptance-v7/chat-focus-wait-sample.txt` доказал синхронное
ожидание главным потоком UIKit сервиса `PBServerConnection` все 3 секунды
сбора. Это дефект/состояние системного окружения Simulator; приложение не
получает обходной реализации UIKit. CUA по-прежнему возвращает технический
ScreenCaptureKit `-3811` даже без активной записи. Системные frame/latency
пороги остаются открытыми.

На неизменном приложении v7 настоящий жест ползунка теперь проверяется по
видимому AX frame его бегунка, без accessibility setter: run
`ipad-testCameraAndFirstTouchControlsOnAgentMaterial-d6a5af29-f68d-41fd-84b8-e5e701d1a10b`
подтвердил count 1 → 2 ровно один раз, slider 50 → 31 и ввод текста после
настоящего tap. Кадры `B935A5B8…`, `8E8E8BBC…`, `F96F6CAA…` просмотрены;
жест и значения сохранены в `actual-slider-native-drag`. Повтор полного
сценария пока не PASS: устранены ошибки выбора свободной области самим
XCTest и повторных AX-запросов к исчезающим клавишам. Клавиатура Simulator
имеет нулевую высоту при подключённой аппаратной клавиатуре; это подтверждает
ввод текста, но **не** приёмку видимой экранной клавиатуры.

Холодное открытие большого документа через поиск выявило ошибку владельца:
переход зависел от наличия обложки в ограниченном кэше текущей сцены. Поиск
находил реальную обложку, а переход молча прекращался. Коммит `2504852`
добавляет адресное чтение положения в Core без загрузки тела и состояния;
4/4 теста прошли, включая смену владельца, адрес элемента и явное отсутствие.
Квитанция `.build/reference-navigation-core-v1/receipt.json`. Интеграция
асинхронного перехода, отмены новым контактом и сохранения истории до успешного
возврата ещё проверяется; повторный холодный UI-тест требует следующей сборки.

В экспорте WebKit renderer отвергнут после реальных XPC-запусков: он требовал
дополнительной GPU/network capability. Новый SVG compiler использует
закреплённые krilla/krilla-svg/usvg и stdin/stdout внутри наследуемой песочницы;
сеть и файловые возможности не расширяются. Отдельный реальный SVG с 12000
сегментами сохранил вектор и извлекаемый текст; gradient/clip/filter просмотрены
в `.build/export-preservation-v1/`. Это проверка compiler, **не** итогового
экспорта из приложения: полный XPC/PDF и 35 SVG контрольного документа ещё
должны пройти повторно после упаковки.

### Дополнение на 11:14 МСК — настоящая связь и первые жесты v7

Изолированная Release-пара v7 собрана и обновлена с сохранением прежних
данных и доверенных идентичностей; исходники
`d7c634e3388e3bed1c09fa9d3079d28906afdc55bf8d615a0f5dd26e11335f62`.
В 11:00 МСК обе стороны разрешили доступ через настоящий интерфейс после
сверки полных device/workspace ID. Mac и iPad показывают подключение, публичный
`notebook_context` вернул `connection.status=connected`; присутствие и квитанции
показа приходят через обычную синхронизацию. Свидетельства:
`.build/public-sdk-acceptance-v7/ipad-real-paired.png` и
`runs/4c1fd55e-5621-4b53-b490-d688e2cf9249/public/paired-context-response.json`.
Это закрывает прежнюю неопределённость discovery/подтверждения, но само по себе
не доказывает сквозной разговор или показ всех материалов.

Отдельный diagnostic UI runner `.build/acceptance-ui-only-v7-r1/` собирает
только XCTest bundle, не пересобирает и не переустанавливает приложения.
Сверка bundle/data до и после совпала. Настоящий тест сопряжения прошёл 1/1;
первый post-validator не распознал имя отдельного bundle. Его исправление
прошло 55 CPU-контрактов и повторно проверило исходный неизменный xcresult;
supplemental receipt сохранена отдельно, прежний неуспешный итог не заменялся.

Жестовый controls run `ipad-testCameraAndFirstTouchControlsOnAgentMaterial-
e993055b-9d61-4d21-b48c-e1b4c9301799` подтвердил настоящий pan, pinch и первый
tap: счётчик 0 → 1 ровно один раз. Следующий шаг **FAIL до жеста slider**:
XCTest не получил WebKit Min/MaxScrubberPosition. Исправляется тест настоящего
перетаскивания видимого бегунка. Сохранённая Synthesized Event траектория pinch
имеет расстояния пальцев 6,505 → 14,142 → 17,620 pt: номинальный scale 1,25
описывает только отрезок после первых 100 мс. Увеличение камеры больше чем
вдвое соответствует этой траектории; первый tap геометрию не менял. Это не
доказательство отсутствия иных дефектов камеры или прохождения порога 100 мс.

Реальный PDF export большого контрольного документа выявил новый дефект:
21 страница сохраняет текст и 1680 формул, но теряет все 35 SVG и активные
ссылки. Независимый обзор исходных PDF/TeX, контактных листов и трёх крупных
страниц: `public/export-preflight-review/REPORT.md` внутри того же run.
Исправляется владелец преобразования HTML/Markdown и публикации полного
пакета TeX/PDF/assets; создание файла не засчитано как успешная приёмка экспорта.

### Состояние на 10:35 МСК

Private Release v6, source SHA
`75026605d9e078438ce3d944f21157ea20f259d838e150a941357efd4bfec148`,
собран и установлен только в прежнюю изолированную пару. Квитанции
`.build/public-sdk-acceptance-v6/build.json` и
`runs/4c1fd55e-5621-4b53-b490-d688e2cf9249/`: byte inventories до/после
совпадают, workspace/actors/Keychain scope сохранены. Рабочий helper и
физический iPad не изменены. Это диагностический срез; новая геометрия живого
элемента, изменённая после копирования, в него ещё не входит.

Apple Development XPC bootstrap и **11/11 native методов PASS**, без skips
и runtime warnings: `.build/public-protocol-v5-mac11-v3/receipt.json`, SHA
`fb28b692ac26609a9c029a62ed682a6de22af99d9ff731facb3a7f6a55ca62ea`.
Проверены реальное исполнение JS, host deadline до bootstrap, cancel после
принятого эффекта, atomic operation errors/place, quotas/recovery, настоящий
PDF compiler и отказ записи за sandbox. Для статeless тестовых workers
используются отдельные устойчивые подписанные bundle identities; прежние
контейнеры и их ACL не меняются. У paired стенда suffix `.acceptance-runtime`,
у native tests `.native-test`; данные запусков остаются у прежнего Mac writer.
Публичный v6 bootstrap вернул42; большой документ действительно создан через
новый API: run `ec08c630-fa60-4ec0-8475-7547049d791e`, document
`3299e4d4-69ef-4a1e-8cb3-d8b10be29249`, action
`F8D0CA04-D00B-47BF-8B59-923E34EF1A24`,140блоков/35SVG/1680формул,
6877041знак. Два адресных чтения подтвердили сохранение. Доставка/показ
этого документа ещё не подтверждены. Старый run `476395b3…` прочитан через
resume: terminal cancelled, эффектов нет.

Native scene projection/source lifecycle: **28 выбранных методов PASS**
в `.build/scene-native-projection-v1/` и `v2/`; между ними изменён только
тест координаты центра системного UIButton, production SHA одинаковый.
Nine-program close теперь PASS, включая освобождение WK и документных
растров. Static lossless10-cycle run с production SHA
`c60ea3742a3a53f688967295d9fe3cdabd79ea250dbc42c7cfdbce929495a10a`
показал delayed source в ready revision2; root просмотрел настоящий finish
PNG. Но камера **ещё FAIL**: независимое измерение521PNG,506измеримых,
только15целиком в движении; максимум Euclidean у WK1,608px, при RGB sensitivity
1,224px. Отдельное измерение стабильного компонента подтверждает1,30px.
См. `.build/camera-native-projection-static-review-v1/`. Settled кадры проходят
≤1px, но не заменяют движение. Прежний медленный drag12pt/s становился
выделением до порога pan; следующий harness использует40pt/s без изменения
recognizer, а покрытие считает по фактическому trace. Canonical placement
элемента переводится со SwiftUI transforms на native geometry.

Per-launch Time Profiler handshake:12CPU fault-injection tests и Swift6
semantic PASS; настоящий attach smoke выполняется отдельно. Два сценария
совместной работы подготовлены и проходят Swift6 semantic, но ещё не запущены.
Simulator frame-drop ≤1%, p95 документов, парный разговор и30минут работы
остаются открытыми. Bonjour Local Network permission пока не подтверждён.

### Дополнение на 10:48 МСК

Сопряжение v6 реально дошло до подтверждения: iPad показал Mac device
`503c84b5-7a9c-4080-957b-6bf5f05fd160`, workspace
`11204815-91ac-4fe5-b0d4-284814bba76a`; Mac UI одновременно показал iPad
`ec2ab92d-5490-4fa3-948d-0d90762d9d96` и то же пространство. Root просмотрел
`.build/public-sdk-acceptance-v6/ipad-actual-pair-confirmation.png`.
UI test остановился на слишком узком запросе StaticText для комбинированного
LabeledContent, **не** на отсутствии peer. Проверка теперь ищет точное значение
label/value и проверяет оба идентификатора; Swift6 semantic PASS. Подтверждение
на обоих устройствах и доставка пока не выполнены. Предыдущая запись о
недоступности сети не описывает этот более поздний успешный discovery.

Native canonical element pose:1/1 PASS,0skip/runtime warnings, source
`a58f239289332858a703c7500110eaedb8e700e0b83564efc4ffc1f29a70600b`,
`.build/scene-element-pose-native-v2/results/verification.json`. Реальный WK
сохранил bounds200×180, один mount, JS identity/count;24fractional phases ×3
контрольных точки совпали с canonical projection до0,0001pt. Это проверка
координат и состояния; новая пиксельная приёмка ещё обязательна.

Независимый public-only v6 агент прошёл create/read/search/update/place/rename
CAS/conflict/undo/cancel/resume/repeat, просмотрел2реальныхPNG и самостоятельно
исправил высоту своего интерактивного примера по diagnostics. Отчёт:
`public/blind-v6/REPORT.md` внутри v6 run. Найден ещё один P2: metadata operation
в error эффекта не входила в outputSchema. Общая схема исправлена без потери
деталей;9MCP tests/check и обе реальные отрицательные квитанции v6 PASS.

Time Profiler smoke v6 **FAIL до начала измеряемой работы**. PID/bundle/UUID
сверены; Instruments сообщает fileDescriptorHandshake failure5, unclaimed
Table42 и disconnected while setting/starting tap. Это сбой DVT backend,
не доказательство универсальной неподдержки Time Profiler. Полные исходные
журналы и граница вывода: `.build/v6-trace-diagnosis/REVIEW.md`. Новый cleanup
сохраняет первичную ошибку: UI48CPU tests и trace16CPU tests PASS. Ни один из
этих результатов не засчитывает системные кадры или отсутствие hangs.

Private v7 собирается из неизменной копии
`d7c634e3388e3bed1c09fa9d3079d28906afdc55bf8d615a0f5dd26e11335f62`;
обе рабочие физические установки остаются прежними.

### Предыдущий срез на 06:08 МСК

Lossless camera v1, SHA
`5ccf3033aedac477ed5c78c41c1b73a995f6ad1626034de7b073ecc362733149`,
`.build/camera-current-lossless-v1/`: оба сценария выполнили десять циклов UI,
но визуальная приёмка **FAIL**. Независимый обзор
`.build/camera-lossless-independent-v1/REVIEW.md` подтверждает Euclidean
расхождение до 1,30 px в кадрах внутри жестов. Сильный blur уменьшился,
однако статический SVG остаётся мягче живого, а `zz-camera-delayed` после
80 секунд всё ещё показывает «Подготовка…» при ready через 4,5 секунды.
Обнаружено, что временное закрытие допуска новой композиции отменяло уже
запущенную подготовку источника. Исправляется жизненный цикл этой работы;
камера переводится на общую нативную транзакцию для установленных плоскостей
и чернил. Новых положительных пиксельных доказательств этих правок пока нет.

124/117 измеримых кадров и 12/11 кадров полностью внутри жестов недостаточно
для принятого охвата 200/60. Отчёт timing v2 отдельно исправляет ошибочное
толкование паузы между screenshot requests: возможный промежуток между
наблюдениями достигает 3,027/3,023 секунды, а не 0,06 секунды. Первоначальные
отчёты сохранены. Для ≤1% пропусков системных кадров пока нет измерения;
read-only диагностика: `.build/simulator-system-measurement-review/REVIEW.md`.
Дорабатывается привязка трассы к фактическому PID после каждого app.launch.

Native v11, SHA
`1b1d31e1ee1b26f91f6a5531df18f6567cae5b73a47f8d33b366bb2916640a9a`,
`.build/document-per-block-native-v11/results/ipad.xcresult`: **6 PASS / 1 FAIL**.
Пройдены два whole-cover контракта, три recorder и stationary native install.
Оставшийся Nine тест нашёл пять UIImageView 20×20 с ancestry
`UIActivityIndicatorView → UIStackView → ProgramPendingView`; документные
растры и WK leases освобождены. Тест теперь исключает только доказанные
системные spinner images, не ослабляя проверку остальных владельцев. Нужен
повтор. V10 compile failure и прежние отказы сохранены.

Исправления замечаний blind API и host deadline: **34 Swift methods / 40 cases**,
**9 MCP tests** и generated help/check PASS, без compile warnings.
`.build/public-protocol-v5-repair/receipt.json`. Время запуска XPC теперь
входит в 30 секунд полного задания; cancel завершается даже при worker до
`main`. Отдельно исправлен `wait_ms:4000`, которому прежде не оставалось
времени на IPC. Настоящая embedded XPC проверка 11 методов ещё выполняется.

У подписанного диагностического helper обнаружено дополнительное системное
ожидание: secinitd не допускает Apple Development identity к контейнеру
прежней ad-hoc identity без системного подтверждения. Журнал
`.build/public-sdk-acceptance-v5-signed-network-probe/sandbox-bootstrap.log`.
Попытка публичного создания большого документа не дошла до JavaScript;
run `476395b3-0ac7-453f-a3b4-95b7f4174c98` не имеет принятых эффектов.
Контейнеры, ACL и системные защиты не изменялись. Bonjour Local Network
permission также не подтверждён. Полная сквозная приёмка и установка остаются
закрытыми условиями.

### Предыдущий срез на 05:24 МСК

Private Release v5 собран: SHA
`246dc648b1b74dfda43f0a89bec306539a476e8c3650e6fd64359181072285f1`,
`.build/public-sdk-acceptance-v5/build.json`. Обновление сохранило byte inventory
обоих хранилищ и прежние workspace/actor/Keychain identities; квитанции
`runs/4c1fd55e-5621-4b53-b490-d688e2cf9249/data-{before,after}.json`.
Simulator entitlement проверяется в настоящем Mach-O `__TEXT,__entitlements`,
включая platform 7 и отдельную Keychain-группу. Первоначальный v4 verifier ошибочно
читал обычный codesign payload; его отказ сохранён, а не переписан на PASS.
XCTest теперь управляет установленной парой без переустановки приложения и
перебазирует launch manifest после перемещения контейнера Simulator.

Настоящие жесты дошли до ввода приглашения и «Подключиться» на iPad:
`ipad-testJoinRealMacThroughPairingUI-4f58f73d-a4c2-4805-a7d4-6c15a9a1199b/result.xcresult`.
Проверка не прошла: подтверждение peer не появилось. Mac listener ready,
но Bonjour не опубликован; журнал mDNSResponder явно называет Local Network
policy `pending` для `com.amirtlinov.notebook.mac.acceptance`. Подготовлена
отдельная подписанная диагностическая копия с тем же источником и manifest:
`.build/public-sdk-acceptance-v5-signed-network-probe/signature-probe.json`.
Сертификат Apple Development, team `VUNH73AYPY`, CDHash
`e0f9b4700ac3428d766dc98b04c50433beddf2f1`; ограничения обоих XPC сохранены.
Она также ожидает системное разрешение. CUA запретил доступ к приложению
UserNotificationCenter; пользователю отправлена только просьба о системном
клике, не задача тестирования. Защиты системы и production helper не менялись.
См. также [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy):
на Mac локальная сеть требует устойчивой подписи, а Simulator не проверяет
поведение системного разрешения iPad.

Независимый агент через только два публичных инструмента выполнил **19/19**
видов изменения, прочитал сохранённые результаты, получил и просмотрел
**6 PNG**. **31 публичный вызов**, история, undo, export PDF и повтор запуска
прошли; это Mac API, не доставка на iPad. Точный отчёт:
`public/blind-v5-report.json` внутри того же private run. Найдены и исправляются:
валидный по схеме `place` → `invalid_command`; неясный containing-board target
для `renameItem`; отсутствие индекса неудачной операции; сырой XPC 4097 при
cancel после уже сохранённого эффекта. Ни один из этих отказов не скрыт.

Native v9: **6 PASS / 3 FAIL**, SHA
`c353ce91b5d377753a020d54c62152e9a0ac6c163b0d0d631f6e3180bde01a38`,
`.build/document-per-block-native-v9/results/ipad.xcresult`.
Recorder 3, hidden/curl cover, независимая публикация геометрии и физическая
плотность page SVG прошли. Снимок SVG 1560×2234, прозрачные углы, источник без
чёрной полосы. Whole-cover red SVG/ink pixel checks прошли, но последующая
проверка версии обнаружила stale proof после model reload; исправляется
сравнение с текущим владельцем версии. Nine close удержал пять декоративных
UIImageView 20×20, не девять растрированных программ; точная ancestry проверяется
до изменения утверждения. Passive capture автоматически повторился после
освобождения ресурсов, однако тест раньше установки native witness завершил
ожидание на готовом cache; уточняется именно ожидание фактической установки.
Все три проверки повторяются на новом неизменном v10, результат пока pending.

Mac editor toolbar **1/1 PASS**, `v9/mac-results/mac.xcresult`: реальные кнопки
Save/Cancel, одна запись при двойном нажатии, сохранение конфликтного черновика,
отмена без новой записи. Это WK/native контракт, полноценный iPad жест ещё
ожидается. Проверки driver **38/38**, release **48/48** прошли. Исправление
startup хранилища сопряжения отдельно проверено 11 native tests и зафиксировано
`ceaee76da30355fbac5a542e1fdab2dc2a245f8a`.

Свежие lossless camera кадры, системные метрики, документные p95, настоящая
доставка/показ/разговор и 30 минут совместной работы ещё не пройдены.

### Предыдущий срез на 04:41 МСК

Native v8: **66 PASS / 4 FAIL**, `.build/document-per-block-native-v8/results/ipad.xcresult`,
SHA `8c0d2322e50dd799d44465c6b0bdb64e1bbd69407794b2701ecfe5b933091c88`.
Прошли восстановление NearbySync после ошибки хранилища, оба теста передачи/
освобождения WK при удержанной UIKit оболочке, снимок внимания всей доски,
14 curl-переходов, raw transparent SVG без чёрной полосы и sparse allocation.
Остались два отказа `cover_ink_pending`, удержанное UIImage после закрытия
девяти программ и ранняя публикация растра в одном headless-сценарии.
Потеря environment сцены при создании hosting controller обложки найдена
и исправляется у этой границы; условие готовности снимка не ослабляется.

UI-only v3 остановлен через 240 секунд без сопряжения. `securityd` доказал
`-34018` у private iPad: отсутствовали `application-identifier` и
`keychain-access-groups`, потому что driver отключал signing. Отдельный sample
после настоящего tap показал главный поток в UIKit keyboard →
`PBServerConnection.localGeneralPasteboard` → синхронное ожидание XPC.
Доказательства: `.build/public-sdk-acceptance-v3/clipboard-ui-v2/system-paste-1/nearby-security.log`
и `.build/public-sdk-acceptance-v3/clipboard-ui-v3/system-paste-1/diagnosis.json`.
Simulator штатно перезапущен без erase; v8 исполнился после этого перезапуска.
Driver теперь требует ad-hoc Simulator signing с собственной Keychain-группой
и проверяет entitlements до установки; новая сборка ещё не испытана.

Через публичный JS API создан контрольный board widget с кнопкой, slider,
полем ввода и nativeText. Run `3aadc2d4-9421-45ae-9030-9d4bea2393d2`, action
`33616BE6-F422-4E7C-8440-C9917F25D576`: saved подтверждён, delivered/shown нет.
Перед этим действие без composition owner корректно отклонялось, но effect
ошибочно получал `outcomeUnknown`; исправляется сверка с атомарной квитанцией
писателя вместо списка кодов ошибок. Все 21 прежние возможности и 19 видов
операций сопоставлены с новым SDK по исходникам; это не 19 полных E2E-прогонов.

### Предыдущий срез на 04:06 МСК

Native v6: **13 PASS / 1 FAIL**, `.build/document-per-block-native-v6/results/ipad.xcresult`,
SHA `d99813452acd0b9836268ce5b04bae64bddfc5a919df954a3b683918741c5d5e`.
Все десять выбранных проверок документов, native overlay и whole-board Send прошли.
Девятая программа после приостановки сохраняет настоящий синий DOM-only фон и
count1, а прежняя оболочка явно освобождает pin изображения при снятии.
Send после публикации контекста сохраняет красные пиксели установленной доски,
исключает зелёный внешний overlay и toolbar, последующее изменение не делает их синими.
PNG `CA11D170-AF4B-4A54-A68E-16ECC583AFE1.png` и
`6DD5133D-F5F3-4F12-BF05-9D8AF2555C18.png` самостоятельно просмотрены двумя агентами.
Единственный отказ v6 — чёрная полоса в прозрачном SVG ещё до композиции:
24 330 заполненных пикселей вместо менее 5 760. Исправление проверяется отдельно.
Предшествующий v5 подтвердил все 14 повторных native переходов страницы.

Release camera current: оба UI-сценария выполнили десять циклов, но визуальный
порог **не пройден**. `.build/camera-current-native-basis`, SHA продукта
`6d0508ece96970cde5028953efdb4e39dbccd46d8d0c9a7645b8772b899f70eb`.
Static: максимум SVG 1,325 px, WK 1,073 px, 223 измеримых кадра движения,
пробел покрытия до 30 кадров. Live: 292 кадра движения, полное покрытие с
максимальным пробелом 3; максимум SVG 1,375 px, WK 1,391 px. Независимый
`.build/camera-independent-review/REVIEW.md` подтверждает реальную размытость
static finish и систематическое смещение SVG около +0,885/+0,872 px.
Непрерывный цветовой centroid уменьшает пограничную live-оценку до 0,970 px,
но даже ограниченная синтетическая ошибка 0,0386 px превышает запас до порога.
Это не основание заменить FAIL на PASS. Видео не измеряет системные FPS.

Private Release v3 собран с SHA native v6; workspace и идентичности v2 сохранены,
перемещение каталога Simulator при установке записано отдельной квитанцией.
Run `.build/public-sdk-acceptance-v3/runs/4c1fd55e-5621-4b53-b490-d688e2cf9249/run.json`.
Новый Mac owner открыл обычное окно сопряжения через reopen; CUA прочёл реальный
AX, публичный SDK отвечает. Приглашение создано обычной кнопкой. Сопряжение,
доставка документа и реальный разговор на iPad ещё не подтверждены.

Следующая дельта завершения native lifetime (удержанная UIKit оболочка не
удерживает WK/image после retirement) прошла компиляцию; её runtime-проверка
ожидается. Системные метрики, 30 минут смешанной работы и полная приёмка остаются открыты.

### Предыдущий срез на 03:31 МСК

Native v4: **43 PASS / 1 FAIL**, `.build/document-per-block-native-v4/results/ipad.xcresult`,
SHA `33dda13d56f51657574559a6fa7dce26adb1ff7826d471e221aa8e13399622bf`.
Прошли синхронный захват реально установленного WebKit в событии отправки,
неизменность красных пикселей после синего DOM, исключение соседнего слоя,
проверка невидимых/обрезанных областей и сохранение учёта памяти после передачи
снимка другому читателю. Прошли адресный приоритет текущей программы, уточнение
неподвижной страницы и освобождение ресурсов. Единственный отказ — возврат
программы в текущую страницу после native curl: фоновая подготовка соседей
задерживала её передачу. Исправление приоритета и ограниченная подготовка
большого числа интерактивных блоков ещё ожидают следующего native прогона.

Mac document v4: **4/4 PASS**, `.build/document-per-block-native-v4/mac-retry-results/mac.xcresult`.
Изменение исходника и возврат к прежним байтам создают новый причинный runtime;
обновление состояния и постороннего блока сохраняет прежнюю программу.
Первый запуск Mac-only из чистой копии не собрался из-за отсутствия esbuild.
Маршрут выбранных проверок теперь готовит locked MCP dependencies также перед
любым Mac host build, независимо от набора поведенческих MCP-тестов.
**31/31** проверки выбора и квитанций прошли, включая этот контрпример.

Private helper запущен с отдельным manifest/store в Application Support.
Run `4c1fd55e-5621-4b53-b490-d688e2cf9249`, workspace
`11204815-91AC-4FE5-B0D4-284814BBA76A`. Независимый субагент получил только
публичные инструменты и справку: **22 вызова, 0 случайных ошибок схемы**.
Пройдены создание русского документа с формулой/SVG/controls, чтение, версионная
правка, ожидаемый stale conflict, undo, точный повтор запуска, resume,
отмена после принятой записи и настоящий PNG через журнал исполнителя.
Отчёт: `.build/public-sdk-acceptance-v2/runs/4c1fd55e-5621-4b53-b490-d688e2cf9249/public/blind-acceptance-report.json`.
PNG с SHA `6f8086f2e6fb938204d5e54ce4ae1becf3ce3ff083e39277999814be9e0e46ad`
самостоятельно просмотрен: русские подписи, формула, полный SVG и controls
читаемы, диагностики пусты. Это рендер Mac; доставка и управление на iPad
не доказаны, `presentation` вернул `unavailable`.

По независимой проверке исправлена справка завершения: polling продолжается
при queued/running либо `has_more=true`. Добавлен полный пример `notebook.ready`,
компактный индекс операций и адресная справка одной операции. Transaction schema
сократилась с 72 352 до 19 567 байт, индекс operations с 61 951 до 2 474 байт.
**6 адресных MCP и 2 Swift help-dispatch** теста прошли, все 19 операций доступны.

Просмотрены v4 снимки красного Send-crop, синей текущей программы, уточнённой
страницы и нижнего фрагмента высокого блока. На снимке четвёртой приостановленной
программы найден непредусмотренный чёрный прямоугольник; он остаётся дефектом,
несмотря на прошедший контрактный тест. Новая камера проверяется отдельно
в `.build/camera-current-native-basis` на неизменной диагностической копии;
системная плавность, реальное сопряжение, 30 минут смешанной работы и полная
приёмка по-прежнему не заявляются.

### Предыдущий срез на 03:03 МСК

Объединённый native v2: **86 PASS / 8 FAIL**, без пропусков и runtime warnings,
`.build/document-per-block-native-v2/results/ipad.xcresult`, SHA
`7bca10e573fd315ea4e917f39bbb21a550df243027e3c1f86e0d8edf92e896bb`.
В том числе прошли все проверки причинной записи состояния программы, внимание,
новый адресный жизненный цикл модели и восстановление чёткости неподвижной
страницы после освобождения памяти. Core source-admission: **20 PASS**,
`.build/acceptance-swift/document-state-source-admission-v5.log`. Старый runtime
не записывает состояние поверх заменённого/удалённого исходника и не двигает
SQL-курсор при отказе; принятая запись имеет отдельное подтверждение писателя.

Native v3: **24 PASS / 3 FAIL**, `.build/document-per-block-native-v3/results/ipad.xcresult`,
SHA `aaf3f7a0f61cdbb6022c0bd185528815c73d043e01a6793b6eb2840757911c9d`.
Прошли дробная геометрия установленного WebKit, проекция уже показанных чернил
без нового drawable, единая программа на нескольких физических страницах,
настоящий WebCrypto и получение нового синего кадра после изменения DOM.
Последняя проверка относится к явному асинхронному захвату; она не доказывает
время отправки вопроса. Новый синхронный Send capture проходит отдельный v4.
Три оставшихся отказа: момент готовности программы в retirement fixture,
освобождение дальних thumbnail packets и отсутствие WebKit в landed curl page.
Последний переход продолжает диагностироваться; общий PASS не заявлен.

Уточнённый bounded baseline камеры (исходный commit `012921b`) сохранил
758 измеримых кадров, 342 кадра движения и все десять остановок:
`.build/camera-baseline-bounded-v2/camera-static-32b5804c-c98c-4df6-b363-0782dbe85a56/measurement`.
Максимальное расхождение SVG 89,977 px, WK 89,419 px; **FAIL**. Есть промежуток
из девяти кадров без измеримых опор, поэтому покрытие не считается полным.
Live baseline остался на «Подготовка пространства»: ноль опор, результат
неопределённый, а не нулевое смещение. Исправленная версия ещё ждёт видео-прогона.

Вторая private Release-пара собрана с настоящим Xcode script sandbox, включая
явный список файлов TeX. `.build/public-sdk-acceptance-v2/build.json`, SHA
`0e00fb5ad20ccaa97c7a13587a7c2e7e34913ebc9a6442e75424ac4e3e44baa1`.
Первый запуск private helper остановился на TCC DocumentsFolder до NSApplication:
runtime manifest ошибочно лежал среди evidence в Documents/.build. Для новых
стендов собственные runtime manifest/store находятся в Application Support;
evidence хранит ссылки и отпечаток драйвера. Доступ к Documents не выдавался,
существующие данные не переносились. Работоспособность и сопряжение новой пары
ещё не подтверждены.

### Предыдущий срез на 02:33 МСК

Новый исполнитель прошёл **9/9 настоящих Mac XPC-проверок**, без пропусков
и runtime warnings: `.build/script-services-tex-sandbox-v5/verification/mac.xcresult`.
Неизменный SHA `ed8a82a82d9a7acc894665c04877c2111967810565dcd4034b5b503f1bd1d95d`.
Проверены общий исполнитель, очередь SDK, отмена, восстановление и настоящий
PDF с русским текстом, формулой, TikZ/siunitx через PDFKit. Вложенные службы
имеют только `app-sandbox`, компилятор — `app-sandbox` и `inherit`; строгая
проверка подписи и отказ чтения внешнего canary прошли. Предыдущий v2 имел
8 PASS / 1 FAIL: Xcode добавил тестовому worker право чтения `/`. Этот отказ
устранён маршрутом build-for-testing → точные исходные права вложенных
служб → test-without-building, а не ослаблением теста. MCP check и **32/32**
протокольных теста прошли, включая общий срок ответа менее четырёх секунд.

Документы теперь используют отдельный runtime каждого программного блока
и нативную обрезку. `.build/document-per-block-native-v1/results/ipad.xcresult`:
**35 PASS / 5 FAIL**, без пропусков и runtime warnings; SHA
`f3799aa6322e9de4d1f2fabbd5737c85f1b35061c84fbd06edd9b529da45f0be`.
Прошли реальные WebKit block tests, native overlay/ownership, запись состояния,
неизменяемое внимание и квоты. Пять ошибок жизненного цикла и подготовки
сохранены; следующий прогон проверяет исправления, общего PASS пока нет.

Покадровое сравнение выявило отдельное от размытия отставание чернил. В
`.build/camera-baseline-v4/camera-static-37939aca-b4bb-46d9-9515-f3ffeeb96552/measurement-v2/`
максимальное расхождение SVG — 73,394 пикселя снимка, WK — 73,366.
В `.build/camera-current-before-ink-basis/camera-static-5d2cc249-9458-4fa0-9731-33ffd2d16a3e/measurement-v2/`
оно всё ещё составляет 46,753 и 46,889 пикселя. Десять жестов исполнились;
полного покрытия опор во всех кадрах нет из-за фактической амплитуды XCTest
pinch. Оба результата **FAIL**, порог 1 пиксель не изменён. Независимый
субагент просмотрел кадры: SVG/обложки в текущей записи стали чётче, но слой
чернил остаётся неподвижным, пока другие слои уже перемещаются. Новая общая
проекция установленного слоя чернил ещё ожидает нативного и видео-прогона.

Диагностика системных инструментов, не приёмка: `Animation Hitches` для этого
Simulator завершился с `Hitches is not supported on this platform`. Проба
`Metal System Trace` не подтвердила начало записи за 60 секунд и не завершилась
по SIGINT; собственный процесс остановлен TERM. Следовательно, системный
процент пропуска кадров или отсутствие длительных main-thread остановок
этими файлами не подтверждаются. Поддерживаемый маршрут измерений ещё нужен.

### Более ранние диагностические проходы

В `.build/scene-native-owner-refinement-v3/ipad.xcresult` выполнено **98 нативных
проверок: 92 PASS / 6 FAIL**, без пропусков и runtime warnings. Simulator:
iPad Air 11-inch (M4), iOS 27.0 `24A434`, UDID
`CBDE7503-A0F7-4B92-85B5-626B9375E0FA`; Xcode 27 beta 5 `27A5237l`.
Прошли геометрия и большая книга, семь проверок нативной плоскости камеры,
захват видимой части большого WebKit-источника, жизненный цикл показа страниц
и большинство проверок неизменяемого внимания. Шесть отказов сохранены в
`summary.json`: две заготовки не создавали заявленное давление/общий тайл;
одна смешивала неподвижный тестовый текст с живой проекцией модели; три
относятся к новому общему WebKit документа и прежним ожиданиям его пула.
Исправления этих причин ожидают нового прогона; общий PASS не заявляется.

В `.build/acceptance-swift/document-block-versions.log` **7 Core-тестов PASS**
(один с двумя вариантами). Адресное чтение возвращает блок и точные причинные
версии исходника/состояния из одного снимка SQLite. При 100 000 посторонних
исторических состояний выполнено 335 SQL-инструкций; постороннее повреждённое
содержимое не декодировалось. Это проверка границы алгоритма на Mac, не RSS
или задержка Simulator.

Ранний Mac исполнитель прошёл **5/5 embedded XPC проверок** в
`.build/script-services-thread-fix/mac.xcresult`; итоговая квитанция этого
запуска отклонена из-за параллельного изменения других исходников. Новый
неизменный прогон добавляет startup recovery и настоящий PDF-экспорт.
Тогда MCP TypeScript check и **31/31 Node-тест** прошли; они не заменяют независимое
прохождение публичного API или разговор из Simulator.

Изолированная Release-пара и новое тестовое пространство подготовлены в
`.build/acceptance-bootstrap-release-1/`. Эта ранняя диагностическая сборка
уже не соответствует текущему коду. Mac UI runner остановлен системной
аутентификацией `Enable UI Automation` до запуска приложения. Сопряжение и
сквозной разговор этим запуском не подтверждены, системная защита не обходилась.
Самостоятельные нативные проверки и отдельный опыт камеры продолжаются.

Ещё не завершены: положительное сравнение baseline/current по всем кадрам,
реальные controls и навигация документов после последних исправлений,
независимая приёмка двух инструментов, синхронизированный сценарий пользователя
и агента, десять повторов, 30 минут смешанной работы, заданные p95 и системные
CPU/GPU/кадры/память. Видео и CADisplayLink не считаются системным FPS.

## 13 сентября — аудит сцены, ввода и MCP

[Отчёт](audit-2026-09-13.md) связывает симптомы с владельцами и содержит
12 находок, порядок исправления и проект сокращения MCP до двух входов.
[Свидетельства](audit-evidence/2026-09-13/README.md) включают переносимый
репродуктор четырёх ошибок MCP/IPC и точные результаты нативных проверок.
Это аудит; исполняемый код и установленная пара в этом изменении не менялись.

Проверен commit `fceadf0a7cc553813423f356908bf09574f79a15`, неизменный отпечаток
`995e15b0302b23d931693e09c0da2cf7202f9756e55dc536ee5824a60dd11f0f`.
В `.build/audit-20260913-selected/`: TypeScript check, **49 MCP PASS**, **1 Mac PASS**,
**14 iPad PASS / 7 FAIL**. Семь `SceneCameraPlaneTests` падают до проверки
освобождения: пустая заготовка после отбрасывания пустых тайлов не содержит
требуемого растра. Это дефект заготовки, не доказательство утечки приложения.
Общей положительной квитанции у этого запуска нет. Синтетическая книга
из 38 страниц холодно подготовилась за **3,783 s на Mac**; текущий тест
допускает до восьми секунд, что не является целевым временем удобного открытия.

`.build/audit-20260913-ui-density/verification.json`: дополнительные **2 PASS**,
без пропусков и runtime warnings. Подтверждены плотность одной таблицы рядом
с двумя обложками и нативное открытие документа с резким статическим снимком.
Сценарий не нажимает интерактивный контрол. Физическое отставание SVG от бумаги
при движении камеры, системные CPU/GPU/кадры/RSS и полная приёмка здесь не измерены.
Чтение установленного помощника показало `ready` и подключённый iPad;
PNG Mac не использовался как доказательство качества физического экрана.

## 13 сентября — компактные сообщения без шапки, 0.3.62 (65)

Из карточки текущей работы и тучек ответов убраны повторяющееся имя задачи
и значок расширения. Сам текст открывает прежнюю переписку; крестик находится
рядом с ответом и только скрывает его. Расчёт высоты больше не резервирует
место под удалённую шапку. Владельцы голоса, очереди и камеры не менялись.

`.build/compact-message-checked/verification.json`: **2 UI PASS**, без ошибок,
пропусков и runtime warnings. Проверены нажатие на сам ответ с открытием его
полной версии в текущем чате, сохранение черновика, закрытие тучки, перенос
панели без случайного открытия, Pencil и неизменность камеры при этих действиях.
Снимок `.build/compact-message-visual/BD4993B9-2C0A-4B34-A062-BC11D0E9424B.png`
проверен визуально: текст начинается рядом с крестиком, заголовка и стрелки нет.
Это целевой сценарий Simulator, не повторная физическая приёмка диктовки.
Отпечаток проверенных исходников:
`995e15b0302b23d931693e09c0da2cf7202f9756e55dc536ee5824a60dd11f0f`.

Подписанная пара установлена на Mac и физический iPad; фактическая версия обоих
приложений — **0.3.62 (65)**. Свидетельства: `.build/compact-message-release/build.json`
и `.build/compact-message-install-current/installed-readback.json`.
Независимая копия — `Notebook Backups/20260913-222659-before-compact-message`.
Первая подготовка остановилась до завершения приложений: во время сборки агент
изменил документ. Новая попытка сохранила уже эти изменения; архивы не восстанавливались.
Обратное чтение сохранило содержание, камеру, черновики, геометрию и доверие.
Единственное отличие состояния чата — первый срок показа одного нового ответа;
прежние сроки, черновик и очередь не менялись. Отдельная проверка этого отличия
сохранена в `audit-readback.py`, первоначальный отказ полного сравнения не скрыт.
Установленный помощник отвечает `ready`, физический iPad подключён, вид готов.

## 13 сентября — единая компактная панель и исходный звуковой поток, 0.3.61 (64)

Подтверждённый дефект 0.3.60: тихий вход обнулялся в визуальной шкале, а
постоянный фон мог бесконечно удерживать запись. Окончание теперь определяет
непрерывный анализ PCM у владельца аудиопотока; UI получает только объединяемые
измерения. Фон сохраняется при переходе от обращения к записи, распознаватель
имени больше не содержит второй акустический анализатор. Контроллер получает
отдельное непотерянное завершение с UUID и позицией звука. Нет опроса `sample()`,
старого определителя паузы или `activationEnabled`.

Карандаш раскрывает текущую переписку; стрелка вниз и промежуточный редактор
удалены. Запись занимает прежний бар высотой 48 pt, а в полном чате — существующую
строку управления под сохранённым черновиком. Автоматическая подготовка ожидания
не блокирует редактор и не сбивает клавиатуру. Диктовка по GPT отправляется
после 1,4 секунды паузы, ручная кнопка оставляет редактирование. Явное выключение
микрофона сохраняется отдельно; фон, отмена, повторное обращение и смена задачи
не превращают его в временный флаг записи.

`.build/unified-dictation-accepted/verification.json`: **35 Core/Codex, 15 Mac,
65 iPad/UI**, 3 проверки голосового аудиопотока, 40 выпуска и 27 маршрута.
Шесть UI-сценариев проверили запись, ручное редактирование, одну отправку,
самостоятельное исчезновение и закрытие ответа, вложения, клавиатуру и терминал.
Проверены настоящий AAC, тихая речь, постоянный синтетический фон, короткие
внутренние паузы, имя без просьбы, последовательные обращения, форматы/каналы,
разрыв PCM, отмена и восстановление прежних квитанций. Ошибок, пропусков и
runtime warnings нет. На ранних проходах исправлены устаревшие ожидания
мини-формы, фокус после подготовки микрофона и системная ошибка `contextMenu`;
меню микрофона теперь использует обычный `Menu` с действием по нажатию.

Последнее изменение — приоритет переноса панели перед нажатием карандаша.
`.build/unified-dictation-final/verification.json`: **2 UI PASS**, без ошибок,
пропусков и предупреждений. Настоящее перетаскивание не открывает чат;
следующее нажатие открывает его, сохраняя черновик, полный ответ, камеру и чернила.
Между объединённой проверкой и этим повтором изменились только компаньон и
его жестовый тест; звуковые владельцы, очередь и транспорт неизменны.
Итоговый отпечаток: `d713657d20a475db128ddabed16e735e3836b4f6bcf1dccee4c805356c14b11a`.

`.build/unified-audio-probe/`: настоящий локальный Speech на Mac принял
русскую и ослабленную русскую запись за **1,90 с**, английскую — **1,40 с**,
русскую с добавленным постоянным синтетическим фоном — **2,80 с** от начала
аудиозаписи. Одно имя принято без просьбы, упоминание внутри фразы отклонено.
Это не живой микрофон iPad. Исходные уровни, задержка обработки блока и позиции
окончания остаются в ограниченной частной сводке; журнал отдельно отмечает
задержку шкалы, доставки завершения и переходов распознавания, без текста речи.
Эти подготовленные записи не заменяют проверку физического iPad.
Результат живого сценария приведён ниже; весь milestone не объявляется завершённым.

Подписанная пара 0.3.61 (64) установлена на прежние Mac и физический iPad:
`.build/unified-dictation-release/build.json`,
`.build/unified-dictation-install/installed-readback.json` и `installed-ipad-app.json`.
Независимая копия — `Notebook Backups/20260913-220005-before-unified-dictation`.
Перед заменой не было активного звонка, процесса терминала, записи диктовки
или недоставленного локального действия. Обычное завершение помощника и
обратное чтение подтвердили неизменность содержания, камеры, геометрии чата,
122 записей поручений, черновиков и сопряжения; неопределённая отправка не
повторялась. Установленный помощник отвечает `ready`, iPad подключён, текущий
составной вид готов.

**Физическая проверка, 22:11 МСК:** Амир подтвердил, что при свёрнутом чате
без дополнительных настроек шкала движется, просьба сама отправляется после
паузы и повторное обращение работает. `.build/unified-dictation-install/physical-acceptance.json`
связывает последнюю запись с одним принятым поручением. Настоящий вход — 48 кГц,
RMS 0,0000365–0,0016204, видимый диапазон 0–0,834; окончание отмечено ровно
после **1,4 с** паузы. Наибольшая задержка обработки PCM — **5,05 мс**,
от закрытия AAC до сохранения просьбы — **2,08 с** (передача и распознавание вместе).
Численное отставание рисунка и чистое время сервиса отдельно не извлечены:
чтение журналов подключённого iPad потребовало административного доступа,
который не запрашивался. В сводке нет текста или звука речи. Этот подтверждённый
цикл не выдаётся за всю физическую приёмку Pencil и milestone.

## 13 сентября — границы голосовой реплики и жизненный цикл тучек, 0.3.60 (63)

Физический ответ Амира по 0.3.59 выявил задержку, пропуски после GPT,
неподвижную индикацию записи и тучку, оставшуюся после закрытия. Причина
задержки воспроизведена: локальный распознаватель выдаёт слова раньше их
временных меток; прежний допуск ждал конца фразы, затем повторно ждал тишину.
Новый системный DictationTranscriber в отдельном опыте также не дал ранних
точных границ слов, поэтому замена API сама по себе не принята как исправление.

Теперь исходные звуковые кадры ограничивают одну реплику до классификации
имени. Периодический повтор хвоста удалён; длинная неадресованная речь не
перезапускает распознавание посередине. Тот же микрофон продолжает запись;
черновик и очередь поручений не заменены. Шкала читает обновления амплитуды
в наблюдаемом представлении. У тучек отдельные сроки и закрытие по ID;
непрочитанное сообщение больше не удерживает пустую карточку на доске.

`.build/wake-flow-verified/verification.json`: **33 Core/Codex, 14 Mac,
58 iPad/UI**, 40 проверок выпуска и 27 маршрута; без ошибок, пропусков
и runtime warnings. Отпечаток исходников:
`f415535b5e1b33a3bd8f1b41a40bdfce176a02e3e5fce494802cc388fa83ecaf`.
Четыре жестовых сценария проверили запись и редактирование, автоматическую
единственную отправку, закрытие всей тучки, её истечение без раскрытия чата,
чтение полного ответа и сохранность Pencil, камеры и черновика. Ранние сборки
обнаружили оставшуюся ссылку на одиночное превью и требования Swift к захвату
полей в журнал; исправлены. Старое ожидание тестом постоянной карточки после
завершения работы заменено проверкой полезного ответа и полного закрытия.

`.build/wake-latency/receipt.json`: на одной русской записи допуск обращения
сократился с **5,61 до 1,90 секунды от начала речи**, до завершения просьбы.
Проверены русский и английский, английское обращение при русском языке,
16 секунд ожидания, имя без просьбы, предшествующая реплика и ослабленная
в 12,5 раза запись. Два неадресованных примера не активировали диктовку.
Codex через прежнюю авторизацию отдельно распознал синтетический AAC за
**1,29 секунды**, HTTP 200; секреты не записывались.
Это реальные системный распознаватель и сервис, но не живой микрофон iPad.
Шумная комната, собственное произношение и субъективная задержка после установки
остаются отдельной физической приёмкой; весь milestone не объявляется завершённым.

Подписанная пара установлена в прежние приложения на Mac и физическом iPad:
`.build/wake-flow-release/build.json`, `.build/wake-flow-install/installed-readback.json`.
Свежая независимая копия — `Notebook Backups/20260913-200458-before-wake-flow`.
Обратное чтение подтвердило неизменность содержания, камеры, геометрии чата,
сопряжения, черновиков и прежних записей поручений; неопределённая отправка не
повторялась. Установленный помощник отвечает `ready`, iPad подключён, составной
вид готов. Ожидание микрофона после перезапуска выключено. Запрошена проверка
живого обращения Амиром; её результата пока нет.

## 13 сентября — обращение GPT отправляет диктовку, 0.3.59 (62)

По «GPT», «Слушай GPT» или «Hey GPT» тот же владелец диктовки принимает
просьбу, завершает запись после 1,4 секунды тишины и отправляет результат
через обычную очередь текущей задачи. Напечатанный черновик остаётся нетронутым.
Обычная кнопка микрофона сохраняет стоп с редактированием; кнопка разговора
по-прежнему сразу начинает звонок. Ожидание явно включается удержанием
микрофона и переключателем «Включать по GPT»; его значок выключает захват.

Один AVAudioEngine продолжает звук от локального обращения до AAC, без второго
запуска и потери начала просьбы. До обращения десятисекундный буфер остаётся
в памяти; ограниченная очередь и запись работают вне UI. Имя само по себе ждёт
следующую реплику, а не отправляет пустое сообщение или старый черновик.
UUID записи используется прежней очередью сообщений: восстановление уже
сохранённого поручения не вставляет и не отправляет его повторно. Ошибка
сохраняет запись и возвращает явный повтор к проверке текста.

Итоговая квитанция `.build/dictation-wake-checked/verification.json` подтверждает: **31 Core/Codex,
13 Mac и 51 iPad/UI проверка**, а также проверки маршрута выпуска; ошибок,
пропусков и runtime warnings нет. Три настоящих жестовых сценария Simulator
проверили ручную диктовку, редактирование, автоматическую отправку из компаньона,
тучку единственного ответа, выключение ожидания и сохранность камеры/чернил.
Нативные проверки дополнительно читают настоящий AAC после отсечения
предшествующего звука, проверяют истёкший буфер, разрыв PCM, конец фразы,
выключение при смене задачи/фоне и восстановление той же записи очереди.

Первоначально UI-проверки нажимали по старой геометрии во время раскрытия
системной клавиатуры, а переключатель — по тексту вместо тумблера. Проверки
теперь дожидаются реального положения клавиатуры и касаются видимого тумблера;
повторные нажатия и произвольное увеличение ожиданий не добавлены.
Подготовка микрофона использует публичный throwing tap API iOS 27, а не
устаревший путь с исключением Objective-C. Первое свидетельство без явно
названного жеста было отклонено сборщиком; это не заменялось обходом допуска.

`.build/dictation-wake-acoustic/receipt.json`: выпускаемый локальный
распознаватель на Mac принял русское обращение с просьбой, короткое имя,
английское обращение (также при русском языке) и правильно нашёл начало
после шестнадцати секунд ожидания. Две фразы с упоминанием/без имени не
активировали ввод. Синтетическое английское аудио прямо с нулевого кадра
Speech распознал как «Play GPT» и не принял; после секунды ожидания тот же
«Hey GPT» принят. Опасный нечёткий псевдоним не добавлен. Это подготовленное
аудио на Mac, не подтверждение живого голоса, акустического уровня и пауз на iPad.
Работа при блокировке и вне Notebook не обещается.

Пара **0.3.59 (62)** собрана из отпечатка
`d9bdfbedccf4b26685c71f4d71c96daa750658701d6468032580b7c555d2b292`
и установлена на прежние Mac и физический iPad. Перед обновлением проверено
отсутствие активного Pencil, диктовки, терминала и незавершённого звонка;
помощник завершён обычным путём, без сигнала. Независимая копия:
`/Users/amir/Documents/Notebook Backups/20260913-185502-before-wake-dictation`.
`.build/dictation-wake-install/installed-readback.json` подтвердил неизменность
содержания (1529 Mac / 1493 iPad записи), камеры, геометрии чата, черновиков,
118 запросов и доверия; прежний неопределённый запрос не повторялся.
Микрофон после установки выключен. Амиру предложена проверка включения и
живой просьбы без стрелки отправки; её результат ещё не получен.

## 13 сентября — явная камера и исчезающие SVG агента, 0.3.58 (61)

`notebook_present` передаёт короткую последовательность приближений, перемещений
и временных SVG через установленного Mac-помощника. Камера остаётся у
`SessionPresence`, а движение — у существующего механизма завершения жестов;
отдельного сохранённого вида, выделения или очереди поручений нет. Ручной ввод
синхронно прерывает показ. Одноразовый адрес текущего вида, срок доставки и ID
отделяют повторное чтение результата от повторного исполнения. SVG рисуется
прозрачным векторным WebKit без JavaScript, сети, касаний и записи в содержание;
аренда поверхности освобождается после завершения. Открытый лист сохраняет
заданный зум, вместо повторного принудительного вписывания в экран.

Итоговая квитанция `.build/presentation-ipc-check/verification.json` подтверждает
**19 Core/Codex, 3 Mac и 21 iPad/UI проверки**, включая два жеста Simulator,
а также MCP и маршрут выпуска; ошибок, пропусков и runtime warnings нет.
Исходники `cdd169872121ad99730a8eb8db49950ff6d34f21293dbca16da4d9b7ca081002`.
Проверены настоящий сокет с полным сценарием и отменой, повтор ID, чужая
квитанция, потеря связи, принятый Pencil, открытая бумага и сохранённое стирание,
прозрачные пиксели SVG и освобождение ресурса. Первая установленная попытка
0.3.57 выявила дублирующий список полей IPC: чтение проходило, сценарий
отклонялся до исполнения. Этот список удалён; допустимые поля теперь берутся
из единственного описания сериализации команды. Ошибка сохранена в
`.build/presentation-install/proof.log`, полный запрос добавлен в проверку.

Пара `.build/presentation-ipc-release/build.json` установлена на Mac и физический
iPad. До завершения приложений повторно проверено отсутствие активных ввода,
диктовки, звонка, терминала и ожидающей доставки. Сохранность текущих данных,
камеры, геометрии чата и доверия подтверждает
`.build/presentation-ipc-install/installed-readback.json`; резервная копия —
`/Users/amir/Documents/Notebook Backups/20260913-170806-before-presentation`.
Исторические архивы не восстанавливались, неподтверждённое поручение не повторялось.

Установленный MCP исполнил на физическом iPad сценарий
`d38ad15b-e2b4-4531-8757-47de51a041eb`: камера приблизилась и сместилась, SVG
появился, исчез, затем явный заключительный шаг вернул исходную камеру точно.
Снимки `presentation-during.png` и `presentation-after.png` просмотрены;
квитанция `presentation-proof.json` завершена, повтор того же ID не запустил
новый показ. `presentation-content-proof.json` подтверждает неизменность всех
1529 записей Mac и 1493 iPad, включая выделение, чернила и разговор; SVG не сохранён.
Все эти файлы находятся в `.build/presentation-ipc-install/`. Прерывание новым
живым Pencil-жестом на физическом iPad не заявляется проверенным. Полная
приёмка milestone, предыдущие жалобы на живые жесты и второй Mac остаются открыты.

## 13 сентября — согласованная камера и защита стирания от случайной отмены, 0.3.56 (59)

Сопоставлены независимые копии текущих SQLite Mac и iPad. Все 61 действие
пространственных чернил совпадают по исходнику и состоянию; 25 заголовков
различаются только локальным индексом порядка. Последнее стирание
`BFCEB830-C62D-4AE1-850A-DD119581EBE6` записалось на iPad в последовательности
85, а в 197 было деактивировано тем же iPad: версия 75 → 76. Поэтому сохранность
данных при предыдущем обновлении не доказывала сохранность намерения стереть.
Сам жест в историю не записан; его случайная трактовка проверена отдельно,
а не выдана за наблюдение действий Амира. Отчёт —
`.build/camera-erase-investigation/forensic-summary.json`.

`SceneCameraPlane` теперь устанавливает новую раскладку тел и матрицу одним
обновлением: старое тело не показывается под новой камерой. Присоединение
пальца к начатому движению или длительному касанию не становится отменой.
Движение после удержания прекращает повторные отмены и продолжает одну камеру.
Однопальцевый сдвиг сохраняет измеренный путь до распознавания UIKit; второй
палец не меняет эту опору. Обычное короткое касание двумя пальцами сохраняет
действующую отмену. Чернила, запись и сетевая доставка не получили новых владельцев.

`.build/camera-erase-red` воспроизводит три исходных нарушения. Итоговая квитанция
`.build/camera-erase-verified-check/verification.json` подтверждает **2 Mac и
64 iPad/UI проверки**, без ошибок, пропусков и runtime warnings; исходники
`a3668a75c96a18190f4b889c6421cf7bf41ed615f99f44d950c567455b487c83`.
Проверены сохранённое стирание после повторного чтения, один вызов намеренной
отмены, прекращение отмен при движении и Pencil, синхронные координаты настоящих
нативных тел, Metal-чернила и четыре жестовых сценария Simulator.
Расширенная промежуточная проверка обнаружила потерю 29,5 пункта при начале
сдвига — исправлено измерение, допуск теста не расширялся. Дополненный тест
намеренной отмены сначала оставлял модель в режиме листа при показе доски;
фикстура теперь явно открывает доску. Оба отказа сохранены в
`.build/camera-erase-release-check` и `.build/camera-erase-final-check`.

Подписанная пара `.build/camera-erase-release/build.json` установлена на Mac
и физический iPad. Резервная копия
`/Users/amir/Documents/Notebook Backups/20260913-161527-before-camera-erase`
и `.build/camera-erase-install/installed-readback.json` подтверждают неизменность
1529 записей Mac и 1493 iPad, кроме состояния ввода. Камера совпала точно,
сохранены черновики, история, очередь, геометрия чата и сопряжение. Перед обычным
завершением не было активных Pencil, диктовки, звонка или терминала. Неподтверждённое
поручение не отправлялось повторно. Снимок установленного iPad `ipad.png`
просмотрен: текущие доска, документы, чернила и таблица видны; уже вернувшиеся
штрихи вручную не удалялись. Движение камеры и новое стирание живыми жестами
Амира на физическом iPad ещё не подтверждены; полная приёмка остаётся открытой.

## 13 сентября — открытие документа, возврат к доске и начало зума, 0.3.55 (58)

Чтение отсутствующего выбранного документа подключено к существующему адресному
чтению сцены. Тело соседних книг больше не загружается ради их обложек; поздний
ответ сохраняет границы выбора, черновика, версии и принятого Pencil. Закрытая
обложка не удерживает невидимый читатель. Одиночный перенос камеры получает
непрерывное смещение UIKit, а не меняющуюся позицию второго касания. Названия
действий Notebook объясняют чтение, размещение и проверку результата; исходные
имена доступны в подробностях, ID и доставка не меняются.

`.build/document-selection-red` воспроизвёл отсутствие текста и состояния после
выбора незагруженного документа без внешнего обновления. Завершающая квитанция
`.build/document-return-final-check/verification.json` подтверждает **34 Core/Codex
и 39 iPad/UI проверок**, без ошибок, пропусков и runtime warnings; исходники
`559b6f2ad6839ae5a2ce788a5781b93e1cd39daebd684f05bf275f56e0550d9a`.
Настоящий WebKit открывает документ, после возврата видимая закрытая обложка
остаётся смонтированной без скрытых страниц. Проверены плотность изображения
таблицы и тонкие полосы непосредственно на экране, сохранность источника и
чернил. Жесты Simulator проходят закрытие листа, открытие и закрытие портала,
сгиб обложки документа. Последовательное прибытие касаний проверено у владельцев
смещения и двухпальцевой пары; это не физическое подтверждение жеста пользователя.
Изображения находятся в `.build/document-return-final-attachments`.

Предварительные `.build/document-selection-baseline`, `.build/document-return-check`
и `.build/document-return-check2` сохранены: исправлены обязательный размер бумаги
в фикстуре, полное чтение маленького тестового каталога и подмена измерения UIKit
без настоящих контактов. Полный многочасовой прогон и физическая приёмка этого
среза не заявлены. Амир пока не смог проверить и ответ-тучку из 0.3.54.

Проверенная пара `.build/document-return-release` установлена поверх 0.3.54
на прежние Mac и физический iPad. Независимая копия
`20260913-153905-before-document-return` и
`.build/document-return-install/installed-readback.json` подтверждают сохранность
1529 текущих записей Mac и 1493 iPad, неизменяемой истории, черновиков, очереди
и доверия. Перед обычным завершением не было активных звонка, диктовки, терминала
или принятых касаний. Первое строгое сравнение заметило переиздание `last-context`:
масштаб `0.16815256695624736` стал `0.1681525669562474`, ровно один шаг Double;
центр и все прочие поля совпали побитно. Эта конкретная разница проверена отдельно,
а не скрыта общим допуском. Физический снимок `ipad.png` просмотрен: доска, чернила,
таблица и текст ответа в компактной карточке видны. Свежая диктовка и живые
жесты открытия/возврата/последовательного касания пальцами пока не подтверждены.

## 13 сентября — ответ после диктовки в компаньоне, 0.3.54 (57)

Компактная карточка показывает последний полезный завершённый ответ, а не
один счётчик. Превью ограничено шестью строками, открывает тот же native ID
в полной переписке и закрывается без удаления сообщения или отметки
непрочитанного. Место закрытия хранится у прежнего владельца чтения, отдельно
для выбранных компьютера и задачи. Голосовой разговор и необходимые вопросы
не заменяются текстовыми тучками.

`.build/dictation-reply-release-check/verification.json` подтверждает **18 Core,
11 Mac и 37 iPad/UI проверок** без ошибок, пропусков и runtime warnings,
исходники `643c5e80f87c82988c61103ade433bea6c10b6419c51a12ae42ca56a3052716b`.
Жесты проверили непосредственную отправку диктовки, сам текст ответа в
свёрнутом виде, раскрытие полного ответа, закрытие превью, сохранённый черновик,
поворот и принятый штрих на доске. Диктовка и ответ сервиса здесь синтетические;
это проверка представления и единственной доставки, не акустической точности.
Предварительные расширенные сценарии сохранены в `.build/dictation-reply-check`
и `.build/dictation-reply-final`: первый остановился на подмене Pencil обычным
пальцем внутри листа, второй — на старом дополнительном сценарии ручного ввода
с движущейся клавиатурой. Решающий жест теперь адресует пространственный Pencil;
отправку проверяет отдельный полный сценарий диктовки, а не косвенное исчезновение
текстового поля.

Проверенная пара из `.build/dictation-reply-release` установлена поверх 0.3.53.
Независимая копия `20260913-150953-before-dictation-reply` и обратное чтение
`.build/dictation-reply-install/installed-readback.json` подтверждают прежнее
содержание, неизменяемые записи, черновики, очередь, камеру, геометрию чата и
доверие. Перед обновлением не было активных диктовки, звонка, терминала или
неотправленных действий. Физический снимок после запуска просмотрен; свежая
диктовка пользователя с получением тучки ещё не подтверждена. Новые замечания
о загрузке документов, размытии возврата, двухпальцевом жесте и подписях
инструментов не объявлены исправленными этим выпуском.

## 13 сентября — единая строка диктовки, отправка и просмотр черновика

После физического подтверждения распознавания Амир потребовал два исхода
в одной строке записи, по присланному изображению. Стоп раскрывает чат и
переводит распознанный черновик в редактирование; стрелка использует обычную
отправку с контекстом и вложениями, зафиксированными при нажатии. Отмена,
ошибка и перезапуск не сохраняют скрытое намерение отправить текст после повтора.

Первый изолированный проход `.build/dictation-ux-first` исполнил **25 iPad/UI
проверок** без ошибок, пропусков и runtime warnings. Настоящие жесты Simulator
проверили единую строку, стоп, раскрытие, фокус, редактирование, обычную отправку
и немедленную отправку следующей диктовки ровно по одному разу; камера и
принятые чернила сохранены. Отдельные проверки покрывают отмену, двойное
нажатие, ошибку/повтор, автоматическое окончание и фиксацию прежнего внимания
и вложений при изменении выбора во время распознавания. Снимки из
`.build/dictation-ux-first-images` просмотрены. Микрофон и ответ сервиса в этом
жестовом сценарии синтетические; новый физический UX пока не принят.

Дополненный проход `.build/dictation-ux-checked` исполнил 41 iPad/UI проверку,
но расширенный жест остановился на поиске контейнера в полном чате:
SwiftUI объединяет единственного ребёнка с существующим
`notebook-chat-composer`. Иерархия доступности подтвердила обе кнопки внутри
этого владельца. Исправлен только адрес контейнера в тесте, затем повторён
весь выбранный набор, без изменения поведения приложения.

Окончательная `.build/dictation-ux-final-checked/verification.json` подтверждает
неизменный срез **0.3.53 (56)**, SHA-256
`2eb9b0c8856ce7978bfbfdef4391e0c77381c7ee05b332fe936f33771b0ab215`:
**19 Core + 4 Codex HTTP + 13 Mac + 42 iPad/UI**, вместе с **40 проверками
сборщика + 27 выбора маршрута**, без ошибок, пропусков и runtime warnings.
Проверены обе формы записи, включая отмену в раскрытом чате и сохранение
прежнего черновика. Срез включает проверенное покрытие доски `a134cac`;
полная физическая приёмка не подменяется этим выбранным набором.

Подписанная пара `.build/dictation-ux-release` установлена как **0.3.53 (56)**
на прежние Mac и iPad. Независимая копия
`20260913-143114-before-dictation-input` проверена до обновления, а
`.build/dictation-ux-install/installed-readback.json` после запуска подтверждает
сохранность 1517/1485 записей, 114 запросов, двух файловых черновиков, текста
чата, камеры, геометрии панели и доверия. Перед обычным завершением проверены
отсутствие активной диктовки, звонков, терминалов, Pencil-контакта и недоставленных
изменений. Исторические архивы не восстанавливались. Установленный MCP вернул
`ready`, соединение с iPad — `connected`. Амиру предложена физическая проверка
новых действий стоп/редактирование и отправка; ответ пока ожидается.

## 13 сентября — появление новой области до окончания движения камеры

Амир на физическом iPad 0.3.50 подтвердил чёткость приближённой таблицы и
сообщил об отдельной задержке появления тетрадей и элементов при отдалении.
`ZoomOutCoverageTests` воспроизвёл её на исходном коде `3c1505f`: две тетради
и SVG находятся в одном сохранённом пространстве, но дальняя тетрадь и схема
не появляются за весь непрерывный жест. Диагностика фиксирует активную камеру
и отсутствие подготовки; снимок окна показывает только исходную тетрадь.
Отрицательное свидетельство — `.build/zoom-out-coverage-red`.

Разрешение готовить покрытие отделено от прочей фоновой работы. Текущий
запрос больше не отменяется каждой новой координатой: прежний владелец
подготовки сохраняет только последний следующий вид. Два пробных запуска
`.build/zoom-out-camera-red` и `.build/zoom-out-camera-green` остановились
раньше жеста из-за передачи оконной проекции вместо полного синтетического
каталога; эта ошибка фикстуры исправлена, результаты не считаются проверкой
пользовательского дефекта.

`.build/zoom-out-coverage-green` прошёл **3/3 iPad-теста**. Тетрадь и схема
появились в настоящем окне Simulator через 1,56 секунды от начала движения,
до отпускания. Проверены камера, исходник, чернила, предел памяти и очередь
WebKit. Контакт с содержимым и принятый Pencil сохраняют запрет подготовки;
увеличение внутри готовой области не пересоздаёт изображение до отпускания.
Само отпускание на тех же координатах возвращает читаемую плотность таблицы.
Заключительный набор `.build/zoom-out-release-checked` прошёл **3 Mac +
18 iPad**, без ошибок, пропусков и runtime warnings, поверх проверенного
исправления диктовки `dba99d1`. SHA-256 исходников:
`7e6a5872c0811f62d51d3ca73fbc352de0aa48110dcd228f4307d447270cb2ea`.
Проверены публикация правок, собственный ввод, перенос проекции, адресное
чтение родителя, сохранение текущего и только последнего следующего запроса,
отмена, завершение и освобождение ресурсов. Дальние предметы появились
через 1,60 секунды до отпускания. В плотной доске p95 дисплейных интервалов
Simulator — 50,00 мс, максимум — 166,69 мс; на доске со схемами — 16,70 и
16,77 мс. Это обслуживание дисплейных вызовов, не измерение GPU FPS iPad.

Предшествующий набор `.build/zoom-out-final-checked` дал 3 Mac + 16 iPad PASS
и два отказа камерных проверок. Один снимал первую промежуточную композицию
при `preparing=true`, включая начальную подготовку в измерение жеста; оба
требовали неизменной композиции при любом отдалении, что исключало появление
новой области. Теперь перед измерением ждут завершения начальной подготовки,
а число показанных композиций ограничено четырьмя вместо запрета расширения.
В итоговом проходе их было одна и две; прежние 10 секунд начальной подготовки,
порог p95 < 100 мс, предел памяти, пиксели и проверки WebKit не ослаблялись.
Отдельный повтор этих двух сценариев также прошёл в
`.build/zoom-out-camera-regressions`.

Подписанная пара из `.build/zoom-out-release-aligned` установлена как
**0.3.52 (55)** на прежние Mac и физический iPad. Независимая копия
`20260913-141732-before-zoom-out` и
`.build/zoom-out-install/installed-readback-repeat.json` подтверждают сохранность
всех прежних записей и неизменность содержания, камеры, геометрии чата,
114 запросов, двух файловых черновиков и доверия. Незавершённой диктовки,
активного звонка, терминала и принятого контакта перед обновлением не было.
Установленный MCP отвечает `connected` и `ready`; физический снимок просмотрен,
таблица остаётся чёткой на прежнем месте и при прежнем масштабе.

Первый сборщик отказал после добавления диагностического экспорта в уже
закрытый каталог свидетельств. Экспорт перенесён отдельно, исходная квитанция
снова совпала побайтно; тесты не переименовывались в успешные задним числом.
Первая последовательная копия SQLite/WAL iPad после запуска также не прошла
проверку целостности. Она сохранена; новое независимое чтение прошло все
проверки без изменения или восстановления живой базы. Обе резервные базы и
живая Mac-база проходили проверку целостности и до повторного чтения.
Это не полная приёмка приложения. Амиру предложено проверить появление
дальних предметов при отдалении; физическая скорость пока не подтверждена.

## 13 сентября — диктовка в черновик через текущую авторизацию Codex

Предыдущая надпись «Диктовка Codex недоступна» была заглушкой. Исследование
полного клиента показало, что список экспериментальных методов App Server
не исчерпывает его действительный интерфейс: установленный Codex использует
`getAuthStatus(includeToken: true)` и отдельный `/backend-api/transcribe`.
Новый выпускаемый Swift-адаптер прошёл этот путь с текущим входом ChatGPT,
без credential-файлов, отдельного API-ключа и создания хода. Для синтетической
русской AAC-записи 32 274 байта за 0,907 секунды получено
«Слушай, GPT, объясни эту формулу.» —
`.build/dictation-investigation/native-transcription.log`.

На iPad реализованы явная запись, индикатор, завершение, отмена и восстановление
частного аудиофайла. Порции до 96 КиБ проходят прежнее доверенное соединение;
Mac проверяет владельца, порядок и SHA-256, удерживает один запрос на запись
и не повторяет его по потерянной квитанции. Сохранённый результат дописывается
в исходный черновик одной транзакцией с UUID квитанции. Запоздалые ответы,
повтор и перезапуск не дублируют слова и не создают поручение. Предел черновика
не обрезает текст; при ошибке его можно сократить и повторить вставку.

Промежуточный целевой набор `.build/dictation-fifth-checked` прошёл 19 Core,
4 Codex HTTP, 13 Mac и 22 iPad/UI проверки, а также 40 проверок сборщика и
27 маршрута проверки. Ошибок, пропусков и runtime warnings нет. Исполнены
настоящий TLS с полной порцией аудио, восстановление, отмена, чужое устройство,
неоднократная квитанция, запрет звонка во время диктовки и гонка обычного
сохранения панели с вставкой результата. UI-жесты проверили микрофон рядом
с голосом, обе формы чата, сохранность черновика и бумаги при недоступном Mac;
снимки `.build/dictation-ui-images` просмотрены. Первые проходы исправляли
компиляцию новых XCTest-фикстур; этот набор не выдаётся за физическую запись.

Окончательный неизменный набор `.build/dictation-checked` прошёл **19 Core +
4 Codex HTTP + 13 Mac + 23 iPad/UI**, а также **40 проверок сборки + 27 выбора
маршрута**, без ошибок, пропусков и runtime warnings. Он добавляет отказ захвата,
пока предыдущее сообщение сохраняется. Жестовый селектор указан явно;
`.build/dictation-final-cut` имеет SHA-256
`7a6350bce49d96f09525a1730ccfa694477f33bec5c00b5f767b41e6a1adb257`.
Первая подписанная пара 0.3.51 (54) собрана в `.build/dictation-release`, но
не установлена: найден отдельный переход «отменить при обрыве → новая запись».
Сохранённая отмена теперь доходит до Mac перед следующим захватом и переживает
перезапуск между записью отмены и удалением аудио. Дополненный неизменный набор
`.build/dictation-complete-checked` прошёл **19 Core + 4 Codex HTTP + 13 Mac +
25 iPad/UI**, вместе с прежними 40 проверками сборки и 27 выбора маршрута,
без ошибок, пропусков и runtime warnings. Его исходный SHA-256:
`81cf136114c87c790a4fb711d4a47a4f848c384c870fcaae7bd49e4df983adf7`.
Окончательная подписанная пара из `.build/dictation-final-release` установлена
на прежние Mac и физический iPad как **0.3.51 (54)**. Новая независимая копия
`20260913-140626-before-codex-dictation` и обратное чтение
`.build/dictation-final-install/installed-readback.json` подтверждают сохранность
содержания, двух файловых черновиков, 114 запросов, 178 строк вывода терминала,
камеры, геометрии чата и доверия. Активных звонков, терминалов, принятого
Pencil-ввода и недоставленных изменений перед обновлением не было. Mac завершён
обычным AppKit-действием, без принудительного сигнала. Установленный MCP
отвечает, пара подключена, снимок физического iPad просмотрен.

13 сентября в 14:11 МСК Амир подтвердил решающий физический опыт: произнесённый
текст появился в черновике на iPad. Это принимает микрофон, передачу и
распознавание через текущий вход для данного сценария. Одновременно запрошен
следующий UX: отправка либо стоп с раскрытием чата для редактирования.
Его новая проверка описана выше; одно произнесение не измеряет общую точность.

## 13 сентября — чёткость существующей таблицы после небольшого увеличения

На установленном iPad 0.3.49 таблица `gpt-token-embedding-table` оставалась
размытой при масштабе `0.7027193990126275`. Снимки до изменения и прочитанный
источник сохранены в `.build/table-render-investigation`: содержимое — SVG
с настоящим текстом, не вставленная фотография. Источник, положение и размер
таблицы не редактировались.

`SceneCompositionTiles.covers` смешивал достаточную область покрытия с
достаточной плотностью изображения: небольшое увеличение до 1,6 раза оставляло
прежний кадр и не запрашивало более подробный растр. Проверка настоящего
`SpatialWorkspaceView` воспроизвела путь обзор → 0,5 → 0,7027: после завершения
увеличения смонтированное изображение оставалось шириной 997 пикселей вместо
необходимых 1400. Отрицательный результат — `.build/table-render-nearby-zoom-red`.
Теперь завершённое увеличение готовит плотность через прежнего владельца;
уменьшение переиспользует достаточное изображение. Новый тест проверяет 1401
пиксель в смонтированном слое, чёрные и светлые границы тонких полос, один
представитель таблицы и неизменность камеры, исходника и чернил.

Широкий локальный набор не объявлен полным PASS. Семь старых проверок завершения
представления ожидают выделенный растр на пустой доске, где он больше не нужен;
ещё одна проверка портала не создаёт ожидаемого давления на память. Все восемь
отказов воспроизведены с прежним условием 0.3.49, без изменения их ожиданий:
`.build/table-density-old-lifetime-baseline` — 5 успешных, 8 неуспешных. Они
остаются в GUI-190. В двух общих запусках подготовка плотной доски не уложилась
в 10 секунд до начала движения камеры; отдельный неизменённый тест прошёл
в `.build/table-density-dense-repeat`. Повтор последовательности с прежним
условием и без нового теста также прошёл; причина зависимости от состава
набора не установлена и не объявляется исправленной этим срезом.

Завершённый целевой набор `.build/table-density-isolated-checked` — **3 Mac +
10 iPad** без ошибок, пропусков и runtime warnings. Он включает новую таблицу,
плотную доску, большую доску со схемами, публикацию правок, принятый ввод,
перенос и завершение движения камеры, соседство таблицы с двумя обложками и
порядок растров. Отпечаток исходников —
`d70210c44f11724b3a62639fbaf22adc2494c17b622ef03f5abb52299729abab`.
Проверка и сборка ведутся в отдельной копии этого среза: параллельные незавершённые
изменения диктовки из другого задания не включены и не изменены. Метрики
CADisplayLink остаются интервалами callback в Simulator, не системным FPS iPad.

Пара **0.3.50 (53)** из `.build/table-density-release-aligned` установлена на
Mac и физический iPad. До обычного завершения помощника свежие снимки обоих
хранилищ совпали с независимой копией
`/Users/amir/Documents/Notebook Backups/20260913-130428-before-table-density`;
активных звонков, терминалов, доставки и принятого ввода не было.
После запуска с iPad пришли новые выделения, перемещение таблицы с отметкой
`20@59adbe6e-f995-48ec-857a-26e7e3513d80` и уменьшение камеры до `0.051411983191661265`.
Поэтому строгая проверка «все текущие записи неизменны» закономерно отказала;
новое положение не откатывалось ради совпадения снимков. Отдельное обратное
чтение `.build/table-density-install/installed-readback-with-live-edits.json`
подтверждает сохранность всех прежних неизменяемых записей, источника и размера
таблицы, чернил, 114 запросов, двух черновиков файлов, чата и доверия. Изменились
только перечисленные новые записи положения, выбора и присутствия iPad.
Установленный MCP читает прежнюю доску, физический снимок показывает её без
ошибки загрузки. В 13:31 МСК Амир приблизил таблицу на физическом iPad 0.3.50
и подтвердил: «да чётко». Отдельное замечание о задержке появления соседних
предметов при отдалении разобрано выше. Проверка живого Pencil и полная
приёмка приложения не следуют из одного подтверждения читаемости.

## 13 сентября — кнопка голоса сразу начинает разговор

Амир подтвердил, что 0.3.48 больше не закрылась при включении: появилось
ожидание, но голосового ответа он не получил. Обычное нажатие на волну теперь
вызывает `begin`, не `arm`, в обоих представлениях единственной общей кнопки.
Произносить GPT или выбирать начало разговора в меню не нужно. Прежний пункт
«Начать разговор без обращения» удалён; ожидание имени включается отдельно
из параметров. Распознавание живого обращения остаётся непроверенным, а не
объявляется исправленным благодаря смене основного действия.

`.build/direct-voice-checked/verification.json` подтверждает **23 Core + 29 Codex
+ 3 аудио + 11 Mac + 22 iPad/UI** без ошибок, пропусков и runtime warnings;
отпечаток — `250f6dc45d9bb7df71aee320c808ea0aa92c3337be61b920bfd6489a06c928a5`.
Нативная проверка после ошибки неподдерживаемого языка обращения проходит
прямо к допуску микрофона: начало обычного разговора не зависит от Speech,
черновик и задача сохранены, при отказе микрофона звонок не создаётся.
Жестовая проверка подтверждает одно основное действие, отдельные параметры
при удержании, одинаковую кнопку в чате и компаньоне, сохранность черновика,
камеры и принятых чернил. Физический звук этим не проверен.

Пара **0.3.49 (52)** из `.build/direct-voice-release` установлена на Mac и
физический iPad. Независимая копия —
`/Users/amir/Documents/Notebook Backups/20260913-123851-before-direct-voice`.
Свежая проверка не обнаружила активных звонков, терминалов, записи или ввода;
обновление не прерывало активную работу. Обратное чтение
`.build/direct-voice-install/installed-readback.json` сохранило содержание,
черновики, все 112 запросов, камеру, положение чата и доверие. Неизвестное
поручение не повторялось. Установленный помощник читает прежнюю доску, версия
и снимок iPad после запуска проверены, микрофон сам не включается.
В 12:44 МСК Амир на физическом iPad подтвердил запуск разговора и слышимый
ответ после нажатия кнопки и «Привет» без имени GPT. Это физическое подтверждение
прямого входа и ответа в 0.3.49, не проверка обращения по имени, перебивания,
совместного Pencil-цикла или отдельной диктовки. Начатый им разговор не остановлен.

## 13 сентября — падение при ответе системы на запрос Speech

На физическом iPad 0.3.47 (50) получены два отчёта о падении в 12:14:41 и
12:14:48. Оба содержат `EXC_BREAKPOINT → _dispatch_assert_queue_fail →
NotebookWakeRecognizer.authorize` в фоновой очереди TCC. UUID образа совпал с
подписанным dSYM: `D21F0192-6EE4-3959-A8A8-B4AB4EDD89DE`. Предыдущий голосовой
профиль обходил настоящий ответ разрешения; успешная проверка отключённого
чата не подтверждала запуск микрофона. Отчёты и разбор находятся в
`.build/voice-start-crash-investigation/diagnosis.json`.

Новый нативный тест вызвал настоящий Speech под Swift 6 и воспроизвёл тот же
сбой после системного отказа (`.build/voice-start-crash-red`). Ответы разрешения
и распознавания теперь явно `@Sendable`; только передаваемые значения возвращаются
прежнему владельцу на `MainActor`, без отключения проверок изоляции или нового
потока исполнения. Разрешение принадлежит приложению, а не экземпляру захвата.

`.build/voice-start-crash-checked/verification.json` связывает исходники
`74073346c39fc973ac07d720c47eddb4aa76321b54e65047f4fdb9eef1f2e1e5`
с **23 Core + 29 Codex + 3 аудио + 11 Mac + 22 iPad/UI** проверками без ошибок,
пропусков и runtime warnings. В настоящем системном вызове проверены три
последовательных ответа, возврат на `MainActor` и неизменность разрешения
микрофона. В тестовом Simulator решение Speech уже принято; свежий Simulator
требует однократного ответа на его системный запрос, а не скрытого изменения TCC.
Микрофон Simulator остаётся запрещённым. Синтетические русское и английское
обращения также прошли через выпускаемый распознаватель, собранный с
`-swift-version 6 -strict-concurrency=complete`, без микрофона и звонка.
Это проверка причины падения и локальной обработки, не физическая приёмка
живого звука, ответа Codex и перебивания.

Пара **0.3.48 (51)** из `.build/voice-start-crash-release` установлена на прежние
Mac и физический iPad. Независимая копия перед заменой находится в
`/Users/amir/Documents/Notebook Backups/20260913-122522-before-voice-start-crash`.
Перед штатным завершением помощника проверено отсутствие активного звонка,
терминала, записи файла, доставки поручения и принятого Pencil-контакта.
`.build/voice-start-crash-install/installed-readback.json` подтверждает те же
1512 записей Mac и 1481 iPad, все черновики и 110 запросов, неизменную камеру,
геометрию чата и доверие; изменилось только служебное состояние ввода.
Единственный запрос с неизвестным исходом не повторён. Установленный помощник
прочитал доску, версия и снимок физического iPad после запуска проверены:
приложение открыто, микрофон выключен. Амиру предложен короткий повтор
нажатия и живого обращения; результата этого опыта на момент выпуска ещё нет.

## 13 сентября — прямое включение и временная привязка голосового обращения

Амир подтвердил, что обращение живым голосом не срабатывает, и не знал о
спрятанном действии «Ожидать GPT». Снимок установленного iPad 0.3.46 показал
выключенный микрофон. Теперь короткое нажатие на волну непосредственно включает
ожидание имени; удержание открывает только параметры и возможность начать
разговор без обращения. Состояние микрофона и закреплённая задача видны и при
выключенной карточке обычной работы. Ни ожидание, ни разрешение не включаются
автоматически после запуска приложения.

Настоящий локальный `SFSpeechRecognizer` на Mac воспроизвёл два независимых
сбоя на синтетических записях. Во-первых, промежуточное «Слушай GPT» приходит
с нулевыми временем и длительностью. На исходном пути после 16 секунд тишины
срабатывание указывало на frame 0, уже вышедший из буфера. После исправления —
на 15,990 секунды, то есть начало обращения, а не начало ожидания. После
48 секунд ожидания, включая смену запроса распознавания, получено 47,970 секунды.
Во-вторых, русская модель выдала всю английскую просьбу одним сегментом
«Hey GPT explain des former». Проверка границы по сегментам теряла обращение;
теперь она использует границы слов внутри текста и сохраняет исходное время.
Сущность `Segment` заменила неверное предположение `Word`, без второго
распознавателя, захвата, истории или очереди.

В `.build/live-wake-investigation/acoustic-probe-receipt.json` сведены исходное
воспроизведение и проверки исправления. Сработали русское и английское обращения
с просьбой, короткое имя и обращение после предыдущей речи. «Мы обсуждали GPT
вчера» и «Слушай, я хотел задать вопрос» не сработали. Это малая проверочная
выборка синтетического звука через выпускаемые классы, не измерение точности
живой речи и не приёмка микрофона iPad. Звук человека не записывался; отдельная
модельная задача и звонок для этих опытов не создавались.

`.build/live-wake-final-checked/verification.json` подтверждает **23 Core +
29 Codex + 3 аудио + 11 Mac + 21 iPad/UI** без ошибок, пропусков и runtime
warnings. Отпечаток исходников:
`0db3aa5e1ce6ac981c7ae3a60af1ef57c5e28ffeee97f2d2b6b545a07ceac1cd`.
Настоящий AudioWorklet исполнился в невзаимодействующей поверхности 1 × 1:
типизированный непрерывный PCM достиг локальной границы, до обращения peer
отсутствовал, mute и завершение освобождали звук без второго соединения.
Жестовый сценарий проверил прямое действие волны в обоих представлениях,
параметры при удержании и сохранность черновика, камеры и принятых чернил.
Снимки просмотрены. Полный цикл с голосом Амира и Apple Pencil на физическом
iPad, включая перебивание и ответ Codex, остаётся открытым в GUI-191/GUI-190.

Подписанная пара **0.3.47 (50)** из `.build/live-wake-release` установлена на
прежние Mac и физический iPad. Независимая копия перед обновлением:
`/Users/amir/Documents/Notebook Backups/20260913-100155-before-live-wake`.
Свежие проверки перед остановкой не обнаружили звонка, терминала, доставки
поручения, сохранения файла или Pencil-контакта. В
`.build/live-wake-install/installed-readback.json` подтверждены те же 1512
записей Mac и 1481 iPad, кроме служебного состояния ввода; камера, геометрия
чата, черновики, файлы, доверие и все 110 запросов сохранены. Неизвестный исход
единственного запроса не повторялся; обе стороны подтвердили доставку до 185.
Установленный MCP прочитал доску, версия iPad и снимок после запуска проверены.
Микрофон после установки выключен: живое ожидание не включается без нажатия.

## 13 сентября — меню «+» получает собственные касания

На исходной 0.3.45 меню над открытым листом прошло сценарий с клавиатурой
(`.build/add-menu-baseline`), но тот же выбор над пространственной доской
в режиме ввода Pencil не завершался. В `.build/add-menu-board-baseline`
нажатия на пункты меню/списка добавили два действия чернил вместо вложения.
Это воспроизведённая потеря ввода, не доказательство остановки главного потока
или сетевого тайм-аута на физическом устройстве.

`SpatialInkCanvas` теперь проверяет принадлежность касания через существующий
`sceneReceives`, как камера и выделение. Касания нативных меню и всплывающих
списков не принимаются доской; нового общего блокировщика или владельца меню нет.
Уже принятые контакты завершаются прежним путём. Успешный повтор с выбором
вложения, закрытием меню и новым штрихом — `.build/add-menu-resume`.

Завершающая `.build/add-menu-checked/verification.json` связывает исходники
`0e1e669a45b9dcbecb56a4c3807821065b4100b2a75f28d054082fb46657db09` с 18
пройденными проверками: 15 нативных и 3 жестовых UI-сценария, без ошибок,
пропусков и runtime warnings. Проверены сохранение камеры, черновика и вложений,
отсутствие отправки при работе с меню, узкий полный чат, новый штрих после меню,
отмена/снятие окна и завершение уже принятого Pencil при смене владельца.
Снимки меню и возвращённого черновика просмотрены. В UI-сценарии Simulator
касания направлены в настоящий пространственный распознаватель Pencil;
это не физическая проверка Apple Pencil. Живое воспроизведение зависания на
iPad ещё не получено: при чтении установленного приложения меню было закрыто.
Другие открытые условия GUI-196 и голоса этим срезом не закрываются.

Пара **0.3.46 (49)** установлена на прежние Mac и физический iPad из
`.build/add-menu-release`. Перед обновлением создана независимая копия
`/Users/amir/Documents/Notebook Backups/20260913-040926-before-add-menu`.
Обратное чтение `.build/add-menu-install/installed-readback.json` сохранило
1512 записей Mac и 1481 iPad, кроме служебного состояния ввода. Камера, окно,
черновики, 110 запросов, файлы и доверие не изменились; единственный запрос с
неизвестным исходом не повторялся. Активных запусков, звонков и Pencil-контакта
при обновлении не было, доставка обеих сторон подтверждена до позиции 185.
Установленный MCP прочитал текущую доску; версия iPad и снимок после запуска
проверены отдельно. Это установка и сохранность работы, не физическая приёмка
касания меню Apple Pencil.

## 13 сентября — голосовой вход и явное ожидание GPT

На установленном iPad 0.3.44 обнаружена `notebook.voice.method = dictation`:
нажатие на недоступную кнопку сохраняло режим, который запрещал ожидание
обращения. Этот неисполняемый выбор удалён, голосовая сессия по-прежнему
начинается только по явной команде. Ошибка запуска больше не исчезает при
освобождении микрофона. Одно меню в чате и компаньоне предлагает живой разговор
сразу или ожидание имени; отдельная приглушённая иконка сообщает ограничение
диктовки, не изменяя черновик. Русское распознавание также принимает точные
варианты Hey / Хей / Хэй / Эй перед GPT из того же словаря, что подсказки речи.

Свежие экспериментальные схемы обеих установленных версий Codex,
0.154.0-alpha.6.2 и 0.154.0, содержат 159 методов: только шесть операций
`thread/realtime/*`, без отдельной диктовки. Свидетельства в
`.build/voice-entry-investigation/schema` и `standalone-schema`.
Диктовка через существующую авторизацию остаётся внешней блокировкой GUI-191;
микрофон человека при этих проверках не включался.

Неподдерживаемый язык отвергается по системному списку до запроса доступа;
отрицательная проверка фиксирует освобождение ресурсов и сохранение причины.
Проход WebAudio с синтетическим звуком остановлен на системном запросе
микрофона; реальный доступ в Simulator запрещён перед повторной проверкой.
Более широкий
`testCompanionKeepsPaperDraftAndOneSubmissionWithoutReplyClouds` отдельно
остановился на новом штрихе после сворачивания (строка 34, до голосовых действий).
Это повторено на неизменённой копии исходного `1c747ac`:
`.build/voice-entry-baseline/ipad.xcresult`. Один ранний проход остановился
на сворачивании. Отдельно воспроизведено неполученное нажатие на диктовку
компаньона после открытой клавиатуры. Фокус черновика теперь принадлежит панели;
кнопка сворачивания освобождает его до смены представления. Тот же голосовой
сценарий прошёл в `.build/voice-entry-focus-action.xcresult` без повторения нажатий.
Широкий сценарий с новым штрихом не объявляется пройденным; проблема остаётся в GUI-196.
Голосовая проверка не заменяет его и физическую акустическую приёмку.

Итоговый выбранный проход `.build/voice-entry-fit-checked/verification.json`:
**29 Core, 3 проверки аудиобуфера, 11 Mac, 22 iPad/UI** — без ошибок, пропусков
и runtime warnings. Неизменные исходники:
`06e38f378aa30f88f176373daf1b3a447dd016b0ebf11a54d384f739b44baf60`.
Жестовые проверки нажимают кнопки в раскрытом и свёрнутом чате, в том числе
после ввода черновика; камера, принятые чернила и текст сохранены. Осмотрены
снимки обоих всплывающих окон: объяснение, закрытие и варианты голосового
входа полностью помещаются и не обрезаются клавиатурой.

Пара **0.3.45 (48)** собрана из этой описи и установлена поверх текущих
приложений Mac и физического iPad. Предварительно создана независимая копия
`Notebook Backups/20260913-025906-before-voice-entry`; архивы не восстанавливались.
`.build/voice-entry-install/installed-readback.json` подтверждает прежние
1512 записей Mac и 1481 запись iPad: изменилось только состояние отсутствия
контакта с бумагой. Все черновики, разговоры, запуски, ключи сопряжения, камера
и геометрия чата сохранены; неизвестное поручение не отправлялось повторно.
Неработавший выбор диктовки удалён из настроек iPad. Обе стороны подтвердили
доставку до 185. Установленный помощник отвечает через MCP; осмотрен снимок
физического iPad с доской и компаньоном. Это не проверка акустического обращения
или настоящей диктовки: GUI-191 остаётся открытой.

## 13 сентября — принятое движение, причинное размещение и полная версия доски

`.build/live-placement-verified/verification.json` подтверждает неизменные
исходники `becc792be0ce92a0e8e0aa6f0f694135af6be868feaf19eb8dbcd75744a407ea`:
**157 Core + 1 проверка архивного конвертера, 47 MCP, 16 Mac и 119 iPad/UI**
прошли без ошибок, пропусков и runtime warnings. Дополнительно прошли проверки
маршрутов проверки и выпуска. Это выбранный объединённый срез,
не полный прогон milestone и не физическая приёмка Pencil.

Нативный сценарий удерживает прежнюю композицию и проверяет настоящее
смонтированное тело после двух переносов и изменения размера: координаты,
четыре угла, пиксели, следующий контакт и конечная запись. Камера и чернила
не меняются. Снимки окончательного сценария извлечены отдельно в
`.build/live-placement-verified-ui`, исходная квитанция проверки не изменялась.

Повторный разбор GUI-196 с тремя независимыми агентами обнаружил две причины
возврата: нативное тело могло получить старое положение из задержанной композиции,
а объединение свободной карточки и стопки могло заменить независимое содержание.
Допущенное тело, рамка и следующая область касания теперь используют текущую
модель. Подготовка изображения не отменяет принятый контакт. Подтверждение
анимации карточки читает её собственные причинные вершины, не удалённые поля
свободного размещения или стопки.

Формат доски 3 хранит одно размещение предмета; стопки и свободные карточки —
производный вид. Полная версия правки приходит из SQLite, не из максимума часов
и не из видимого подмножества. Pencil и камера портала остаются независимыми.
Квитанция действия получает версию после записи в той же транзакции. MCP
возвращает вычисленную нативную раскладку, не строит своего владельца размещения.

Отдельная проверка `oneHundredThousandOwnersKeepAnEditAndItsJournalAddressed`
прошла за **466,628 с**: 100 000 предметов, 1 300 006 записей, при адресном
чтении размещения просмотрен **один предмет / 421 SQL VM step**. Большая часть
времени — создание исходного каталога и проверка порядка страниц; это не
задержка обычного перемещения. Общая команда этого прохода остановилась на
устаревшем утверждении о равных версиях разных досок. Её нельзя назвать общей
успешной приёмкой. `.build/live-placement-scale-audit/production-identity.json`
фиксирует состояние до последнего исправления индекса передачи. Проверка
нагрузки относится к той версии; её нельзя объявлять измерением окончательной
сборки. Последнее исправление не расширяет чтение: отдельный контракт проверяет
точечное сопоставление изменённого предмета менее чем за 512 SQL VM steps.
Для отдельных повторов большой нагрузки предусмотрен профиль `placement-scale`.

Промежуточная нативная сборка выявила оставшееся тестовое обращение к удалённой
версии дерева. Два Mac setup и DEBUG-запуск пересоздавали начальную доску,
изменяя старые координаты под прежней причинной версией; новый формат правильно
отказывал. Теперь фикстуры читают сохранённую доску и авторят только настоящие
добавления/движения. Проверки бумаги Letter, чужого JavaScript и пикселей
не ослаблены. Исправлена также сигнатура конструктора в новом тесте анимации.

Объединённый iPad-проход дополнительно поймал настоящий дефект передачи между
досками: удаление старого размещения могло стереть уже записанного нового
владельца. Исправлена принадлежность строки индекса её точному адресу, а не
порядок доставки. Добавлены оба порядка UUID, свободная карточка и стопка,
возврат, повторная доставка и отказ от двойного живого владения. Новые сценарии
сначала воспроизвели ошибку во всех четырёх сочетаниях, затем прошли; прежние
нативные проверки удаления и передачи не менялись.

Свежая независимая копия
`/Users/amir/Documents/Notebook Backups/20260913-014916-before-live-placement`
содержит **1527 записей Mac и 1496 iPad**. Оба старых журнала полностью
подтверждены. Одна карточка реально расходилась: Mac сохранял положение с
версией 0, iPad — более позднее положение с версией 1. Репетиция на отдельных
копиях через обычную миграцию, передачу и подтверждение точно свела доски,
сохранив позднее положение iPad. Все прежние неизменяемые записи, не относящееся
к доске содержание, чернила, локальные черновики, доверие и курсоры проверены.
Копии: `.build/live-placement-install/golden`; пользовательские архивы не
восстанавливались и текущая база iPad не заменялась копией Mac.

Миграция сохраняет старые закреплённые ссылки. Неоднозначная старая отмена
пакетного создания/стопки явно отказывается вместо угадывания авторства;
одиночное доказуемое перемещение и новые отмены поддерживаются. Отставший до
границы перехода компьютер не получает ложного подтверждения пропущенных
изменений. Исторические неотправленные пакеты не превращаются в новый формат.

Полный физический цикл с Pencil остаётся открытым из-за прежнего запроса
код-пароля XCTest; установка и снимок не заменяют этот сценарий. GUI-197
сохраняет отдельный доказанный риск одновременных поздних правок текста и
свойств артефактов. Известный дефект очень тонких линий при сильном уменьшении
и остальные открытые условия GUI-190 этим срезом не закрываются.

### Установленная пара 0.3.44 (47)

`.build/live-placement-release/build.json` подтверждает подписи пары из того же
неизменного исходника. Обновлены прежние Mac и физический iPad без удаления
контейнеров. Перед остановкой повторно проверены текущие данные обоих устройств,
отсутствие принятого Pencil, активных процессов и незавершённого звонка; прежнее
разрешение на прерывание не переиспользовалось. Mac завершён обычным AppKit
маршрутом. Его прежний App Server и MCP завершились; новые принадлежат новому
помощнику. Основное приложение Codex и чужие задачи не перезапускались.

`.build/live-placement-install/installed-readback.json` подтвердил:

- SQLite и все хеши корректны; все прежние неизменяемые записи сохранены;
- обе доски в точности совпали с репетицией перехода и между собой, включая
  более позднее положение iPad; оба журнала полностью подтверждены на 185;
- камера, чернила, содержимое документов, 110 запросов, два файловых черновика,
  сохранённый вывод процессов, геометрия чата и сопряжение не изменились;
- неизвестный исход создания `F4F21136-9CBE-4519-9B16-7D6E946F5F35` остаётся
  неизвестным и не отправлен повторно;
- текущих строк стало 1512 на Mac и 1481 на iPad вместо 1527 и 1496:
  удалены заменённые представления размещения, а не содержание.

Свежий MCP установленного помощника вернул `ready`, связь с физическим iPad
и одинаковую полную версию доски в observe/read:
`fa7ceed9599710ff4c26031a520d9c75642e92b52e9c68e390d35317c13854a6`.
Отдельная версия MCP-пакета осталась 0.3.39; принадлежность нового кода доказана
описью установленного bundle, а не этим номером. Снимок `ipad-after.png`
показывает прежние материалы и компактный чат при той же камере. Это доказательство
установки и показа, не выполненный физический жест переноса или письмо Pencil.

## 12 сентября — четыре угла и завершение у своего владельца, 0.3.43 (46)

`.build/corners-ownership-final/verification.json` подтверждает неизменный срез
`07ae6b18a3f0b726e54f233363490ed2342e770ef670f236060832ed747a6d2c`:
**49 Core, 23 Mac и 79 iPad/UI** проверок прошли, ошибок, пропусков и runtime
warnings нет. MCP проверен изолированным маршрутом профиля пометок. Это
выбранная проверка затронутого поведения, не полный прогон milestone.

Настоящие жесты Simulator проверяют все четыре угла, неподвижность
противоположного угла, бумаги и чернил, единственную рамку после смены выбора,
удержание и удаление артефакта, отмену совместного действия, текст на обложке.
Нативные проверки дополнительно покрывают углы у края экрана, отмену Pencil,
позднее отпускание, один расчёт прямоугольника и освобождение контакта.
Одновременные текст и чернила агента сохраняются при изменении размера
человеком. Размер активного WebKit до отпускания не меняется.

Проверены A → медленное B → A, закрытие во время чтения, поздняя ошибка другого
файла, A → B → A при обновлении и просмотре пометки, завершение старого
текстового редактора, одноимённые элементы разных досок, смена проекта во время
терминальной команды. Удалён отдельный изменяемый флаг режима указания:
его состояние выводится из текущего контакта/области, а не конкурирует с ними.
Границы обхода рабочих путей описаны в `reliability-transition.md`.

Промежуточные ошибки новых проверок исправлены до итогового прохода:
сравнение дробных координат теперь использует точность; жест учитывает путь до
порога распознавания; тестовый черновик имеет сохранённую камеру; тихое чтение
терминала не считается записью файла. Проверка физических углов с Pencil
остаётся открытой из-за прежнего запроса код-пароля XCTest. Прежний дефект
сильного уменьшения тонких линий не исправлен этим срезом и не скрыт из GUI-190.
Подписанная пара `.build/corners-owner-release/build.json` установлена на месте:
**0.3.43 (46)** на Mac и физическом iPad. Исходный commit `df0cd8b` отправлен.
Независимая копия
`/Users/amir/Documents/Notebook Backups/20260912-233916-before-corner-resize`
содержит 1497 записей Mac и 1468 iPad. Перед обычным завершением помощника
не было активного терминала, незавершённого звонка, доставки или Pencil;
прежнее разрешение на прерывание не использовалось.

`.build/corners-owner-install/installed-readback.json` проверил целостность
SQLite, хеши всех сохранённых данных, доверие, 110 запросов, два файловых
черновика iPad и прежнюю геометрию чата. После установки с 20:50:52 UTC уже
появились новые человеческие указания, перенос и изменение размера таблицы.
Поэтому строгая проверка полного совпадения остановилась; отдельный разбор
каждого изменения подтвердил: ни одна прежняя запись не удалена, содержание
таблицы и чернила не изменились, поменялись её прямоугольник и причинные версии.
Текущее состояние содержит 1514 записей Mac и 1484 iPad. Новая работа сохранена,
неизвестное создание разговора не повторялось.

Камера изменилась после запуска; её текущее значение, выбор и прямоугольник
таблицы совпадают на обоих устройствах. Это не доказательство неподвижности
камеры во время физических жестов: промежуточный путь не наблюдался и прежнее
положение не восстанавливалось. Просмотрен физический `ipad-after.png`:
документ, тетрадь, таблица и свёрнутый компаньон отображаются. Установленный MCP
вернул `ready` и тот же iPad; версия модуля инструментов остаётся 0.3.39.

Два копирования каталога iPad оборвались с CoreDevice 7000 / POSIX 60 на
30 000 000 байтах базы. Неполные копии сохранены отдельно. Передача самой базы,
WAL и SHM отдельными файлами через тот же `devicectl` завершилась; требования
целостности и сравнения не ослаблены. Полная физическая приёмка остаётся открытой.

## 12 сентября — один текущий выбор вместо конкурирующих рамок

Повторная жалоба Амира на установленную 0.3.41 вновь открыла GUI-196 и GUI-188.
Прежний успешный перенос одного предмета не доказывал переход между предметами.
В модели теперь одна `NotebookSelectionSession`: обложка, элемент, область,
текстовый ввод и показ ссылки не хранят независимые текущие выделения.
`ElementEditingSession` и локальные копии выбранного предмета/редактируемого
текста удалены. Приложенный материал принадлежит тому же выбору, история
сохраняется отдельно и не рисует вторую рамку. Закрытая обложка принимает
свой контакт целиком; общий распознаватель не дублирует её tap.

Позднее завершение сохранения или чтения истории проверяет идентификатор
текущего выбора и не возвращает прежнюю рамку. Отмена сохраняется через
существующую очередь, включая отказ при изменившемся содержании. Пока новый
материал ещё сохраняется, отправка не теряет черновик и не создаёт поручение
со старым контекстом. Адрес перемещения содержит доску, поэтому смена камеры
не направляет его другому элементу с тем же именем. Прямой ввод в программу
не включает ручки трансформации и не перестраивает её размер при увеличении.

Настоящий жестовый сценарий Simulator выбирает первый артефакт, затем второй:
изображение первого остаётся без рамки, видна одна кнопка удаления над вторым,
счётчик равен одному. Снятие выбора и касание пустой бумаги удаляют рамку,
кнопки и счётчик вместе; бумага и принятые чернила не изменяются. Отдельно
проверяются перенос, удаление, редактирование текста, история и причинная отмена.
`.build/selection-owner-checked/verification.json`: **17 Core, 13 Mac и 58
iPad/UI** проверок прошли, без ошибок, пропусков и предупреждений выполнения.
Неизменный исходник: `2fbbcca39925109ba4b078b4f05725323fd7b3f98c8126c70ced086767fa3d5b`.
Просмотрен снимок `only-second-artifact-selected` из итогового жестового теста;
первая рамка исчезла, вторая стоит на выбранном материале.

Подписанная `.build/selection-owner-release/build.json` установлена на месте:
**0.3.42 (45)** на Mac и физическом iPad. Перед первой попыткой Амир успел
сделать ещё три указания; проверка остановила установку до завершения
помощника. Новая независимая копия
`/Users/amir/Documents/Notebook Backups/20260912-225547-before-selection-owner`
содержит и эту последнюю работу. Исторические архивы не восстанавливались.

`.build/selection-owner-install-current/installed-readback.json` подтвердил
все **1472 записи Mac и 1446 iPad**, прежнюю выбранную область, доверие,
108 запросов, оба файловых черновика и размер/положение чата. Из записей
изменилось только состояние текущего ввода. Центр и масштаб доски совпадают
с чтением непосредственно перед обычным завершением помощника. Активных
процессов, незавершённых звонков, доставки действий и контакта Pencil не было;
неизвестное создание разговора не повторялось.

Физический снимок `.build/selection-owner-install-current/ipad-after.png`
просмотрен: восстановлена одна рамка документа и счётчик «1», другая тетрадь
и таблица без лишних рамок. Таблица остаётся чёткой. Установленный MCP вернул
`ready`, тот же iPad и камеру; версия неизменённого модуля инструментов —
0.3.39, версия самой пары — 0.3.42. Этот снимок подтверждает установку и
восстановление выбора, но не заменяет физический последовательный жест.

Промежуточные проверки обнаружили выход второго тестового предмета за размер
листа и перекрытие текстового значения новым атрибутом доступности; оба
исправлены, проверки не ослаблены. В более широком наборе был также найден
непроходящий тест тонких линий при масштабе 0,03. Изолированный неизменённый
`a5af9c9` дал тот же результат: контраст 0,015686 вместо >0,084.
`.build/selection-baseline-thin/ipad.xcresult` и
`.build/selection-baseline-thin-summary.json` фиксируют воспроизведение на
исходной 0.3.41. Этот дефект сильного уменьшения отмечен в GUI-190 и не выдан
за успешную проверку. Ошибка неподвижности активного WebKit в новом наборе
исправлена разделением прямого ввода и показа ручек внутри одного выбора.
Физические последовательные жесты с Pencil всё ещё не приняты: XCTest
требует код-пароль устройства. Установка и снимок не заменяют этот сценарий.

## 12 сентября — экранная плотность таблиц, установленная 0.3.39 (42)

`.build/board-table-checked/verification.json`: **29 Codex, 5 Mac и 17 iPad/UI**
проверок прошли без ошибок и пропусков. Новый сценарий держит таблицу 1280×1120
рядом с двумя нативными обложками при масштабах 0,12546 и 0,30090: обложки
сохраняют владельцев ввода, таблица — экранную плотность, общий лимит не растёт.
Проверка смонтированного SVG отдельно ждёт нового растра после увеличения
и измеряет контраст полос на экране. Причинная отмена и сохранность Pencil
проверены настоящими жестами Simulator.

Промежуточный набор `.build/board-table-release-check` выполнил 32 из 34
iPad/UI-проверок успешно, включая медиаресурсы и снятие представлений.
Два старых ожидания исправлены: полная каноническая плотность больше не является
контрактом маленького экранного предмета, а проверка сохранения прежнего
изображения теперь действительно начинает с видимого материала. Итоговый
выбранный прогон выше проверил оба исправленных сценария. Удалён также расчёт
второго растрового кеша, который уже не используется представлением, и повторное
огрубление пустых диапазонов, не освобождавшее памяти.

Подписанная пара `.build/board-table-release/build.json` установлена на месте.
Физический iPad объявляет **0.3.39 (42)**, установленный MCP — **0.3.39**, 20
инструментов. Независимая текущая копия лежит в
`/Users/amir/Documents/Notebook Backups/20260912-203100-before-table-density`;
исторические архивы не восстанавливались. Перед обычным завершением помощника
не было активных процессов, незавершённых звонков или контакта Pencil.

`.build/board-table-install/installed-readback.json` подтвердил прежние 1408
записей Mac и 1388 iPad, сопряжение, 108 запросов, оба файловых черновика iPad
и геометрию чата. Из записей изменилось только состояние текущего ввода.
Неизвестное создание разговора сохранило свой UUID и состояние, без повтора.
Камера совпала с чтением непосредственно перед обновлением.

Физический снимок `.build/board-table-install/ipad-after.png` просмотрен и
сопоставлен с `.build/board-repair-install/ipad-after.png`: **существующая
таблица стала чёткой** при том же содержимом, центре и масштабе. Видны заголовок,
строки и значения вместо растянутых пятен. Это закрывает конкретную размытость
на предоставленном материале, но не заменяет живой совместный цикл с Pencil,
голосом, перебиванием и обрывом связи. Общая физическая приёмка остаётся открытой.

## 12 сентября — выбор пальцем и компактное управление, установленная 0.3.38 (41)

`.build/board-repair-verified/verification.json` подтверждает неизменный срез:
**29 Codex, 1 Mac и 26 iPad/UI** проверок прошли без ошибок и пропусков.
Пять жестовых сценариев проверяют выбор пальцем и область удержанием, причинную
отмену после перемещения, тихое изменение агента, свёрнутый чат с черновиком и
единственной отправкой, перенос и изменение размеров без движения камеры.
Для настоящего пальца в Simulator используется отдельный режим ввода: обычная
проверка там специально имитирует Pencil прямым касанием. Перемещённое окно
не должно перекрывать точку проверяемого касания; это учтено в сценариях.

Нативные проверки проводят вывод и ввод через настоящий WebKit, закрывают его,
находят прежний процесс после холодного восстановления и замечают его выход
без нового запуска. Медийные проверки освобождают ресурсы WebRTC; они не
доказывают слышимость, перебивание и завершение живого разговора на iPad.
Ранние попытки выявили перехват кнопки сворачивания переносом заголовка и
дублирующий элемент доступности у ручки размера; оба исправлены до этого PASS.

Пара установлена на месте: `.build/board-repair-install/installed-readback.json`
подтверждает 1408 записей Mac и 1388 iPad, прежние камеру, геометрию чата,
сопряжение, два файловых черновика и 108 запросов. Неизвестное создание задачи
не повторялось. Резервная копия —
`/Users/amir/Documents/Notebook Backups/20260912-194258-before-board-repair`.
Первое обратное чтение остановилось на уже существующем поле отметки чтения:
проверяющий сценарий удалял его только из новой стороны сравнения. Значения
переписки были идентичны; исправлено сравнение, не данные пользователя.

Снимки `.build/board-repair-before.png` и
`.build/board-repair-install/ipad-after.png` показали **сохранившуюся размытость**.
Следовательно, отказ от второго кеша Core Animation сам по себе дефект не устранил.
Холодный запуск с журналом выявил 116 916 480 байт пассивных нативных обложек при
лимите 134 217 728; запрос таблицы требовал ещё 29 622 528 байт. Планировщик
сохранял обложки, но сводил таблицу к фрагменту около 26×24 pixels внутри
512-пиксельного обзорного тайла. Именно этот тайл найден в копии контейнера
и просмотрен; камера и SVG не менялись. Это причина потери детализации, а не
плохое содержимое SVG и не отказ доставки.

Полная приёмка Pencil и голоса, отдельная диктовка Codex и второй Mac остаются
открытыми; этот выбранный маршрут не выдаётся за полный прогон milestone.

## GPT над доской: установленная 0.3.37 (40)

12 сентября свёрнутый чат сохранил подключение к той же задаче Codex. Полезный
законченный ответ показывается ограниченной тучкой: её закрытие сохраняет
сообщение и непрочитанный счётчик, нажатие открывает полный ответ в переписке.
Черновик можно изменить, отменить и отправить в компактном окне; настоящие
вопросы Codex имеют приоритет. Камера и принятый Pencil остаются у доски.
Убрана отправка пустой подписки при сворачивании, которая отключала события
разговора на Mac; неизвестный прежний запрос не задерживает дочитывание.

Явное «Ожидать обращения» использует только локальное распознавание выбранного
языка и один аудиозахват. До обращения нет WebRTC; ограниченный буфер сохраняет
имя вместе с просьбой, убирает предшествующую речь и передаёт запись один раз
через прежний голосовой разговор. При звонке локальное ожидание выключено.
Mute останавливает исходный микрофонный трек; повторное включение остаётся в
прежнем соединении. Уход в фон и обрыв освобождают звук без скрытого ожидания.
Название задачи закреплено до завершения, а имя GPT не выдаёт разрешений.

Неизменный выбранный маршрут `.build/board-voice-release-check/verification.json`
прошёл **20 Core, 28 Codex, 11 Mac и 26 iPad/UI** проверок без ошибок, пропусков
и runtime warnings. Дополнительно прошли **3** проверки аудиобуфера, **25**
маршрута проверки и **40** сборки пары. Это не полный прогон всего проекта.
Жестовый сценарий в Simulator пишет на бумаге при свёрнутом чате, получает и
убирает ответ, раскрывает точное длинное сообщение, редактирует черновик над
клавиатурой, отправляет одно поручение и поворачивает окно. Снимки просмотрены.
Нативная медиапроверка исполняет настоящий AudioWorklet без микрофона человека:
нет peer до обращения, mute завершает трек, unmute сохраняет peer, окончание
освобождает ресурсы. Отдельные примеры различают обращения, упоминания имени и
собственный голос, но не измеряют акустическую точность.

`.build/board-voice-probe/buffer-receipt.json` и `buffer.log` фиксируют настоящий
WebKit с выпускаемым `voice-shell` и установленным Codex через существующий
вход. После локального накопления 2,3 секунды синтетическое «Hey GPT, what is
two plus two?» пришло целиком; ответ — «Two plus two is four». Проверочный вызов
остановлен. Это доказательство сохранности начала записи и настоящего
подключения, не физической слышимости, распознавания человека или перебивания.
Первая попытка использовать событие публичного Realtime была отвергнута Codex;
этот путь удалён, в выпуске звук идёт по WebRTC-аудиотреку.

Подписанная пара `.build/board-voice-release/build.json` установлена поверх
прежних Mac и физического iPad. SHA-256 неизменных исходников:
`89a31f7c1493c6c29a3fcea39ae2c0f5ca43c24668df8197b530a04a87d38267`.
Свежая независимая копия с целостным обратным чтением SQLite и описями SHA-256:
`/Users/amir/Documents/Notebook Backups/20260912-183745-before-board-voice`.
Перед обычным завершением Mac-помощника не было активных процессов терминала,
неподтверждённых остановок голоса или принятого текущего контакта Pencil.
Прежнее разрешение на прерывание другой работы не использовалось.

`.build/board-voice-install/installed-readback.json` подтвердил **1408→1408**
записей Mac и **1388→1388** iPad. Изменилось только состояние сессии ввода;
содержание, активация, два файловых черновика, 108 запросов и вывод терминала
сохранены. Неизвестное создание `F4F21136-9CBE-4519-9B16-7D6E946F5F35` осталось
`uncertain`, без повторения. Камера обоих устройств совпала с непосредственным
чтением до обновления: local `(1034.2722088949927, 5383.61961736647)`, tile
`(0,-1)`, scale `0.1254612818717936`; чат `751.5×493.04386951631045`, anchor
`(1,1)`. Это нынешнее положение человека, не восстановление старого выпуска.
Физический iPad объявляет **0.3.37 (40)**; установленный MCP — **0.3.37**,
20 инструментов, `ready`, связь с прежним iPad. Снимок
`.build/board-voice-install/ipad-after.png` просмотрен: холодный запуск вернул
доску и новый компактный доступ к чату, черновику и голосу. Исторические архивы
не восстанавливались, контейнеры и ключи не заменялись.

Схема Codex `0.154.0-alpha.6.2` повторно получена в
`.build/board-voice-availability`: 159 методов, только `thread/realtime/*` для
голоса; отдельного интерфейса диктовки в черновик нет. Выбранная диктовка
объясняет ограничение без захвата звука и без перехода к звонку. Полный цикл
на физическом iPad с живым обращением, Pencil, перебиванием и выключением
микрофона **не принят**; нужны также измерения ложных активаций и пропусков на
разных языках. Системное требование человеческого код-пароля UI Automation не
обходилось. Работа при блокировке и в другом приложении не обещается; внешние
блокировки диктовки, второго Mac и общей приёмки milestone остаются открытыми.

## Установленная панель ввода: 0.3.36 (39)

12 сентября «+» стал добавлением к сообщению: файлы и папки выбранного Mac,
установленные плагины, навыки и приложения Codex. Файлы выбираются существующим
деревом, без открытия документа и изменения камеры. Прикрепления сохраняются
вместе с черновиком; отправка очищает только отправленную версию текста и набора
прикреплений, не затрагивая более поздний выбор или другой компьютер.
Проверка изменений подготавливает редактируемый запрос, а сжатие контекста
использует настоящую команду Codex. Меню устройств и навигация больше не
подменяют добавление материалов.

Модель и мышление выбираются из текущего каталога Codex и меняют настройки
той же задачи, без нового разговора или изменения доступа. Неизвестный исход
не повторяет запись: повторное чтение подтверждает только совпавшую настройку.
Контекст показывает фактический последний объём токенов и размер окна, не
суммарные затраты всех ходов. Отсутствующий размер не превращается в ноль.
Узкое окно переносит инструменты на следующую строку, а не скрывает два
соседних голосовых действия; области касания остаются 44×44 точки.

Завершающий неизменный маршрут `.build/composer-final/verification.json` прошёл
**15 Core, 28 Codex, 11 Mac и 25 iPad/UI** проверок без ошибок, пропусков и
runtime warnings. Проверены сохранение прикреплений и прежнего ID поручения,
нативное подтверждение модели, восстановление контекста, геометрия окна,
терминал, голосовой контроллер, прокрутка и остановка. Настоящие касания в
Simulator изменили модель и усилие, прочитали контекст, прикрепили плагин и
файл, сузили окно и сохранили бумагу с принятыми чернилами. Снимки из
`.build/composer-final-attachments` просмотрены. Это выбранная область, не
полный прогон и не физическая приёмка.

Отдельный настоящий App Server установленного Codex подтвердил шесть моделей,
чтение установленных ресурсов и смену на `gpt-6-astra / low` в одноразовой
проверочной задаче. Один короткий ход с временным файлом получил тот же
`clientUserMessageId`; **31 078 / 258 400** токенов сохранились после закрытия и
нового подключения. Свидетельство — `.build/composer-native/receipt-2.json`.
Первое чтение полного магазина приложений завершилось тайм-аутом; этот путь
удалён в пользу списка уже установленных приложений и их метаданных.
Первая расширенная UI-проверка искала не опубликованный системным меню
идентификатор; тест теперь нажимает реальное действие «Файлы и папки».
Неуспешные попытки не включены в PASS.

Подписанная пара `.build/composer-release/build.json` установлена на прежние
Mac и физический iPad. SHA-256 исходников:
`b7ca22764e71e9263478f8e436706267617ae9f9ac1d2b8ec66bb046daf0e41b`.
Независимая копия с обратным чтением SQLite и описями SHA-256:
`/Users/amir/Documents/Notebook Backups/20260912-173301-before-composer`.
Исторические архивы не восстанавливались, контейнеры и ключи не заменялись.

Амир явно разрешил завершить разговор и терминал для обновления. На момент
установки последний голосовой останов уже был принят в 14:16:38 UTC, нового
звонка не было. Обычное завершение помощника закрыло его App Server и оболочку
`0D15821B-D254-4CB2-922F-21CC09CDABFB`; исчезновение обоих процессов проверено.
Запись запуска стала `interrupted`, не повторялась; 178 строк прежнего вывода
сохранены. Никакие другие исполнители не останавливались.

`.build/composer-install/installed-readback.json` подтвердил **1408→1408**
записей Mac и **1388→1388** iPad. Изменилось только состояние новой сессии
ввода; содержание, два черновика файлов, выбранный документ, 108 запросов и
активация неизменны. Неизвестное создание
`F4F21136-9CBE-4519-9B16-7D6E946F5F35` сохранено без повторного исполнения.
Камера обоих устройств совпала с чтением перед остановкой: local
`(1843.0566250289119, 234.309353255514)`, tile `(0,0)`, scale
`0.3009028410296117`; чат `571.5×493.04386951631045`, anchor `(1,1)`.
Это нынешнее положение пользователя, не восстановление камеры прежнего выпуска.

Физический iPad объявляет **0.3.36 (39)**, установленный MCP — **0.3.36**,
20 инструментов, `ready` и связь с прежним iPad. Снимок
`.build/composer-install/ipad-after.png` просмотрен: холодный запуск вернул
нынешнюю доску со свёрнутым чатом. Он не доказывает касания новых настроек на
физическом устройстве; требование код-пароля UI Automation не обходилось.

Диктовка в черновик всё ещё не предоставлена интерфейсом Codex: кнопка не
подменяет её Apple-диктовкой или отдельным ключом. Отдельные физические жесты,
второй Mac и полный цикл milestone остаются открытыми.

## Установленный рабочий срез: 0.3.35 (38)

12 сентября навигация чата разделена на «Чаты» и «Проекты». Общий список
больше не фильтруется выбранным проектом; папки показывают собственные чаты,
включая не попавшие в недавнюю страницу. Пустые проекты остаются видимыми.
Раскрытие папки не меняет рабочий проект и не запускает задачу; выбор разговора
связывает файлы и терминал с его настоящим проектом Codex. Прежний ряд вкладок
удалён; переключатель режимов виден только при выборе разговора.

Терминал находится рядом с файлами в заголовке. Его собственная кнопка
сворачивания получила площадку 44×44 точки и явное закрытие вместо инверсии:
повторный сигнал не открывает панель снова. Процесс, ввод и доля высоты остаются
у прежних владельцев; камера не участвует в этих переходах.

Объединённый маршрут `.build/chat-project-browser-verified/verification.json`
прошёл **29 iPad/UI** проверок без ошибок, пропусков и runtime warnings:
каталог и отдельные курсоры папок, отложенные ответы, пустой проект, файлы,
терминал, геометрия, прокрутка переписки и остановка без потери черновика.
После удаления двух неиспользуемых свойств общего списка финальный маршрут
`.build/chat-project-browser-final/verification.json` повторил **11** проверок
контроллеров чата и терминала и обоих новых жестовых сценариев. Это не 40 разных
тестов и не полный прогон приложения.

Настоящие касания в Simulator переключили оба режима, раскрыли несколько
проектов, выбрали другой разговор и закрыли терминал в четырёх частях кнопки,
включая возврат после ввода с экранной клавиатуры. Сохранились прежний процесс,
его вывод, высота, бумага и чернила. Просмотр снимков первого среза выявил
повторное использование отступа общего списка внутри папки: режимы получили
разные идентичности представления, а проверка теперь охватывает оба вложенных
разговора. Итоговые снимки находятся в
`.build/chat-project-browser-verified-attachments`; их вид просмотрен.

Подписанная установленная пара: `.build/chat-project-browser-release/build.json`.
SHA-256 исходников: `b8b144639f5adc6ee501711e8525eac6908b859210379a87ec460b953409744e`.
Копия перед обычным завершением помощника:
`/Users/amir/Documents/Notebook Backups/20260912-163217-before-chat-project-browser`.
Обновлены прежние bundle ID; контейнеры, доверие и исторические архивы не заменялись.

`.build/chat-project-browser-install/installed-readback.json` подтвердил
**1390→1390** записей Mac и **1372→1372** iPad: изменилось только состояние новой
сессии ввода. Содержание, активация, все 99 прежних запросов и прежний вывод
терминала неизменны. Камера обоих устройств и геометрия чата совпали с чтением
перед остановкой. Неизвестное создание `F4F21136-9CBE-4519-9B16-7D6E946F5F35`
осталось неизвестным, без повторной отправки.

Во время обратного чтения iPad уже использовали: после установки пришли новые
явные запуск, остановка, новая оболочка и создание чата. Поэтому проверка
полного равенства таблиц была остановлена; последующее сравнение проверило все
прежние строки и отдельно записало новые действия с их временем и автором.
Выбор другого разговора и открытый терминал не откатывались к резервной копии.
Один новый сеанс остаётся активным; ради проверки он не завершался.

Физический iPad объявляет **0.3.35 (38)**, установленный MCP — **0.3.35**,
20 инструментов и `ready`; связь с прежним iPad восстановлена. Снимок
`.build/chat-project-browser-install/ipad-after.png` показывает новый заголовок,
правую файловую панель и терминал под открытым окном команды проекта.
Это наблюдение настоящего использования, не автоматизированная приёмка всех
касаний: требование код-пароля UI Automation не обходилось. Отдельная диктовка
Codex, второй Mac и полный физический цикл milestone остаются открытыми.

## Проверенный срез: 0.3.34 (37)

12 сентября убраны ручные обновления чатов, проектов, дерева и открытого файла.
Переписка больше не разделена на «Историю» и текущий ответ: предыдущая страница
подгружается настоящей прокруткой вверх и сохраняет видимый фрагмент. После
обрыва дочитывается пропущенный промежуток, без повторного исполнения поручений.
Кнопка остановки заменяет отправку в поле сообщения и не стирает черновик.
Распознанная служебная обёртка вложений Codex отображается как запрос человека
и безопасные названия файлов. Цитаты и неполные обёртки не очищаются; миниатюры
из названий файлов не выдумываются.

`.build/chat-silent-sync-verified/verification.json` подтверждает **25 Codex и
21 iPad/UI** проверку без ошибок, пропусков и runtime warnings. Проверены
постраничный каталог после удаления и добавления файлов, сохранение загруженного
конца, слияние истории и живого текста по исходным ID, восстановление пропуска
после обрыва и отсутствие перехода из разговора при переименовании проекта.
WebKit удержал экранное смещение того же сообщения при вставке ранних ответов.
Настоящий жест в Simulator загрузил предыдущую страницу, а касание остановки
вернуло отправку, сохранив набранный черновик, положение бумаги и принятые чернила.
Снимки из `.build/chat-silent-sync-verified-attachments` просмотрены.

Дополнительно `swift test --filter NotebookChatStoreTests` прошёл **14 Core**
проверок очереди, закреплённого материала и неизвестного исхода без повторного
исполнения: `.build/chat-silent-sync-store.log`. Это целевые проверки затронутых
владельцев, не полный прогон приложения. Первая UI-попытка в
`.build/chat-silent-sync-checked` завершилась отказом записи: тестовый ход имел
недопустимый ID вместо UUID. Исправлен набор данных проверки, а не ослаблен
сохраняющий контракт; тот запуск не объявляется PASS.

Подписанная пара — `.build/chat-silent-sync-pair/build.json`; SHA-256 исходников:
`f42af950eb6011034b6847096f3e7fce830ea9cc4ae93bedf57a6ce7d113e5a7`.
Независимая копия перед обычным завершением приложения:
`/Users/amir/Documents/Notebook Backups/20260912-160700-before-chat-silent-sync`.
Прочитаны SQLite, описи SHA-256 и активация; прежнее Mac-приложение сохранено
отдельно. Те же bundle ID обновлены на месте, без удаления контейнеров, замены
доверия или восстановления исторических архивов.

`.build/chat-silent-sync-install/installed-readback.json` подтвердил
**1390→1390** записей Mac и **1372→1372** iPad. Изменилось только состояние
новой сессии ввода; содержание, активация, 99 записей очереди и 173 строки
вывода завершённого процесса Mac прежние. Неизвестное создание
`F4F21136-9CBE-4519-9B16-7D6E946F5F35` сохранилось без повторного создания.
Камера обоих устройств: local `(533.2129247103034, 6594.09478579606)`,
tile `(0,-1)`, scale `0.11027730044711667`. Геометрия чата также совпала
с чтением непосредственно перед остановкой: `537.5×567.5`,
anchor `(1, 0.9032620922384702)`.

Физический iPad объявляет **0.3.34 (37)**; установленный MCP — **0.3.34,
20 инструментов**, `ready` и прежнее сопряжение. Просмотренный физический
снимок `.build/chat-silent-sync-install/ipad-after.png` показывает холодный
запуск нынешней доски с двумя обложками и свёрнутым чатом. Новые жесты в
физическом чате ещё не приняты: ранее UI Automation остановился на системном
запросе код-пароля; в этом срезе отказ не обходился и не повторялся.
Отдельная диктовка по-прежнему блокируется отсутствующим интерфейсом Codex,
не подменяется Apple Speech или API-ключом. Milestone не завершён.

## Проверенный срез доски и терминала: 0.3.32 (35)

12 сентября на нынешние Mac и физический iPad установлены исправления показа
доски и снимков, а также терминал под перепиской и полем сообщения.
Файлы остаются справа с одним разделителем, доступ — одной иконкой рядом с «+»,
действия — со смысловыми иконками, чат растягивается за любой угол без кнопки.
Открытие документа и изменение окна не используют камеру доски.

Подписанная пара — `.build/board-recipe-pair/build.json`, SHA-256 исходников:
`ce9b07d6be206a31b7718077bafd8675d7c84486887cb53170eb647dcc1613f1`.
Установленный Mac сверён с подписанным bundle, физический iPad объявляет
`com.amirtlinov.notebook.preview` версии **0.3.32 (35)**. Живой MCP установленного
помощника объявляет **0.3.32, 20 инструментов**, отвечает `ready` и видит прежний
подключённый iPad: `.build/board-recipe-install/installed-mcp.json`.

### Целевые проверки и настоящий снимок

Объединённый маршрут `.build/board-terminal-checked` прошёл **43 Core/Codex,
46 MCP, 17 Mac и 46 iPad/UI** без ошибок, пропусков и runtime warnings.
Это проверка терминала, чата, композиции, чернил и квитанций, не полный прогон.
Следующее исправление фона проверено в `.build/board-grid-release-checked`:
**7 Mac и 15 iPad**. Финальное версионирование снимка проверено семью Core-тестами
в `.build/board-recipe-core/test.log`, а полный путь подготовки PNG и показ доски —
**2 Mac и 2 iPad** в `.build/board-recipe-native-checked`, также без ошибок,
пропусков и предупреждений. Последний маршрут связан с исходниками пары.

Воспроизведён и исправлен остановившийся показ после записи подтверждения.
Снимки `agent-ink-without-navigation`, `native-pencil-erasure` и
`erasure-after-cold-start` просмотрены: линия появляется без навигации, стирается,
новая модель читает оба UUID и показывает стёртые пиксели. Камера не меняется.
До исправления тот же случай не показывал линию за пять секунд;
`.build/board-eraser-repro` — отрицательное свидетельство, не PASS.
Двойное касание в Simulator возвращает целый лист за **1,77 секунды**, в прежнем
пределе ожидания 3 секунды. Это лист с чернилами, не физическое воспроизведение
медленного открытия пустой тетради. [Контракт и границы](board-publication.md).

На установленной **0.3.32** прежняя область доски **2048×2048 points** с тем же
источником подготовлена в **4096×4096 pixels за 1493 мс**, `ready`, без диагностик:
`.build/board-recipe-install/installed-render.json`. Запрос
`35475BCC-ED05-420B-819E-0CFF5CDE1498`, PNG SHA-256
`381ef7219e5e2521ad9b0c5a93ac8710ba1e3cd40256183bc56adc372e9806d7`.
PNG просмотрен: фон и существующий график показаны. Бюджет и плотность не
увеличивались; лишние полные буферы убраны. Новая версия отрисовки имеет свой
устойчивый адрес, поэтому прежняя сохранённая ошибка не заменяет новый результат.
Старые квитанции и содержание не удалялись. Последующий `notebook_place`
вернул `ready` на том же источнике: `installed-placement.json`. Команда записи
содержимого не выполнялась. `post-render-readback.json` подтверждает неизменность
всех прежних записей содержания и камеры: добавился только запрос этого снимка.

Для прежней правки `0D6C2B8E-83AF-4582-8A71-5CAC10B113D9` живой MCP правильно
подтверждает сохранение и получение iPad: `installed-action.json`. Квитанция
показа целой старой версии остаётся `awaiting_display`: после правки человек
изменил чернила. Более поздний кадр нельзя выдать за подтверждение прежней версии.

Терминал сначала занимает половину доступной высоты под чатом; разделитель
сохраняет размер. Явное открытие возвращает прежний сеанс либо создаёт оболочку
Mac, а не угадывает скрипт. Настоящая экранная клавиатура, ввод в xterm,
изменение высоты и повторное открытие с тем же UUID проверены в Simulator.
`.build/terminal-drawer/native-run-complete.json` отдельно подтверждает реальный
PTY Codex: кириллицу и emoji, размер, Ctrl-C, холодное чтение и завершение.
Это два разных доказательства, не физический запуск с iPad.

Четыре настоящих жеста изменения углов, неподвижность камеры при работе с кодом,
компактное согласие и файлы справа ранее проверены в
`.build/chat-corners-checked/verification.json`: **45 Core/Codex, 19 Mac и
26 iPad/UI**, без ошибок, пропусков и runtime warnings. Эти владельцы не
перепроверялись целиком после каждого изменения отрисовки.

### Обновление с сохранением содержания

До установки создана и прочитана независимая копия
`/Users/amir/Documents/Notebook Backups/20260912-1430-before-board-recipe`.
Согласованный снимок WAL Mac и архив iPad прошли integrity_check; сохранены
описи SHA-256, активация, настройки и прежнее Mac-приложение. Mac завершён обычным
выходом AppKit, без сигнала. Обновлены прежние bundle ID на месте, без удаления
контейнеров или замены ключей. Исторические архивы не восстанавливались.

`.build/board-recipe-install/installed-readback.json` до запроса нового снимка
подтверждает **1387→1387** записей Mac и **1370→1370** iPad. Изменился только
`runtime/input.json#` новой сессии; всё содержание и SessionPresence совпали.
Обе активации побайтно прежние, SQLite исправны. Все строки окон, очереди,
черновиков, сохранений, переименований и запусков сохранились. Геометрия чата
совпадает с чтением непосредственно перед остановкой: размер `537.5×567.5`,
anchor `(0.7464075374207251, 1)`. Камера обоих устройств: local
`(2396.697061217138, 6181.498541459997)`, tile `(0,-1)`, scale
`0.11027730044711667`, viewport `834×1194`; старое положение не возвращалось.

Физический снимок `.build/board-recipe-install/ipad-after.png` просмотрен:
холодный запуск показывает прежние обложки, рукопись и график. Чат свёрнут.
Это не физическое доказательство стирания, открытия пустой тетради или ввода
в терминал. Эти пользовательские сценарии и общая приёмка остаются открытыми.

Журнал macOS подтвердил предоставленный человеком доступ к Documents
12 сентября в 11:05. Дерево теперь повторяет неудавшееся чтение видимых папок,
не блокируя сохранение и не загружая скрытых потомков. Удержанный исход создания
разговора `F4F21136-9CBE-4519-9B16-7D6E946F5F35` остался неизвестным и не был
повторён. Его прежний тайм-аут больше не становится ошибкой текущей переписки;
новое создание не обрывается обычным коротким сроком чтения Codex.

`.build/chat-access/native-access.json` подтверждает на пустой отдельной задаче
установленного Codex чтение, полный доступ, возврат к проектному режиму и его
сохранение после нового подключения. Модель не запускалась, правами тест не
пользовался, настоящие задачи и общие настройки не менялись; пустая задача
архивирована. Разовое согласие, срок `session`, постоянный `always` для MCP и
точный объём файлового разрешения проверены на протоколе; постоянное разрешение
настоящему инструменту тест не выдавал. Неизвестная выдача доступа не исполняется
повторно и не мешает более позднему явному выбору. Произвольные формы MCP с
дополнительными полями по-прежнему требуют Codex на Mac; пустая форма согласия
больше не показывает один отказ.

## Что исполняет установленная версия

- Свободная геометрия чата, сворачиваемые файлы проекта, непрерывный нативный
  документ под чатом. Открытие, смена, закрытие файла и ссылки не используют
  пространственное открытие предмета; доска остаётся смонтированной.
  [Контракт файлов](project-code-document.md).
- Сохраняемые рассмотренные фрагменты, общие чернила и собственная причинная
  отмена. Изменённый или неоднозначный код сохраняет исходный материал заметки.
  TextKit и Metal действительно входят в замороженное изображение для обсуждения.
  Добровольная перепривязка меняет только адрес назначения, не рассмотренный
  текст или рисунок. Переименование из чата подтверждается настоящим Mac:
  оно сохраняет черновик, чтение и пометки, не заменяет существующий файл
  и после прерывания выясняет исход без повторного переноса. Переименование
  вне Notebook не угадывается по похожему тексту.
  [Пометки](code-annotations.md), [обсуждение](code-discussion.md).
- Один постоянный App Server Codex, прежние задачи, сообщения и разрешения.
  Приватный follower-путь удалён. Прямое доказательство установленного Codex
  `.build/app-server/live-final-receipt.json` проверило реальный ответ, прежний ID,
  повтор, переподключение, отказ разрешения, уточнение, остановку и чужого владельца.
  [Контракт](codex-desktop-bridge.md).
- Настоящий PTY процесса Mac, ввод/вывод, остановка и перезапуск из чата.
  `.build/terminal-drawer/native-run-complete.json` подтвердил русский текст и emoji, изменение
  размера, ожидание дольше обычного RPC, холодное чтение того же UUID и остановку.
  Сворачивание и обрыв iPad не создают новый запуск. [Контракт](project-runs.md).
- Голосовой разговор через WebRTC с существующим входом ChatGPT, без отдельного
  ключа. `.build/voice-probe/media-visible.log` передал синтетическую речь через
  настоящий WebKit, получил распознавание «two plus two» и ответ «Four», затем
  завершил сеанс. Микрофон человека не использовался. [Контракт](codex-voice.md).
- Отдельное окно каждого выбранного доверенного Mac. Два подставных компьютера
  с одинаковыми путями не смешивают черновики или команды. Холодный запуск,
  отказ записи/повтор и сохранение материала после отзыва проверены на нативной
  очереди и SQLite. [Контракт](computer-workspace.md).
- Внешняя подготовка дополнительного Mac из текущей копии iPad сохраняет
  действующую пару. Новый Mac получает собственную идентичность и допуск после
  своей фактической активации, затем обычное явное сопряжение. В изолированном
  сценарии проверены три назначения, холодный запуск и дальнейшая доставка
  в обе стороны; физический второй Mac ещё не установлен.
  [Допуск компьютера](computer-enrollment.md).

## Незавершённые условия milestone

**Физическая приёмка заблокирована системным разрешением iPad.** Отдельный
XCTest-исполнитель обращается к уже установленному приложению по bundle ID,
не собирает другую версию Notebook и не передаёт ему тестовые заготовки.
Три попытки — `.build/physical-milestone/inspect.xcresult`, `inspect-027.xcresult`
и `.build/milestone-physical-20260912-0752/inspect.xcresult` — закончились
`Timed out while enabling automation mode` до первого теста. Последний отказ
повторился 12 сентября; после него ожидание без нового системного подтверждения
не повторялось.
iPad снова показал запрос код-пароля
«Enable UI Automation»; секрет не запрашивался и обход не предпринимался.
Автоматические касания физического приложения ещё не исполнились. Амиру
предложено подтвердить системный запрос непосредственно на устройстве.

Открыты полный физический цикл файла/Pencil/агентской ссылки, правки и пометки,
запуск с iPad после обрыва, слышимость голоса и перебивание. Переименование,
добровольная перепривязка и подготовка третьего устройства реализованы и
проверены локально, но это не их физическая приёмка. Доступ к
MacBook-Air-Amir.local разрешён Амиром 12 сентября; SSH не отвечает, установка
не начиналась. Новый Mac нельзя включить копированием
идентичности первого или заменой текущего архива iPad.

**Отдельная диктовка — внешняя блокировка:** текущий App Server не предоставляет
поддержанный интерфейс распознавания в редактируемый черновик через авторизацию
Codex. Голосовой разговор не является диктовкой; Apple Speech удалён, отдельный
API-ключ не используется. GUI-191 и весь milestone не объявляются завершёнными.

## Навигация по ссылкам: 0.3.22 (25) установлена

Физическое открытие документа в 0.3.21 подтвердилось, но ссылки оглавления не
выбирали дальние страницы. Настоящее нажатие в `/tmp/notebook-links-before.xcresult`
воспроизвело этот отказ, без crash или runtime warnings. Индекс адресов теперь
строится при прежнем измерении источника и принадлежит `DocumentLayoutRecord`.
Текущий канонический фрагмент передаёт ссылку штатному владельцу страницы;
полный DOM не восстанавливается и второй порядок листов не создаётся.
Подробный контракт — [document-link-navigation.md](document-link-navigation.md).

Проверяются кодированные и именованные якоря, заголовки Markdown, возврат,
первые дубликаты, отсутствующая цель, внешние схемы и отказ поздних callbacks.
Полный прогон не запускается: выбран документный и композиционный набор плюс
один настоящий UI-сценарий перехода к дальней главе и назад. Общие UI-фикстуры
требуют явного `--test`; один профиль без названного жеста не допускает выпуск.
Маршрут `.build/document-links-verified` прошёл за 125,228 секунды: 24 Mac,
67 нативных iPad и один UI-сценарий, без ошибок, пропусков и runtime warnings.
Сам сценарий ссылки занял 16,417 секунды. SHA-256 проверенных исходников:
`819980e97f033b140a55b0a7a2ec74a7e6104ab604e8a864296bd65cbc7539e9`.
Следующий срез изменяет только выдачу суффиксов заголовкам и явный выбор проверок.
Для него `.build/document-links-linear` прошёл за 29,058 секунды: четыре проверки
ссылок на каждой платформе, 23 проверки выбора и 40 сборщика. UI и не затронутые
владельцы повторно не исполнялись. SHA-256 финальных исходников:
`908355a8cc1a62573074ec0dc92ae3eed152a348609ab244f01517b97753e84f`.
Подписанная пара собрана из этой квитанции и обновлена на месте 11 сентября,
23:10 МСК. Свежая независимая копия:
`/Users/amir/Documents/Notebook Backups/20260911-231007-before-document-links`.
Идентичности и активация сохранились; на iPad остаётся только preview-bundle
версии 0.3.22 (25). Живой установленный MCP 0.3.22 прочитал прежние страницы
0 и 37 с теми же PNG и квитанциями. Дополнительно страница с индексом 9
подготовлена за 4,935 секунды, устойчиво сохранена и прочитана обратно с тем же
PNG и квитанцией; исходник и камера не изменились. Свидетельство:
`.build/document-links-install-20260911-231007/mcp-new-page/result.json`.

Физический снимок `.build/document-links-install-20260911-231007/ipad-installed.png`
показывает обе настоящие обложки: тетрадь больше не представлена одной тенью.
Это не доказательство её раскрытия. После предложения нажать «Введение» или
«1 Основы» Амир подтвердил физический переход: «нажал - перешло».
Снятый позднее `ipad-link-destination.png` показывает оглавление (`1 / 83`),
а наблюдение MCP — индекс 0; сам переход этим снимком не удостоверяется.
Физическая проверка ссылки основана на ответе Амира, автоматический путь — на
отдельном UI-сценарии. Общая ресурсная приёмка приложения этим не закрывается.

## Исправление открытия бумаги: 0.3.21 (24) установлена

Открытая тетрадь или документ — ближайший владелец Pencil также между
штрихами. `SpatialInkSceneLease` передаёт этот адрес в существующий реестр;
установка сцены атомарно назначает его готовому backing приоритет ввода.
Закрытая соседняя бумага остаётся пассивной. Пределы 256 МиБ всего и 128 МиБ
пассивного содержания, плотность чернил и сами архивы не меняются.
Пакет страницы резервирует верхнюю границу только её блоков, не всего
исходника книги. Вычитаются лишь доказанно отсутствующие UTF-8 тела строк;
экранирование и метаданные продолжают учитываться с запасом.

Отрицательный контроль в `/tmp/notebook-focused-paper-before.xcresult`
воспроизвёл отказ при 206 253 799 занятых байтах: 132 277 543 считались
пассивными, поэтому следующие 2 124 558 байт отклонялись, хотя общий лимит
не исчерпан. Набор использует три настоящих нарисованных поверхности и
синтетический иллюстрированный источник больше 6 МиБ, не человеческий архив.
После исправления тот же бюджет удерживает все три поверхности и показывает
первую, среднюю и последнюю страницы; проверяется квитанция и текст настоящего
WebKit, а не только запрошенный индекс. Полный измерительный DOM удаляется,
исходник кодируется и размечается один раз.

Финальный выбранный маршрут `.build/focused-paper-selected` прошёл за
88,496 секунды: 8 Mac, 12 нативных iPad, 21 проверка выбора и 40 сборщика, без ошибок,
пропусков и runtime warnings. SHA-256 исходников:
`2ec855fc384467a3ad3b2f90c0947e4ac695831f426d2087f9d36519c6a784f4`.
Полный маршрут и UI повторно не запускались.

Подписанная пара из `a806ec7` установлена на месте 11 сентября, 22:40 МСК.
Свежая независимая копия:
`/Users/amir/Documents/Notebook Backups/20260911-224047-before-focused-paper`.
На iPad по-прежнему только `com.amirtlinov.notebook.preview`; установленные
версии 0.3.21 (24), акторы и квитанции активации сверены без замены архивов
или ключей. Свежий процесс установленного MCP 0.3.21 вернул 19 инструментов,
подключённый iPad, прежние исходник и устойчивые PNG страниц 0 и 37.
Во время запуска viewport перешёл из альбомного в портретный: центр, владелец
и страница сохранились. Полное равенство камеры не заявляется.

Физический снимок `.build/focused-paper-install-20260911-224047/ipad-installed.png`
после холодного запуска показывает настоящий текст и оглавление большого
документа, счётчик `1 / 83`, без прежней ошибки подготовки. Это подтверждает
открытие первого листа, но не десять повторов, все дальние листы или общий
30-минутный прогон. Для отдельного подтверждения тетради Амиру предложено
открыть её на экране; MCP читает её шесть листов и семь действий на обложке,
но это не доказательство её физического раскрытия.

## Исправление пустых слоёв: 0.3.20 (23) установлена

Пара обновлена на месте 11 сентября, 22:17 МСК. Свежая независимая копия:
`/Users/amir/Documents/Notebook Backups/20260911-221739-before-scene-sparse`.
Единственный iPad bundle, идентичности и активация сохранены. Установленный MCP
повторно прочитал страницы 0 и 37 с теми же устойчивыми квитанциями и PNG.
Это чтение готовых растров, а не новое доказательство показа на iPad.
Физический снимок `.build/scene-sparse-install-20260911-221739/ipad-installed.png`
подтвердил, что сцена теперь открывается, но сама страница сообщает об ошибке
подготовки. Этот второй отказ — причина исправления приоритета открытой бумаги,
а не основание объявить всю задачу завершённой.

`SceneCompositionSource` доказывает пустоту только полным адресным чтением
текущей ревизии, не более 64 записей на тайл. Если остался курсор, обычный
рендеринг сохраняется. В расчёт входят тени за границей. Подготовка не выделяет
растр для прозрачных диапазонов, сохраняя покрытие, порядок, живые обложки,
чернила, предел памяти 256 МиБ и исходную Retina-плотность.

Синтетический случай с тетрадью, A4 и уже нарисованными штрихами сначала
терял настоящего владельца обложки; после исправления сохраняет оба готовых
буфера чернил без пустых растров. Финальный выбранный маршрут
`.build/scene-sparse-selected-final` завершён за **24,805 секунды**: 3 Mac,
13 нативных iPad, 21 проверка выбора и 40 проверок сборщика. Ошибок, пропусков
и runtime warnings нет. SHA-256 исходников:
`81e314e65f256c4ebd8f0d8db2560a229ea7f94b1f3ab3c361983ab017eec9d3`.
Это не полный прогон и не физическая приёмка установленного приложения.

Два настоящих UI сценария в `.build/scene-sparse-selected-v2/ipad.xcresult`
прошли за 14,135 и 12,636 секунды: раскрытие документа через обложку и открытие
целого листа двойным касанием. Весь тот маршрут не был зелёным: три старые
ресурсные проверки рассчитывали на расход пустого растра. Их наборы заменены
реальным статическим содержанием, не ослабляя проверки давления, отмены и
освобождения. После этого UI не запускался повторно: 256 входов приложения
совпадают с финальной проверкой, что записано в
`.build/scene-sparse-ui-comparison.json`. Полные Core/нагрузки/44 UI не повторялись.

## Проверки по необходимости — 11 сентября

11 сентября полный прогон отделён от обычной итерации. Текущие команды и
условия выбора находятся в [контракте выпуска](release-build-contract.md#выбор-проверки).

Разбор уже завершённого iPad xcresult показал: 44 UI сценария заняли суммарно
851,524 секунды (14:11), ещё 462 нативных теста — 430,940 секунды (7:11).
Из них один тест адресного перехода по 100 000 листам занял 261,46 секунды.
Поэтому прежний «UI этап» фактически включал и всю нативную нагрузку.
`./verify.sh --timings /absolute/result.xcresult` разбирает эти времена без
повторного запуска. Автокоррекция, системный ввод и проверки жестов не отключены.

## Установка 0.3.19 (22): MCP работает, показ iPad не принят

Подписанная пара из `0d05e98` установлена на месте 11 сентября, 21:40 МСК.
На iPad остаётся только `com.amirtlinov.notebook.preview`; текущие архивы,
идентичности и доверие сохранены. Свежая независимая копия находится в
`/Users/amir/Documents/Notebook Backups/20260911-214021-before-large-document`.
MCP установленного помощника прочитал страницы 0, 20 и 37 большого документа
за 4,20–4,67 секунды, вернул устойчивые квитанции и те же PNG при обратном
чтении, не изменив документ или камеру. Физический показ не прошёл: iPad
остаётся на ожидании ресурсов. В консоли после подготовки нативных чернил
занято 190 488 576 байт, из них 116 371 008 в пассивной половине; подготовка
следующей цельной композиции отказывается. Установка не означает завершения
приёмки, этот отказ исправляется отдельно от уже работающего MCP.

## Объединённый выпуск 0.3.19 (22): полный маршрут пройден

Объединённый выпуск 0.3.19 (22) прошёл полный неизменный маршрут 11 сентября,
21:35 МСК: 540 Core, 36 Codex, 26 external, 44 MCP, 39 проверок первого
установщика, 40 сборщика, 130 Mac и 506 iPad/UI. Ошибок, пропусков и runtime
warnings нет. Квитанция связывает 535 исходников, SHA-256
`42f10803192366ca1cb8f47da4eec652b3440972e48d04ae2af02674cb28dda3`, и 2013 файлов свидетельств
в `.build/large-document-combined-full-evidence`. Состояние установки и живого показа описано выше.
Предыдущие остановленные прогоны не выдаются за PASS.

Источник объединения — `5cb7aaf` и `d7ca72c`. Первый прерванный кандидат
`.build/large-document-release-evidence` не включал последнее исправление
сворачивания. Его 535 входов имели SHA-256
`45b90f241cf36e4e0240821f2685d03890fb494c33029354a4a9ac73b48bcc79`;
наш процесс был остановлен после начала соседнего полного маршрута, до
собственного Xcode. Код завершения −15 и причина сохранены, PASS не выставлен.
Новый объединённый набор получает новый каталог свидетельств и номер версии.

## Сворачивание после «Нового чата» — 11 сентября, 20:45 МСК

Ветка `codex/chat-collapse-target` исправляет область нажатия двух соседних
кнопок в заголовке. `NotebookChatPanel` задаёт полный прямоугольник 44 × 44
точки на самих метках «Новый чат» и «Свернуть чат», не только размер картинки.
Состояние панели, сохранение переписки и владелец жестов не заменены.

Отрицательный контроль `.build/chat-collapse-corners/ipad.xcresult` получил
настоящий отказ: после «Нового чата» касание в нормализованной точке (0.9, 0.9)
не сворачивало панель, тогда как центр и (0.1, 0.1) работали. Это координатный
XCTest-жест, не прямой вызов действия. Отказ и снимки сохранены. После исправления
тот же сценарий проходит. Финальный профильный маршрут
`.build/chat-collapse-final-focused` дополнительно проверил центр и все четыре
угла, смонтированную переписку, настоящую клавиатуру, поворот и сохранение
черновика: **4 проверки**, 0 ошибок, 0 пропусков, `runtimeWarnings: []`.
Изолированная фикстура только сохраняет выбранный UUID чата; она не запускает
модель, не подключается к настоящему Codex и не пишет в рабочий архив.

По явному решению Амира 11 сентября в 20:41 МСК общий прогон
`.build/chat-collapse-full-evidence` остановлен на iPad-этапе; завершённые Core,
Codex, MCP и Mac проверки сохранены. Это **не полный PASS**: `interrupted.json`
фиксирует остановку, а прежняя квитанция не выдаётся за результат нового среза.
Для этой изолированной правки согласован выпуск по четырём целевым проверкам.
Подписанная сборка связывает их с отпечатком исходников и отдельно проверяет
подписи, устройство и отсутствие изменений за пределами двух областей нажатия,
регрессий и номера версии. Постоянный полный маршрут не ослаблен.
Пара **0.3.18 (21)** установлена на месте. Подписи и **531 исходный файл**
проверены до и после сборки, SHA-256
`398e4b3d702871a67ca46ef0945bca496d98c08ccbd8c21e291a95befab4334d`.
Подписанная сборка `.build/chat-collapse-signed` явно имеет статус
`targeted-verified-build`, а не квитанцию полного маршрута. Установка записана
в `.build/chat-collapse-install-20260911-204429`: на iPad только новый bundle,
отпечаток установленного Mac совпал, холодный запуск проверен. Свежие копии —
`/Users/amir/Documents/Notebook Backups/20260911-204429-before-chat-collapse`.
Архивы, идентичности и доверие не заменялись. MCP 0.3.18 автоматически вернул
19 инструментов и наблюдение `ready/connected`. Физический снимок подтверждает
запуск, но ручной жест «Новый чат → −» на устройстве ещё не подтверждён.

## Предыдущий выпуск — проекты и диктовка, 11 сентября, 19:50 МСК

Реализация находится в отдельной ветке `codex/chat-live-projects`. Профильный
маршрут проверил 7 Mac и 11 iPad/UI сценариев без ошибок и пропусков; голосовые
фикстуры проверяют уточнение текста, сохранение последних слов и запрет отправки
без человека. Настоящее распознавание речи на физическом iPad ещё не проверено.

Первый полный проход `.build/chat-top-voice-full-evidence` получил отказ в одном
из 527 Core-тестов: десятисекундный watchdog ожидал задачу остановки IPC,
запланированную в общем пуле вместе с синхронной нагрузкой. Проверочный вызов
получил явный executor и проверяет его до и после настоящего `stopAndDrain`.
Срок watchdog не увеличен, предел остановки остаётся одной секундой, очередь
проверяемых socket workers остаётся приостановленной до подтверждения drain.
Производственный IPC не изменён. После исправления 17 профильных IPC-тестов
прошли за 0.082 секунды. Первый отказ сохранён; новый неизменный полный проход
использует отдельный каталог `.build/chat-top-voice-release-evidence`.
Новый полный `./verify.sh` завершён в 19:47:02 МСК: **527 Core / 51 suite**,
**36 Codex / 3 suites**, **26 external / 4 suites**, **44 MCP**, **39 проверок
первого установщика**, **40 сборщика пары**, **120 Mac** и **495 iPad/UI**.
Обе нативные сводки: 0 ошибок, 0 пропусков, `runtimeWarnings: []`.
Системная клавиатура и автокоррекция не отключались; тесты не пропускались.
Совпали **531 исходный файл**, SHA-256
`27476ff331bda376be41223dae8301fb27e78212139ecf0c93532d100c2fa9cb`;
квитанция связывает **1931 файл** свидетельств. Подписанная пара
`.build/chat-top-voice-signed` повторно проверила эту опись и квитанцию.

На физическом iPad остался только `com.amirtlinov.notebook.preview`,
**0.3.17 (20)**; Mac обновлён до той же версии. До замены проверены отпечаток
предыдущего Mac bundle и версии обоих приложений. Данные, идентичности и
сопряжение не заменялись. Свежие копии находятся в
`/Users/amir/Documents/Notebook Backups/20260911-194917-before-chat-live-projects`;
прежние копии сохранены. Установка и холодный запуск записаны в
`.build/chat-live-projects-install-20260911-194917`. Отпечаток установленного Mac
совпал с подписанной сборкой; установленный MCP **0.3.17** вернул **19 инструментов**
и настоящее наблюдение `ready/connected`. Снимок iPad подтверждает запуск и
свёрнутую кнопку, но не физическую приёмку раскрытой панели или распознавания.
Профиль iPad действует до 16 сентября 2026, 14:15:33 UTC.

Тестовая диктовка не выдаётся за проверку живого микрофона. Пользователю предложен
короткий физический сценарий: разрешить микрофон, продиктовать и остановить,
проверить черновик без отправки. Настройки проектов используют канонический
App Server; мгновенное обновление кеша уже открытого окна Codex не доказано.
Ограничение независимо исполняющегося CLI и точные границы описаны в
[codex-desktop-bridge.md](codex-desktop-bridge.md).

## Снимок документа связан с версией рендерера

11 сентября, 20:02 МСК: **50 Mac-тестов**, 0 ошибок, 0 пропусков и
`runtimeWarnings: []`, на неизменных 525 исходниках, SHA-256
`525a8716d6c4db0c8261c8fa537977c09614c02162c8bab6490a51f9b03c8d54`.
Профиль — `.build/document-render-recipe-v3-evidence`.
На том же наборе прошли 12 Core-тестов / 2 suites за 1,716 с.
Сохранённый снимок большой книги готов за 5,222 с; проверены дальние страницы, PNG,
квитанции и повтор адреса после открытия другого SQL-владельца. Старый результат
рендерера не очищается и не выдаётся за новый. Предыдущий профиль отказал из-за
второго ручного исполнителя в тесте: теперь тест получает квитанцию штатного
помощника, без перерисовки и повторов ошибки. Подробности и граница установки —
[live-document-render-boundary.md](live-document-render-boundary.md).

## Большой документ: проверенный нативный срез

11 сентября, 19:12 МСК: **37 Mac** и **21 iPad Simulator** тест прошли на
неизменных 524 исходниках, SHA-256
`ed04b896d6bfdee658307b474240ae02c7a0c07856f355796edb873e6005a982`.
Ошибок, пропусков и runtime warnings нет. Синтетическая книга с 140 блоками,
35 встроенными SVG и 1680 формулами открывается за 3,615 с на Mac и 5,143 с
в Simulator без увеличения восьмисекундного срока. Проверены дальние листы,
точные пиксели возврата, геометрия, владение формулами, отмена индексирования
и ресурсы настоящего page curl. Описи и xcresult находятся в
`.build/large-source-native-v3-evidence`; причины исправления и отклонённые
прогоны — [live-document-render-boundary.md](live-document-render-boundary.md).
Это не полный проход `verify.sh` и не установка: последняя проверка живого
документа установленной пары пока остаётся неуспешной.

## Новый нативный срез: адрес физического фрагмента

11 сентября, 17:39 МСК: профиль прошёл **118 Mac** и **48 выбранных iPad**
тестов, без ошибок, пропусков и runtime warnings. Исходные 523 файла до/после
имеют SHA-256 `bae0cfbf598d01b4939cbd45f848c9cd34de2697b4a6039da0a3b1a89cb5d657`.
Смещение внутри блока входит в принятую нативную разметку и сравнение соседних
листов. Неверное, отсутствующее или логическое значение не становится нулём.
Новый набор не выдаётся за полный проход: предыдущий полный маршрут ниже
относится к своим 522 исходникам. Контракт, отрицательные проверки, исправление
фикстуры и незавершённый владелец программы — [document-program-cuts.md](document-program-cuts.md).

## Предшествующий полный срез — 11 сентября, 15:32 МСК

`.build/agent-command-read-full-cut` от `e3906b9` прошёл весь `./verify.sh`
с кодом **0**: **530 Core / 51 suites** (1031.049 s), **26 Codex / 2 suites**
(0.002 s), **26 external / 4 suites** (0.787 s), **44 MCP**, **39 проверок
первого установщика**, **40 сборщика пары**, **113 Mac** (218.835 s) и
**483 iPad** (1181.804 s). Обе нативные сводки: 0 ошибок, 0 пропусков и
пустой список runtime warnings. Автокоррекция, системный ввод, жесты и
количество повторов не ослаблялись.

До/после совпали 522 исходных файла, SHA-256
`f3e1ac388d3bc5b5cbde85238b843e8799e321d17a20eaa262b20fb0ddf74953`.
Квитанция `.build/agent-command-read-full-evidence/verification.json`
связывает **1879 файлов** свидетельств. `checked_verification` независимо
проверил байты свидетельств, исходники, обе сводки и инструменты.
Основное дерево на момент фиксации содержит тот же набор исходников;
проверки владения программами и физических фрагментов отделены в другие копии.

Общий допуск внешней команды принадлежит её SQL-соединению: строки и значения
учитываются до копирования в Swift, вложенное чтение не получает новый бюджет,
а пойманная ошибка не разрешает commit. Проверены отказ тяжёлых структурных
команд, отсутствие частичной записи и продолжение адресной правки на том же
листе. Расчёт размещения сохраняет запрос точного растра через существующую
очередь записи. Контракт, профиль и отрицательный контроль —
[agent-command-read-allowance.md](agent-command-read-allowance.md).
Журнал: `/tmp/notebook-agent-command-read-full.log`; точная разница:
`/tmp/notebook-agent-command-read-full.patch`.

Ограниченный отказ не подтверждает адресность структурных команд или входящего
тяжёлого слияния. Установка, свежий перенос, MCP установленной пары, физическая
приёмка и удаление старого приложения ещё не выполнены. Прежние полные срезы
сохранены в git; их квитанции остаются на диске и не заменяют текущую.

## Проверенный срез: один сохраняющий путь листа

Единственный `savePage` объединяет принятую копию, а ошибка чернил отклоняет
весь кандидат. SQL защищает заголовок и отмену, общее создание откатывает
членство при отказе листа. Связанный профиль прошёл **91 Core-тест / 7 suites**
за **3.957 s**. Одинаковые описи 520 файлов до/после имеют SHA-256
`a7374e9fb306322133690bd835588e785c33260e96168d54cd3fe717ae544187`.
Те же 11 регрессий на прежнем Core дают 91 нарушение. MCP прошёл 44 теста
и smoke, iPad — 86 тестов за 212.531 s; после исправления одной Mac-фикстуры
Mac — 10 тестов за 26.999 s. Ошибок, пропусков и runtime warnings в положительных
xcresult нет. Полный `single-page-owner-full-cut` (520 файлов, SHA `39552c12fa0408cd4c6693825a61000877f6e1e7c11dfdd18a4d5c35912ed16d`)
завершился с кодом 1: 510 Core-тестов, 17 отказов подготовки архивов,
391.283 s. Старые фикстуры записывали лист до членства; порядок исправлен
в той же транзакции. Неиспользуемый `publishRemoteWorkspace`, требовавший
предварительной записи зависимостей, удалён; смешанное добавление и удаление
проверяет обычный атомарный `saveWorkspaceBundle`. Новый срез 520 файлов:
`0ae09d3803e238807a5b4df4b44ab2d895fedf9358982ec404b37b91a8b74565`,
`.build/single-page-owner-member-first-full-cut`; его новый полный PASS получен
11 сентября, 13:17 МСК, как указано выше.
Профиль исправленного порядка прошёл 37 тестов / 4 suites за 170.878 s,
включая добавление среди 100 000 страниц: 5651 SQL-инструкций и 12 адресов.
Журнал — `/tmp/notebook-single-page-owner-member-first-profile.log`, статус 0.
Исходная опись профиля и нового полного маршрута совпадает. Промежуточный `page-ink-refusal-full-cut`
остановлен с кодом 130 при обнаружении прямого писателя; его PASS не объявлен.
Контракт, отрицательные проверки и исправления тестовых фикстур:
[page-ink-conflict-contract.md](page-ink-conflict-contract.md).

## Причины отрицательных прогонов и проверенные исправления

`DocumentPagePreparation` готовит один источник для четырёх существующих
WebKit, передаёт измеренные DOM-фрагменты и стили формул, сохраняет редактор,
а отменённая отправленная работа удерживает свой слот до настоящего callback.
Полный контракт и существенные отрицательные результаты находятся в
[document-page-fragments.md](document-page-fragments.md).

Целевой профиль `.build/shared-pagination-continued-paragraph-baseline.xcresult`
завершился 11 сентября в 07:56 МСК: 6 Mac-тестов, exit 0. На 121 странице
проверены все видимые графемы и векторы, нумерация списков, линии таблиц,
идентичность настоящих пикселей формул между соседними WebKit, отмена и бюджет.
Настоящие PNG таблицы, смешанного текста и формул просмотрены.
Первый полный Mac-профиль остановился после 37 успешных тестов на подготовке
источника без формул: отсутствующая SVG-таблица стилей передавалась CSSOM.
Отрицательная диагностика и зависшее оформление отказа XCTest сохранены в
контракте выше. После исправления прошли 104 Mac-теста и 57 связанных iPad-тестов без ошибок,
пропусков и runtime warnings (`shared-pagination-source-style-*-contracts`).
Это отдельные профили, не полный `verify.sh`.

Общий прогон `shared-pagination-full-evidence` завершился exit 65: 499 Core,
26 Codex, 26 external, 44 MCP, 39 проверок первого установщика и 40 сборщика
прошли; Mac — 103 успешных теста и один отказ.
`testSettledPageReadoutUsesTheVerifiedPageRaster` обнаружил различие SHA-256
опубликованной зависимости и независимого рендера того же листа.
Полный iPad-профиль не запускался. Неизменная опись 518 исходников имеет SHA-256
`dc7cd285c104a4828b81a5dbb58dbe177f5b66bcbfc173cb0ce36362a2d396d6`;
журнал и статус сохранены в `/tmp/notebook-shared-pagination-full.*`.
К диагностике добавлены настоящие PNG и квитанция. Отдельный успешный повтор
не устранил причину этого отказа и не сделал общий маршрут успешным.

### Владелец пиксельного буфера композиции

`SceneRasterCompositionTests.testPageCompositionRetainsItsPNGIdentityDuringParallelVisionEncoding`
воспроизвёл оба исходных SHA-256 уже на второй итерации. Настоящие исходные
изображения Canvas менялись до кодирования и смешивания композиции: 43 167
пикселей сетки отличались на единицу компонента; размеры, фон и метаданные
совпадали. PNG сохранены в `/tmp/notebook-pagination-parallel-encoding-attachments/`,
промежуточные исходники — `/tmp/notebook-parallel-raster-stage/`.
Смена calibrated RGB на sRGB не устранила отказ (`pagination-explicit-paper-color`,
exit 65), а проверка восстановления `NSGraphicsContext.current` подтвердила
исходный nil. Эти гипотезы не оставили изменений в рабочем коде.

`SceneRasterCompositor` теперь передаёт `ImageRenderer.render` свой заранее
учтённый RGBA8/sRGB CGContext с точным размером и масштабом. Отсутствующий
callback или несовпадающий размер возвращает отказ, а не готовый пустой растр.
Автоматический `ImageRenderer.cgImage` больше не выделяет растр этого пути;
источники, порядок композиции и фоновая подготовка карты чернил сохранены.
`pagination-owned-artwork-context` прошёл все 64 цикла совместной подготовки
(1 тест, 84.228 s). `pagination-owned-artwork-calibrated-fixture` прошёл 3 теста:
квитанция листа, чередование размеров/плотностей и точные оси/альфа при дробном
размещении. Полный Mac-профиль `pagination-owned-artwork-full-mac` прошёл 108 тестов
(187.182 s) без ошибок, пропусков и runtime warnings. Штатно подписанный iPad-профиль `pagination-keychain-signed-ipad-contracts`
прошёл 65 тестов (18.617 s) без ошибок, пропусков и runtime warnings.

Следующий неизменный общий прогон `owned-artwork-pagination-full-evidence`
завершился exit 65: 499 Core, 26 Codex, 26 external, 44 MCP, 39 проверок
первого установщика, 40 сборщика и 108 Mac прошли. На iPad прошли 472 теста,
семь сценариев документов отказали до готовности страницы; пропусков и runtime
warnings нет. Опись 518 файлов имеет SHA-256
`b9efabe9145f14956a3feb17604cabb5b003e3c2c1fb4e03da1bb12b1c241643`.
Журнал и статус — `/tmp/notebook-owned-artwork-pagination-full.*`.
Реальная диагностическая сцена показала `resource_limit` при 60 817 408 байтах
удержанной сцены: максимальные резервы разметки и фрагмента одновременно
занимали ещё 72 МиБ, сверх пассивной половины общего бюджета. Отрицательный
`pagination-native-document-diagnostic` прерван при оформлении отказа XCTest,
exit 75; его журнал и sample сохранены, успешным повтором он не назван.

Передача заменена на объявление и допуск фактического размера неизменного
пакета, с проверкой адреса и точной длины. Общая разметка сама удерживает
свою аренду до последнего читателя. `sized-document-packets-layout-ipad-contracts`
прошёл 14 тестов (48.670 s), включая подготовку рядом с удержанными 60 МиБ
и прежнее настоящее перелистывание текста туда и обратно; ошибок, пропусков
и runtime warnings нет. Предыдущий запуск этого профиля остановился на ошибке
типа нового тестового callback, до исполнения тестов.

Срок жизни разметки выявил прежнего лишнего владельца: реестр удерживал её
после последнего исходника. `sized-document-packets-browser-mac-contracts`
остановлен при оформлении отказа проверки отмены (exit 75, sample сохранён).
Реестр теперь ссылается на разметку слабо; сильные владельцы — живой источник,
сохранённый растр и фактическое обратное чтение. Вытеснение непоказанного
растра освобождает его разметку до нового расчёта допуска. Профиль
`sized-document-packets-raster-owner-mac-contracts` прошёл 38 тестов (44.099 s)
без ошибок, пропусков и runtime warnings: отмена, запрет изменившейся длины
обоих типов пакетов, адреса, исчерпание ресурсов, явный повтор и реальный растр.
Освобождение последнего читателя также удаляет адреса и диагностику реестра.
Полный Mac-профиль `sized-document-packets-final-full-mac` прошёл 113 тестов
(191.620 s) без ошибок, пропусков и runtime warnings, включая этот переход.

После появления готовой страницы UI-проверка конечной бумаги обнаружила
своё требование старого полного DOM: соседняя бумага ожидалась внутри первого
WebKit ещё до перелистывания. `sized-document-packets-seven-ipad-scenarios`
сохраняет этот отказ и sample (exit 75). Проверка заменённого пути теперь
выполняет настоящий page curl, проверяет одинаковую конечную геометрию A4,
посадку в центр и отсутствие номеров чужих страниц в текущей оболочке.
`sized-document-packets-physical-owner-ipad-contracts` остановился в этой новой
проверке на числе меток системного дерева доступности; геометрия и посадка
до этого прошли. `sized-document-packets-finite-addresses-ipad-contracts`
сохранил ещё один отказ того же строгого выражения (exit 75). Диагностический
`sized-document-packets-native-address-diagnostic` установил точную причину:
WebKit добавляет локализованную роль, и полная метка равна
`Страница 2 из 5, область`; строгое выражение возвращало пустой список.
Нативное дерево сохранено в `/tmp/notebook-sized-document-packets-native-address-observation.txt`.
Проверка теперь использует тот же префикс адреса, что и существующее нахождение
бумаги; число DOM-элементов отдельно проверяет реальный WebKit-профиль.
Оба настоящих кадра просмотрены: `/tmp/notebook-sized-document-packets-finite-page-negative.png`
и `/tmp/notebook-sized-document-packets-finite-second-page.png`.
Контроль сохранённой третьей страницы теперь сравнивает распознанные заголовки
реального кадра с последовательным приходом на этот же лист, не ищет прежний
маркер в полном дереве доступности. `sized-document-packets-visible-pages-ipad-contracts`
остановился на ожидании (exit 75); подробный неизменённый запуск
`sized-document-packets-ui-transition-diagnostic` локализовал его в новом
контрольном пути. Первые шесть UI-сценариев прошли, но немедленный swipe после
повторного запуска предшествовал готовности соседнего листа; номер и количество
страниц не являются квитанцией готовности соседней WebKit. Контроль использует
существующую кнопку следующей страницы: она сохраняет цель до готовности, а
тест дополнительно ждёт установки и центрирования самой физической бумаги.
Проверки настоящих свайпов не изменены. Новая проверка не подменяет кадр номером.
`sized-document-packets-stored-selection-ipad-contract` прошёл один тест
(27.478 s). Оба кадра 1640×2360 просмотрены и имеют одинаковые RGB-пиксели:
`/tmp/notebook-sized-document-packets-stored-selection-attachments/775882A2-8371-44CB-A3D2-7FBEA3544579.png`
и `A2766A37-7B0C-467E-8B69-77D665762D53.png`; распознаны разделы 17–26.
Это сравнение конкретной пары настоящих снимков, не обещание идентичных
системных пикселей любого последующего запуска.
`sized-document-packets-complete-ipad-contracts` прошёл 45 тестов
(190.195 s) без ошибок, пропусков и runtime warnings: 38 ресурсных проверок
и все семь сценариев документов. Неизменный полный маршрут выполнен в
`bounded-document-packets-full-cut`, свидетельства —
`bounded-document-packets-full-evidence`. При запуске все три дерева — рабочее,
целевой профиль и полный срез — совпали по 519 исходным файлам, SHA-256
`6267e65138983b87a3391b21befe14da1bdebe55eb2bd3777f75ba9f0d688125`.
Полный PASS подтверждён квитанцией выше; основания для установки ещё зависят
от открытых условий перехода и свежих архивов, а не только от этого прогона.

Предшествующий отдельный iPad-профиль ошибочно запускался с
`CODE_SIGNING_ALLOWED=NO`: 64 теста прошли, Keychain вернул отказ.
`pagination-keychain-unsigned-diagnostic` сохранил точный системный статус
−34018 — отсутствует обязательное право подписанного приложения. Возвращён
штатный подписанный запуск, который уже используется в `verify.sh`; проверка
Keychain, защищённость хранения и сам `verify.sh` не ослаблены.

Оформление отрицательных проверок `pagination-parallel-encoding`,
`pagination-raster-stage` и `pagination-context-restore` зависло в
CoreSymbolicationDT. Стек, журналы, сохранённые изображения и exit 73 оставлены;
эти прерванные запуски не названы полными PASS. Геометрическая фикстура сначала
ошибочно предполагала чистый RGB у системного `Color.red`; теперь она задаёт
точные компоненты, а не ослабляет проверку цвета или координат.

## Системный ввод: сохранённый отрицательный контроль

На Simulator iOS 27 `24A5408d` полный проход
`.build/addressed-pages-verified-20260910/` завершился exit 65 из-за
`testQuestionDraftSurvivesRotationAndRemainsReachableAboveKeyboard`.
После поворота системный `InputUI` аварийно завершился с SIGABRT:
`TUIKeyboardCandidateMultiplexer` → `TUIInputSession.pushAutocorrections` →
`UIView.setHidden` → `UIFocusSystem` → assertion UIApplication на фоновой очереди.
Отчёт `InputUI-2026-09-10-104029.ips` сохранён в его `evidence/inputui-crash/`.

Независимый `.build/stock-inputui-20260910/` со стандартным SwiftUI TextField,
без моделей и рендера Notebook, воспроизвёл ту же цепочку и SIGABRT:
`InputUI-2026-09-10-105421.ips`, `control.xcresult`, `exit.txt` и
`source-manifest.json`. Гипотеза о дополнительном окне не подтвердилась;
её изменения удалены. Отказ не скрыт повтором, пропуском или отключением
автокоррекции.

Официальный Simulator runtime `24A434` установлен рядом с прежним. Независимый
TextField-контроль прошёл в `.build/stock-inputui-rc-20260910/`.
Устройство `CBDE7503-A0F7-4B92-85B5-626B9375E0FA` использует именно этот build;
он подтверждается getenv и xcresult. Проверка Notebook сохраняет открытые
клавиатуру и черновик через поворот и сворачивание, затем дописывает текст.
Системная Cmd+Right явно ставит курсор в конец, а не предполагает положение
после касания. Прежний отрицательный тест положения курсора сохранён в
`.build/chat-keyboard-rc-20260910/` как interrupted, не pass.
Исправленный профиль `.build/chat-keyboard-rc-positioned-20260910/` и последующие
полные маршруты прошли с включённой автокоррекцией. Это не подтверждение
другого build на физическом iPad.

## Как воспроизводится полный маршрут

`./verify.sh --full` последовательно проверяет Core и нагрузки, внешнюю подготовку
архивов, защиту первого установщика, иконки, MCP с изолированным IPC,
закреплённый Codex App Server с mock-provider, Mac runtime и настоящий
безоконный PNG, Release Simulator и весь iPad runtime/UI.
Манифесты до и после связывают результат с одним неизменным набором исходников;
commit сверяется с этой описью по байтам и исполняемым режимам файлов.
Предыдущие квитанции остаются свидетельствами своих срезов, история — в git.

Среда последнего полного прохода: Xcode 27 beta 5 `27A5237l`,
`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.5.app/Contents/Developer`,
macOS 27 `26A5421a`, Simulator `24A434`. Несколько Xcode/Simulator runners
одновременно не запускаются. Новый helper никогда не направляется на прежний
человеческий архив; все автоматические команды имеют отдельные `NOTEBOOK_HOME`
и соответствующий IPC-процесс.

## Граница установленной пары

Simulator не подтверждает представление кадров на физическом iPad, задержку
Pencil, полный RSS, CPU/GPU или готовность настоящего архива на 100 000 предметов.
CADisplayLink сообщает частоту callback, не FPS. Требуются десять повторов
реального сценария и 30 минут совместной работы с измерениями представленных
кадров и ресурсов. Контроль App Server с mock-provider не удостоверяет
человеческий вход и исполнение установленного помощника.

Восстановление исторических архивов отменено Амиром; копии остаются в резерве.
Старый iPad bundle уже отсутствует. Следующее обновление сохраняет текущее
пространство, контейнеры, идентичности и доверие: оно не запускает перенос или
повторную активацию. Непосредственно перед обновлением нужна короткая пауза
рисования и свежие независимые копии нынешних Mac и iPad. Подписанная пара
должна происходить из собственной окончательной квитанции; проверка первого
Lab не обходится. После обновления проверяются установленные версии, единственный
bundle, холодный запуск и живой MCP, включая реальный большой документ.

## 12 сентября — тихая публикация и голосовая переписка

Исправлена проекция нативного голосового поручения: только просьба, без
накопленного протокола и служебного хвоста завершения. Завершение нового
звонка не запускает дополнительное поручение. Удалено уведомление о правке;
короткий перламутровый контур относится к видимому объекту. История и отмена
остались в меню чата без постоянной карточки на доске.

`.build/board-repair-first-cut-2` проверяет 29 Codex и 14 iPad-тестов:
повторную доставку нативного сообщения, растр без второго кеша, смонтированный
SVG при трёх масштабах, показ правки, стирание Pencil и холодное чтение.
Все прошли. `.build/board-repair-quiet-ui-3` проверяет настоящий жест открытия
истории после удаления карточки: 1 UI-тест, без ошибок и предупреждений.
Промежуточная попытка с системным контекстным меню выявила предупреждение
UIKit; доступ перенесён в обычное компактное меню существующего заголовка.
Физическая резкость на установленном iPad ещё не подтверждена этим срезом;
он не закрывает сообщения пользователя о синхронизации и голосе.

## 12 сентября, 21:24 МСК — компаньон и текущая работа

Кандидат **0.3.40 (43)** заменяет автоматические тучки небольшой панелью
компаньона: письмо раскрывает прежний черновик, стрелка возвращает ту же
переписку, карточка сообщает о работе или непрочитанном ответе. Необходимый
вопрос не скрывается настройкой карточки. Модель, мышление и контекст находятся
справа возле диктовки, голоса и отправки. Комментарии и инструменты одного хода
раскрываются из перламутровой строки текущей работы; завершение, запрос решения
и обрыв выключают перелив. Звук GPT отключается независимо от микрофона и сессии.

Неизменный маршрут `.build/companion-release-check/verification.json` прошёл:
17 Core, 11 Mac и 22 iPad/UI проверки, без падений и пропусков. Настоящие жесты
в Simulator сохранили бумагу и принятые чернила при сворачивании, редактировании
черновика, одной отправке, возврате к точному ответу, повороте и изменении окна
за четыре угла. Проверены правое расположение модели, доступность голосовых
кнопок в узком чате и прежние прикрепления. Нативный WebKit проверил один набор
элементов, раскрытие подробностей после изменения ширины и остановку перелива;
голосовой тест выключил только воспроизведение, сохранив микрофон и прежний peer.

Первый компиляторный проход нашёл захват ещё не завершённого значения статуса;
он исправлен локальным идентификатором хода. Общая проверка выявила старые
фикстуры чата, отвергавшие чтение состояния скрытого терминала как запуск.
Они теперь отвечают именно на чтение, продолжая запрещать новые действия.
Проба DOM больше не пытается вернуть нативному коду сам HTML-элемент.
Снимки настоящих жестов просмотрены; чёрный снимок отдельного offscreen DOM-теста
не используется как визуальное доказательство. Это локальный срез, не полная
физическая приёмка и не подтверждение недоступной отдельной диктовки Codex.
### Установлено 12 сентября, 21:31 МСК

Пара **0.3.40 (43)** установлена в прежние Mac и физический iPad после свежей
независимой копии `Notebook Backups/20260912-212400-before-companion-current`.
Установщик дождался `verified-build` для обеих подписей; попытка на промежуточном
`building` ничего не устанавливала и не останавливала. Действующих терминалов,
неподтверждённых голосовых начал и принятого Pencil-контакта перед остановкой
не было; Mac завершён обычным AppKit-запросом, без сигнала принуждения.

`.build/companion-install/installed-readback.json` подтвердил неизменность 1456
записей Mac и 1430 записей iPad, кроме служебного состояния ввода. Сохранены
камера непосредственно перед остановкой, выбранный материал, два файловых
черновика iPad, все 108 запросов с прежними исходами, вывод терминала, окно
443×460,0439 и доверие пары. Неизвестное создание F4F21136… осталось uncertain:
повтора не было. Изменения человека, сделанные во время разработки, вошли в
свежую копию и не откатывались к состоянию начала работы.

Версии приложений прочитаны из установленного Mac bundle и списка приложений
физического iPad, не из каталога сборки. Живой MCP установленного помощника
вернул ready и связь с прежней доской; неизменённый пакет инструментов продолжает
объявлять собственную версию 0.3.39, она не является версией приложения.
Снимок `.build/companion-install/ipad-after.png` показывает новую небольшую
панель компаньона и чёткую прежнюю таблицу при сохранённой камере. Контекст
выделенной человеком области сохранён, не очищался ради снимка.

Исходники 9c87930 отправлены. Сборка `.build/companion-release/build.json`
привязана к `f445ab800bd982ec75b70e8b41571ab4984599db038fc6ce77886e6bb22061de`.
При чтении результатов отдельно переформатированный summary был возвращён
побайтно из запечатанного stdout: исходный SHA и вся опись проверены без замены
результатов тестов. Физическая проверка касаний и живого голоса не подменяется
установкой, снимком или Simulator; системное подтверждение UI Automation не
обходилось, отдельная диктовка Codex по-прежнему не предоставлена.

## Артефакты, удержание и Pencil — 12 сентября, 22:06 МСК

Срез устраняет наблюдавшийся в 0.3.40 разрыв между материалом агента и вводом
человека. Палец удерживает и переносит сам артефакт вместо выделения области;
рамочная кнопка перемещения и отдельный режим редактирования удалены.
Перемещение сохраняет исходный масштаб контакта, прежнюю запись положения и
причинную отмену. Оно не создаёт новое указание или поручение. Лист принимает
Pencil над непрозрачным и интерактивным материалом, не меняя владельца чернил.
Тот же порядок «бумага → материал → чернила» проверяется в снимке для агента;
ссылка только на элемент по-прежнему не раскрывает соседнюю рукопись.

Большая карточка «Амир указал область», её раскладка вокруг материала и
подписи над выделением удалены. Над материалом остаётся тонкий контур;
`NotebookContextCounter` показывает количество сохранённых ссылок внутри чата
и компаньона. Из него доступны источники, состояние версии и снятие выделения.
Обычные перенос, размер и удаление больше не вызывают уведомление в центре.

`.build/artifact-input-checked/verification.json` подтверждает **17 Core,
17 Mac и 37 iPad/UI** проверок без ошибок, пропусков и runtime warnings.
Исходники: `b7aede5c571a892d2dc157f5e599e1ff95efa0ec5de41a76e1e3518b4777fb59`.
Отдельно четыре `DocumentRenderRecipeTests` прошли на тех же исходниках
(`.build/artifact-input-core-final.log`). Новый адрес снимка страницы не
перезаписывает историческое содержание или старые квитанции.

Нативные проверки провели Pencil через настоящий hit-test поверх HTML-кнопки,
сохранили новый штрих при неизменном элементе и камере, перенесли график доски
при масштабе 0,5 и прочитали новое положение с диска. Настоящие жесты Simulator
перенесли и удалили элемент с листа, сохранили доработку после отмены агентского
хода, сняли и вернули указание из истории и проверили один счётчик в обеих
формах чата. Снимки в `.build/artifact-input-checked-images` просмотрены.

Первые сборки обнаружили отсутствовавшую среду модели у окна и неверную форму
тестового callback; исправлены. Проба `XCUIScreen.screenshot` внутри нативного,
а не UI-теста остановилась в XCTest: стек `.build/artifact-native-sample.txt`.
Остановлен только изолированный Simulator runner, снимок теперь берёт сам
смонтированный UIWindow. Последующая пиксельная проверка после истории сначала
сравнивала бумагу с перекрывающим её раскрытым чатом. Она возвращает чат в ту
же свёрнутую форму до сравнения; требования сохранности пикселей не ослаблены.

Это выбранная проверка изменённых владельцев, не полная физическая приёмка.

### Установлено 12 сентября, 22:12 МСК

Пара **0.3.41 (44)** установлена в прежние Mac и физический iPad из
`.build/artifact-input-release/build.json` со статусом `verified-build` и тем
же SHA исходников. Версии прочитаны из установленного Mac bundle и списка
приложений физического устройства. Исходники `5b17ce0` отправлены в текущую
ветку. Свежая независимая копия:
`/Users/amir/Documents/Notebook Backups/20260912-220047-before-artifact-input`.
Перед обычным завершением Mac не было действующего терминала, незавершённого
голосового начала, очереди отправки, сохранения файла или Pencil-контакта.
Прежнее разрешение на прерывание работы не использовалось повторно.

`.build/artifact-input-install/installed-readback.json` проверил 1456 записей
Mac и 1430 записей iPad. Изменилось только служебное состояние ввода;
содержание, выбранные ссылки, камера, доверие, два черновика файлов iPad,
все 108 запросов и их исходы, вывод терминала и геометрия чата сохранены.
Неизвестное создание F4F21136… осталось `uncertain`, без повторного поручения.
Живой MCP установленного помощника вернул `ready` и прежнюю доску.

Физический снимок `.build/artifact-input-install/ipad-after.png` просмотрен:
в компаньоне небольшой счётчик «2», над материалом только тонкие контуры,
без большой карточки и надписи «Амир указал область». Прежняя таблица остаётся
чёткой, камера совпадает с состоянием перед остановкой. Выделение человека не
снималось ради проверки. Установка и снимок не доказывают физический перенос
пальцем или письмо настоящим Pencil: системное подтверждение UI Automation
остаётся не пройденным, обхода и повторной попытки без изменения условий не было.

## 15 сентября — пассивный SVG передаёт первый drag камере (GUI-200)

Отдельное исправление пользовательского дефекта в `codex/svg-camera-input`,
база `83a2e5a`. Рабочая копия основной задачи и установленная пара не изменялись.
Устранены два запрета: каждый установленный WebKit больше не считается
интерактивным по самому факту установки; рамка пассивного элемента больше
не отзывает уже допущенный камерой контакт. Отсутствие кода/контролов/обработчиков
определяет существующее token-scoped завершение `AgentWebCoordinator`.
Runtime, ресурсы и публичный API не заменялись. Программы с кодом и контролами
консервативно сохраняют ввод всей поверхности; это не DOM hit-region routing.

На iPad Air 11-inch (M4), Simulator iOS 27.0 (24A434), Xcode 27A266a:
**4/4 выбранных проверки PASS**, `source-before == source-after`,
SHA-256 `259f04de30fe830e6ac81d014d81049d7c9e3ad11aa13eb904ab262670e12aaa`.
`AgentSceneFingerRoutingTests` проверил 12 настоящих загрузок WebKit, включая
SVG, inline-код, удаливший себя script, SVG xlink, SMIL-контакт, media controls
и возврат от интерактивного источника к пассивному. Проверены native ancestors
внутри сцены и прежняя регрессия сохранения принятого ввода при смене плотности.

UI `testDraggingPassiveSVGFromFirstContactMovesCameraAndKeepsControlsIndependent`:
без активирующего тапа два drag по SVG сдвинули **обе** native WK-рамки на
`(+90,+60)` и `(-50,-40)` pt, без изменения размера. Кнопка дала ровно `Count 1`;
настоящий drag slider изменил значение без движения камеры; pan не активировал
соседнюю кнопку. Все три снимка до/после просмотрены.
Доказательства: `/private/tmp/Notebook-svg-camera/.build/svg-camera-v3/`,
`ipad.xcresult`, `completed.json` и `attachments/` с изображениями и рамками.

Первый UI-прогон остановился до pan: WebKit не предоставляет XCTest native
scrubber bounds; вместо `adjust` использован настоящий drag видимого thumb.
Второй дошёл до успешного первого pan и остановился на побитовом сравнении
CGFloat (разница высоты около `6e-14` pt). Сравнение размера исправлено на
допуск `0.01` pt; между v2 и v3 изменились только два файла тестов, не приложение.
Контакты после pan опирались на свежие native WK-рамки, не дочерний AX.
Это узкая Debug/Simulator-приёмка дефекта, **не** исправление устаревшего AX,
не системные измерения и не физическая/Release-приёмка. На устройства не ставили.


## 16 сентября, 18:38 UTC — убрать повторный разбор чернил при переходе

Адресное чтение больше не строит JSONValue-дерево и не сериализует его обратно.
Подготовка камеры/повторная попытка бюджета берёт уже измеренные штрихи из
существующего cohort только при той же SQL-версии и полном покрытии поверхностей.
Новый контакт или новая поверхность читаются заново; дополнительного кэша нет.
На iPad установлена пара `bc442572a9aded73a07e22c9e0de24a612df84528bede8a89c9f26165553b532`.
Короткий Back из дочерней доски показал родительскую доску с материалами;
трасса `.build/seven-slices-physical/ordinary-exit-1835.trace`: 1,276 CPU-с чтения
чернил за35с (раньше12,320 за45с, но камера/начальная граница различались —
это не контролируемый замер задержки перехода). Сохранённый лист/документ неизменны.
Регрессии: семь Core-проверок измерений/undo и два native SQL-сценария; свидетельства
`.build/ordinary-ink-core.log`, `.build/ordinary-navigation-ready/`.
Драйвер полного цикла18:34 остановился до жеста: ожидал корневую доску, а открыта
была дочерняя. Полный рабочий цикл,50мс p95 и4мс главного потока не подтверждены.
Следующие приоритеты Амира: адресные блоки вместо полного JSON до первой страницы,
сохранение готовой подготовки при возврате, пространственная выборка ink chunks.

## 17 сентября, 00:04 МСК — адресный приём каталога, досок и элементов листа (GUI-206)

Отдельная ветка `codex/notebook-offline-sync` от `f5011d1`; незавершённые
правки основной рабочей копии не включены. Старые ветви полного слияния
`workspace.json`, `board.json` и `pages/*.json` удалены из `applyRemoteChange`.
Конфликты полей, размещений, порядка страниц, undo и публичные ожидания MCP
не заменены новой политикой. Общая SQLite-транзакция и очередь приложения
остаются владельцами записи. Установленная пара и человеческие данные не менялись.

**106 Core-проверок в 12 наборах PASS**, 15.022 s: адресная репликация,
повтор и атомарный отказ, старое эхо, причинные конфликты, отдельные и общие
поля листа, конкурирующие добавления страниц, владение размещениями,
графика, вычисления и undo. Отдельный тест повреждает недоступные соседний
элемент и рисунок: правка другого элемента проходит, не читая их тела.
Журнал: `/tmp/notebook-sync-final-core.log`. Это не полный `verify.sh`.

Контролируемый Debug/Swift 6.4 профиль: одинаковая форма 1000 реальных
независимых владельцев, один соседний HTML размером 1 000 000 байт.
Исходный `f5011d1` и новый код запускались отдельно, без параллельных runners.
SQLite trace считает фактически выданные строки и BLOB-значения, не число
вызовов JSONDecoder. Время — от начала до завершения SQLite-команды, не LAN/UI.

| Приём | До: BLOB-чтения / байты / время | После: BLOB-чтения / байты / время |
|---|---:|---:|
| Перемещение | 6028 / 2 719 318 / 722.1 ms | 28 / 9596 / 24.5 ms |
| Элемент листа | 40 / 1 018 463 / 42.2 ms | 46 / 21 783 / 20.1 ms |
| Заголовок предмета | 5026 / 2 069 266 / 641.9 ms | 37 / 16 270 / 24.5 ms |

Рост числа мелких чтений элемента не скрыт: выигрыш здесь — исключение
чужого мегабайтного тела. Пиковый RSS всего процесса, включая подготовку
фикстуры: 146 833 408 B до и 146 735 104 B после. Это **не** измерение отдельного
пика merge и не доказательство выигрыша памяти приложения.
Журналы: `/tmp/notebook-sync-before1000.log`, `/tmp/notebook-sync-after1000.log`.

Дополнительный потоковый профиль **100 000 реальных независимых владельцев**
прошёл за 436.417 s вместе с построением данных. Перемещение: 28 BLOB/9596 B,
3500 SQL VM steps, 28.3 ms; элемент: 46 BLOB/21 783 B, 2900 steps, 23.6 ms;
заголовок: 37 BLOB/16 270 B, 4200 steps, 26.9 ms. Повтор: 0 BLOB, 3 SQL строки.
Объём чтения тех же правок совпал с 1000 владельцев. Пик всего процесса с
фикстурой — 1 021 820 928 B. Журнал: `/tmp/notebook-sync-scale100k.log`.
Этот профиль выполнен до последней дополнительной проверки каноничности
заголовков; она не добавляет SQL-чтений и проверена в финальных 106 тестах.

Граница среза: изменение самих чернил листа ещё восстанавливает `drawingData`,
а native `savePage` сохраняет полный запрошенный лист. Облачная доставка,
generation журнала, provisioning и CloudKit пока не реализованы этим срезом.
Нет измерения задержки до показа, системных CPU/GPU/кадров, десяти повторов
на физической паре и 30 минут совместной работы. GUI-206 остаётся открытой
до незакрытых условий, GUI-207 ведёт отдельную облачную доставку.

## 17 сентября, 01:18 МСК — общий журнал и CloudKit-доставка (GUI-207)

В изолированной ветке `codex/notebook-offline-sync` добавлен общий
`NotebookReplicationDelivery`: source device + generation, immutable transaction
и ссылка на manifest. LAN v16 и CKSyncEngine используют один Core apply и
очередь сохранения приложения. Повтор и пересылка не создают нового transaction
ID; снимок покрывает исходный префикс и объединяется, а не заменяет локальную
тетрадь. Cloud SQLite staging/outbox, порции CKAsset до 1 MiB, engine tokens и
ACK устойчивы к перезапуску. Собственные cloud records не создают вечную inbox.

Cloud выключен по умолчанию; явное включение находится в существующих окнах
устройств. Смена аккаунта не переносит тетрадь автоматически. Начальная проверка
аккаунта не задерживает старт LAN, загрузка/сборка assets не выполняется внутри
очереди сохранения. Полный первый снимок всё ещё является согласованным SQL cut;
его длительность на физическом большом пространстве отдельно не измерена.

Финальный повтор: **126 Core-тестов / 14 наборов** и **4 archive-transfer теста**:
`/tmp/notebook-cloud-final-core-r3.log` (17.237 s и 0.878 s), immutable source map
в `.build/cloud-delivery-final-commit-core-proof.json`. Включены offline
restart, независимые и одинаковые поля, сохранение tombstones, snapshot floor,
перестановки LAN/cloud, self-echo, частичный большой asset, отказ до commit и
потерянный ACK после commit. Это локальная модель облачного сервера, не iCloud.
`MCP/npm run check` и **51 MCP-тест PASS**, `/tmp/notebook-cloud-mcp-final.log`.
Публичные CAS/undo не получили новой политики. IPC test host использует
изолированное хранилище, установленный helper не заменялся.

**41 preview guard + 70 release guard PASS**:
`/tmp/notebook-cloud-preview-final-r2.log`,
`/tmp/notebook-cloud-release-final-r3.log`. Подписи требуют точные CloudKit/Push
права и Production-контейнер. На Mac profile проверяет именно Provisioning UDID,
не Hardware UUID; unrestricted get-task-allow проверяется в подписи, без ложного
требования к profile. CloudKit Mac-подпись обязана содержать собственные App ID
и team entitlement, а не только ссылаться на верный embedded profile.
Это проверки выпускного контракта с фикстурами, не
подтверждение действительных CloudKit profiles или серверной schema.

Выбранный native route `.build/cloud-delivery-native-20260917-r3/verification.json`
прошёл **4 Mac + 35 iPad Simulator тестов**, без failures/skips/runtime warnings.
Область: реальные CKRecord/CKAsset, cloud-off без entitlement/account, TLS,
persistence fence, live gesture presentation и один UI stroke. Исходники после
этого изменены финальным LAN ACK/dependency допуском, snapshot root set,
Mac provisioning guard, physical logical-address fix и тестами; прежняя квитанция не выдаётся за проверку этих
поздних изменений. После уведомления об обновлённом правиле основного AGENTS.md
дальнейшие проверки iPad выполняются только физически. Первый native build
нашёл существовавший в base неверный отступ multiline fixture; исправление
только пробелов зафиксировано отдельно: `a659e85`.

Финальный **физический iPad: 35/35 PASS**, 0 failures/skips/runtime warnings,
`.build/cloud-delivery-physical-20260917-r5/physical-proof.json`. Проверены
`NotebookCloudWireTests`, `NearbySyncTests`, `NotebookTransportSessionTests`,
`NotebookPersistenceFenceTests`, `NotebookLiveGesturePresentationTests`.
Включён TLS-сценарий: cloud checkpoint опережает LAN offer, ACK подтверждает
именно предложенную транзакцию и не закрывает исправную сессию.
Исходники до/после совпали с финальным Core source map.

Предыдущие physical r2/r3 дали 34 PASS и один отказ открытия тестовой тетради;
r4 уточнил `The file doesn’t exist.` до исполнения жеста. Причина —
`standardizedFileURL` по-разному разрешал существующий `/private/var` контейнер
и несуществующий JSON-путь SQLite. Из уже завершённого `3f30fb0` перенесены
**только** исправление `logicalAddress` и его регрессия, без graphics/schema/wire
изменений. Бесполезная попытка дополнительной инициализации fixture удалена.
Существующий DEBUG drawing fixture допущен к physical test build; его поведение
не менялось. Установлено только изолированное `.native-test`, CloudKit в нём
выключен. Это native XCTest с mounted presentation, **не** новая физическая
UI/Pencil или облачная приёмка рабочей пары.

Повторный профиль **100 000 независимых предметов PASS**, 419.882 s с подготовкой:
`/tmp/notebook-cloud-final-scale100k.log`, source map и команды в
`.build/cloud-delivery-final-core-proof.json`. На тех же addressed алгоритмах:

| Операция | BLOB-чтения / байты | SQLite время |
|---|---:|---:|
| Локальное перемещение | 24 / 7907 | 10.75 ms |
| Приём перемещения | 28 / 9596 | 28.05 ms |
| Локальный элемент | 25 / 10 050 | 7.94 ms |
| Приём элемента | 46 / 21 783 | 19.64 ms |
| Локальный заголовок | 38 / 14 001 | 15.86 ms |
| Приём заголовка | 37 / 16 270 | 26.71 ms |
| Повтор | 0 / 0 | 0.96 ms |

Объём чтения не вырос относительно 1000 предметов. Пик всего процесса с
построением фикстуры — 1 021 067 264 B; это не peak отдельного сохранения и не
доказательство снижения RAM приложения. Во время подготовки другой рабочий
процесс выполнял свою короткую Core-проверку: времена не являются изолированным
системным performance gate. Поздняя правка LAN и Cloud snapshot/profile не
меняла адресный алгоритм или этот fixture. Число вызовов JSONDecoder отдельно
не измерялось; trace считает SQL BLOB, а чужие тела исключены sentinel-тестом.

Попытка настоящей signed Release Mac-сборки в
`.build/cloud-signed-mac-20260917` остановилась **до компиляции**: Xcode сообщает
`No Accounts` и отсутствие Mac App Development profile для существующего
`com.amirtlinov.notebook.mac` с новыми правами. Ни helper, ни рабочая пара не
устанавливались этим запуском; обход строгой подписи не добавлен.

Внешняя граница: `cktool export-schema` не имеет management token. CloudKit
Console открыта и требует вход Apple; пароль/2FA у Амира в чат не запрашивались.
Существование контейнера, проверка/import/deploy `.ckdb` в Production и новые
profiles не подтверждены. Не выполнены реальный cloud-only обмен с раздельно
выключенными устройствами, настоящая квота/смена аккаунта, десять повторов,
30 минут совместной работы и системные кадры/CPU/GPU. Облачная доставка пока
не включалась. Контейнеры рабочей пары, их базы, идентичности и доверие сохранены;
чужие незавершённые графические изменения в этот worktree не включены.

## 17 сентября, 12:13 МСК — CloudKit Production и интеграция связей

С явным подтверждением Амира в команде `M94V58FCVP` создан контейнер
`iCloud.com.amirtlinov.notebook`. Два explicit App ID сохраняют идентичности
`com.amirtlinov.notebook.preview` и `com.amirtlinov.notebook.mac`; каждому
включены iCloud с CloudKit, Push и назначен ровно этот контейнер. Исходный
wildcard не менялся. Новые management tokens, ключи и пользователи не создавались.

CloudKit Console сначала показала пустые Development record types. Файл
`Applications/CloudKit/Notebook.ckdb` без ненужных public GRANT прошёл серверные
**Validation Passed** и import. Production diff содержал создание только
`NotebookBlob` и `NotebookDelivery`, ноль индексов и ноль изменений security
roles; после Deploy получено **Changes Deployed — The schema is deployed to
Production**. Системный `Users` не менялся. Reset, удаление данных и отправка
человеческого содержания не выполнялись. Наличие серверной schema не выдаётся
за проверку CKSyncEngine на паре.

В нашем изолированном worktree объединён законченный опубликованный `871e15a`
основной ветки, а не её незавершённые правки. Исходный checkout остался чистым
на том же commit. Объединённая версия использует SQLite admission 6 и wire 16;
конфликт wire-комментария разрешён без второго формата/пути применения.
Новый параметризованный cloud regression проверяет page и board: обратный
порядок initial snapshot, сохранение bindings, независимые `bend` и
`endArrowhead`, холодное открытие и последующий LAN duplicate без нового эффекта.

Объединённые исходники:
`ecd1b75ab472969a73588f1745b3cf2e8a3d052ee489d3b69debea0a9d65f253`.
**142 Core + 4 archive PASS**, 67.751 s / 0.793 s:
`.build/cloud-merged-core-20260917-proof.json`,
`/tmp/notebook-cloud-merged-core-20260917.log`. В этот повтор входит адресный
graphic admission среди 100 000 элементов: 96 допущенных, 7878 VM steps.
Это отдельная проверка допуска графики, не новое измерение времени облака.
**54 MCP + 70 release + 41 preview + 79 verification guards PASS**;
`.build/cloud-merged-guards-mcp-20260917-proof.json` сохраняет также первую
ошибочную команду preview с несуществующим путём. Правильный повтор
`Tests/PreviewInstaller/run.py` и его source map —
`.build/cloud-merged-preview-20260917-proof.json`.

Физическая повторная native-проверка: **51 iPad + 7 Mac PASS**, 0 failures,
skips и runtime warnings: `.build/cloud-merged-native-20260917/verification.json`.
Проверены cloud wire, TLS/ACK, очередь сохранения, live presentation, ввод,
bindings и рендеринг графики. Установлена только изолированная `.native-test`,
облако в ней недоступно. Native XCTest не считается Pencil/UI-приёмкой;
квитанция без названного UI-сценария не допускает выпуск изменённой фикстуры.

После сообщения Амира о добавлении аккаунта новый signed Mac probe
`.build/cloud-signed-mac-account-20260917` снова остановился **до компиляции**:
`No Accounts` и нет Mac App Development profile. CLI использует
`/Applications/Xcode.app`; на машине также установлен Xcode Beta, а сохранённый
список `IDE.Identifiers.Prod` пуст. Native UI Xcode недоступен из-за ошибки
захвата, поэтому состояние его окна не утверждается; запрошено уточнение.
Рабочая пара, её содержимое, доверие и идентичности не заменялись.

Отдельный physical UI запуск `.build/cloud-merged-ui-20260917/ipad.xcresult`
реально исполнил четыре сценария: **2 PASS / 2 FAIL**, без skips/runtime warnings.
`testBoundConnectorOnBoardFollowsTheNodeAndEditsItsBendAndLabel` и такой же
page-сценарий прошли: перемещение узла, связанная линия, правка изгиба/подписи,
сохранение живого соседнего WebKit и повторное открытие. Это не timeout
automation mode из прежних попыток основной задачи.

Плотная схема остановилась на первом перемещении: фактический dx=0 вместо 38.
Экспортированное видео показывает исходный узел и все 12 дополнительных узлов
со связями; synthesized event действительно послан из (271,417) в (309,443).
Причина пока не доказана: падение не объявляется ни дефектом CloudKit,
ни только ошибкой теста. Этот случай передан владельцу GUI-205. `Pen`-сценарий
остался на 80 действиях: XCTest отправляет direct contact, тогда как
`NotebookInputGate` на физическом устройстве намеренно не подменяет finger на
Pencil. Simulator-only режим не включался, production/input gate ради PASS не
ослаблялся. Этот сценарий не доказывает неисправность настоящего Pencil и не
считается его физической проверкой.

Сводка, дерево тестов, attachments и кадр перед dense drag сохранены в том же
каталоге. Успешной UI-квитанции и допуска рабочей пары нет. Реальный cloud-only
обмен, смена аккаунта/квота, системные измерения, десять повторов и 30 минут
совместной работы по-прежнему открыты; GUI-206/207 остаются In Progress.

## 17 сентября, 12:43 МСК — Xcode восстановлен, CloudKit profiles проверены

Амир подтвердил, что Xcode действительно был деавторизован, и восстановил
вход. Свежая CLI-проверка видит один аккаунт; новый Mac Release build в
`.build/cloud-signed-pair-account-restored-20260917` завершился
**BUILD SUCCEEDED**, ошибки `No Accounts` больше нет. Apple выдала explicit
Mac Team Provisioning Profile с нужным контейнером, Production/Development и
development Push. Первоначальный `inspect_mac` отклонил его из-за дефекта
нашего валидатора: `com.apple.developer.icloud-services` в реальном профиле
равен строке `*`, а не массиву. Это allowlist профиля, не entitlement сборки
([TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)).

Узкое исправление допускает эту форму **только** для services внутри profile.
Подпись по-прежнему обязана содержать ровно `CloudKit`; контейнер, окружения,
App ID/team, физическое устройство, срок, сертификат и права вложенных XPC
не ослаблены. До исправления новая регрессия воспроизвела отказ для обеих
платформ; после — **75 release + 41 preview PASS**. Проверяются также отказ
расширенным правам подписи, чужому/wildcard-контейнеру, неверному окружению и
отсутствующему разрешению сервиса.

Текущие исходники:
`ebf962416e84b75e4cd9560c355e16ae82b5c3d851d5f041de61ecb4d2f7a7ac`.
`.build/cloud-profile-wildcard-20260917/proof.json` связывает guard-тесты и
**полный реальный inspect_mac PASS** с этим валидатором. Mac bundle построен
предыдущим probe из `ecd1b75a…`, а не пересобран после изменения Python guard;
его manifest не менялся, Swift-исходники также не менялись. Проверены оба XPC,
вложенные TeX/image executables, профиль и сертификат.

Отдельный свежий physical-iPad Release build из `ebf96241…` и
**inspect_ipad PASS**:
`.build/cloud-signed-ipad-account-restored-20260917-r2/signing-probe.json`.
Source maps до/после совпали. В обеих реальных подписях — ровно
`iCloud.com.amirtlinov.notebook`, `CloudKit`, `Production`, development Push,
прежние идентичности; iPad сохраняет собственную Keychain-группу. Первый iPad
probe остановился до сборки по проверке занятого Xcode: диагностический скрипт
использовал буквальный `/tmp`, тогда как штатный lock находится в
`tempfile.gettempdir()`. Повтор использовал штатный путь; второго Xcode runner
одновременно не запускалось.

Эти probes проверяют **авторизацию, сборку и подпись**, но не создают release
admission и не заменяют физическую UI/Pencil или cloud-only приёмку. Рабочие
Mac/iPad приложения не устанавливались и не запускались, отправка тетради в
iCloud не включалась. Локальные базы, идентичности и доверие сохранены.
Сценарий раздельно выключенных устройств, квота/смена аккаунта и ранее
указанная полная физическая приёмка остаются открытыми; GUI-207 — In Progress.

## 17 сентября, 12:54 МСК — CloudKit и непрерывная публикация графики

В совместный worktree объединён законченный опубликованный `8911329` из
GUI-205, прямой потомок уже включённого `871e15a`. Незавершённые правки
исходного checkout не переносились. Автоматическое объединение сохранило
CloudKit/LAN-адаптеры одного writer и обе фактические записи журнала.

Ранее обнаруженный dense UI отказ был реальным разрывом представления:
после lift контакт удалял свой draft до асинхронной SQL-публикации. Теперь
принятый draft удерживает команда, пока сцена с cursor не ниже сохранённого
не примет каноническую геометрию. Старый SQL-срез, смена выделения, поздний
cancel и следующий Pencil не откатывают принятый результат; CAS rejection
снимает draft без перезаписи конкурентной геометрии. Правила конфликтов,
команд и Pencil gate не заменены, ожидания/координаты UI-тестов не ослаблены.

Совместные исходники:
`972f3451282b30bbfcb6fb0e4e2c23cc5875b264894ad069765a56566d5a32dd`.
Отдельный штатный `verify.sh --only` завершился **75 physical iPad + 7 Mac
PASS**, 0 failures/skips/runtime warnings, source maps до/после равны.
Квитанция: `.build/cloud-graphics-handoff-integrated-20260917/verification.json`;
точные селекторы сохранены в соседнем `selection.json`.

В 75 iPad входят 72 native и три реально выполненных UI-сценария:
bound connector на page, board и dense board. Дополнительно проверены
CloudWire, NearbySync, transport ACK, persistence fence, live scene и жесты.
Mac проверил CloudWire и рендеринг графики. Три финальных PNG из текущего
`ipad.xcresult` экспортированы и просмотрены: связанная изогнутая линия и
перемещённый узел остаются видимыми; соседний WebKit показывает `Count 1` и
`78seed`; dense screenshot содержит все N1–N12 и их линии. Это проверка
представления в изолированных физических тестовых bundles, не новые
измерения FPS/CPU/GPU или 100k алгоритма хранения.

Сбой dense устранён и подтверждён уже вместе с облачной реализацией. Однако
CloudKit entitlement в native-test не включён: реальная доставка через Apple,
обновление рабочей пары, ручной Pencil, квота/смена аккаунта, десять повторов
и 30 минут совместной работы этим проходом не подтверждаются. Человеческое
содержимое в iCloud не отправлялось. GUI-206/207 остаются In Progress.

## 17 сентября, 13:24 МСК — актуальный Release установлен на iPad

По прямому запросу Амира установлен и запущен **Notebook Lab 0.3.62 (65)**,
`com.amirtlinov.notebook.preview`, из commit `9a1488c` / source `972f3451…`.
Штатный `build_verified_pair` принял прежнюю неизменную integration-квитанцию
и выполнил полные проверки обеих настоящих Release-подписей. Установлен только
iPad; рабочий Mac этим действием не заменён. Свидетельства сборки, единственной
установки и запуска: `.build/cloud-ipad-install-20260917/`.

До установки devicectl показывал только `.native-test` и UI-test runner,
без `.preview` или прежнего canonical. После — точный новый bundle, версия
и installation URL; идентичность тестового приложения не изменилась. Нормальный
запуск без fixture-параметров подтверждён, повторное чтение показало тот же
PID/executable и созданную локальную `Notebook/notebook.sqlite` (544768 bytes).
До запуска в рабочем контейнере не было прежней тетради или activation:
это чистая установка, не восстановление человеческих данных из тестов/архивов.

CloudKit не включался, история и тестовые контейнеры не переносились и не
удалялись. Экран установленного Release напрямую не просмотрен: native
Device Hub недоступен через CUA (timeout). Установка/живой процесс и локальная
инициализация подтверждены отдельно от UI/Pencil и реального облачного обмена.

Экспортированные после integration-тестов PNG вынесены в соседний
`.build/cloud-graphics-handoff-integrated-20260917-attachments`: они не являются
файлами исходной запечатанной квитанции. Перед переносом проверены нулевые
missing/changed для всех её файлов; исходная `verification.json` не менялась
и после отделения производных изображений снова прошла строгую проверку.

## 17 сентября, 13:35 МСК — первый запуск и преждевременное чтение истории

После установки Амир сообщил постоянное «Предыдущая транзакция ещё
записывается». Предыдущая квитанция доказывала установку и процесс, **не
готовность интерфейса**. Обычный повторный запуск той же базы открыл доску;
Амир подтвердил это в 13:35. Данные, приложение, идентичности и доверие не
сбрасывались; исторические архивы не использовались. При диагностическом
запуске LLDB breakpoint в SQLite failure не сработал. Исходную гонку BUSY
повторно не захватили, поэтому её конкретный стек не установлен.

Найдено воспроизводимое нарушение порядка: смонтированный task истории мог
выполнить `CollaborationReadSnapshot` до регистрации startup writer.
`readTransaction` тогда сам создавал SQLite-схему рядом с инициализацией
пространства. Допуск `permitsBackgroundPreparation` теперь требует `.ready`.
Тот же переход меняет ключ task истории и допускает её чтение после загрузки;
новой очереди, retry-петли или увеличенного SQLite timeout нет.

На физическом iPad новая регрессия до исправления доказала создание базы
посторонним читателем: 1 FAIL / 5 PASS в
`.build/startup-readers-before-run-20260917`. Предварительная попытка в
`startup-readers-before-20260917` остановилась на исправленной ошибке аргумента
teardown в новом тесте и не исполняла тестов. После исправления source
`bc50f6b5…` прошёл 27 физических native-тестов без skips/runtime warnings:
`.build/startup-readers-fixed-20260917`. Включены mounted `NotebookRootView`
на новом изолированном root, запись перемещения и повторное открытие,
подготовка истории, persistence fences, live scene, защита Pencil и CloudWire.
Native launch-тесты отключают LAN; реальный CloudKit и полную физическую
приёмку этот выбранный проход не доказывает.

В 13:41 тот же source установлен поверх рабочего `com.amirtlinov.notebook.preview`
и запущен без fixture-аргументов (PID 1521). Строго проверенная Release-пара:
`.build/startup-fixed-release-20260917`; единственная установка обновления и
readback: `.build/startup-fixed-install-20260917`. Mac не установлен, облако
не включено. OS переместила data container из `34B54F80…` в `62110C5F…`:
первая проверка остановилась на изменившемся пути, следующая — на добавленной
атрибуции data-protection от `com.apple.containermanagerd`. До запуска отдельно
проверено совпадение всех девяти путей, размеров, modification time, владельцев,
permissions и resource flags. SQLite осталась 1855488 bytes, WAL — 0; менялась
только указанная OS-атрибуция четырёх файлов. Повторной установки, копии базы,
изменения xattrs или восстановления архива не было. `.native-test` не изменён.
Экран Device Hub снова недоступен через CUA. В 13:42 Амир отдельно подтвердил
для исправленной установленной сборки: прежняя доска видна без ошибки,
тетрадь открывается и можно писать — «Да, всё открывается и работает».
Это ручная проверка запуска/работы, не полная парная или CloudKit-приёмка.
## 17 сентября — многоштриховый QuickShape (GUI-205)

Физическое замечание Амира: стрелка не распознаётся даже непрерывно, круг
нестабилен, квадрат и плюс не распознаются. Старый классификатор требовал
строго пять вершин стрелки; square/plus не были самостоятельной геометрией.
Commit `503b668` заменяет этот путь ограниченной проверкой всех измеренных
точек, допускает разные порядки и до четырёх штрихов. Прямоугольник и плюс —
нативные графические типы. Смена страницы/инструмента, отмена, уход поверхности,
а на доске и смена камеры прерывают короткую последовательность. Протокол 17
требует обновления обоих устройств, ключи и локальные данные не меняются.

Выбранный проход `.build/quickshape-sequence-v3-20260917`, source
`47528e928e67d029ab180974782ce761056f47e10ed20816780290786b287ea2`:
23 Core-теста, 55 MCP, 23 native-теста на физическом iPad и 4 native-теста на
Mac PASS; skips/runtime warnings отсутствуют. Проверены порядок/направление
стрелок, зазор и перехлёст эллипса, square/plus, отрицательные L/T/V/треугольник,
масштабы, multi-source undo и конкурентное согласование, контуры и привязки.
Mounted-сценарии листа и доски проводят два контакта через обычный input gate,
дают публикации первого штриха завершиться и затем закрывают/повторно читают
базу. Все исходные измерения остаются неизменными.

Первый расширенный Core-тест остановился из-за ошибочной NaN-фикстуры:
`SpatialPoint` запрещает NaN уже в конструкторе. Тест заменён допустимым
отрицательным scale, production precondition не ослаблялся. Первый выбранный
проход остановился на устаревшем generated SDK; ресурс воспроизведён штатным
`MCP/build-script-services.mjs`. Второй проход нашёл настоящий дефект: 22 PASS /
1 FAIL на iPad — finisher обычной публикации обнулял историю после подъёма
Pencil. Исправлено разделение drain завершённого контакта и отмены/ухода
поверхности. Третий проход выполнил оба mounted multi-stroke сценария.

Снимок `native-rectangle-plus` из mac.xcresult экспортирован в отдельный
`.build/quickshape-images-20260917` и просмотрен: прямоугольный контур и
пересекающиеся линии плюса, не эллипсы. sealed-свидетельства не изменялись.
Контакты в native-тестах синтетические. ML не обучалась, личные наброски никуда
не отправлялись; качество на настоящем Pencil не выводится из этих тестов.
Полная парная/CloudKit-приёмка, десять повторов, системные измерения и 30 минут
совместной работы этим проходом не выполнялись.

Перед выпуском дождались параллельной задачи иконок. В объединение вошли
только завершённые `9f81b3d` и `f38416d`; чужой working tree не копировался.
Merge `b5b4708` сохраняет новую иконку с исправленными отступами. Полностью
повторён выбранный проход `.build/quickshape-integrated-20260917` на source
`8789c0f52a95c3f80aa6f1378016308876191ec6d40d5cc76ba323b06141af02`:
те же 23 Core / 55 MCP / 23 iPad / 4 Mac, плюс 79 verification и 75 release
проверок маршрута PASS. Runtime warnings/skips нет. Полный `--full` не запускался.

В 14:24 МСК подписанная **Notebook Lab 0.3.63 (66)** установлена одной in-place
операцией на физический iPad и запущена без fixture-аргументов, PID 1583.
Строго проверенная подписанная пара: `.build/quickshape-release-20260917`;
установка/readback: `.build/quickshape-install-20260917/operation.json`.
Девять относительных путей Notebook и вся возвращённая метаинформация
побайтно совпали до/после установки до запуска; OS сменила путь data container
`3213F7EE…` → `1301749F…`. Данные не удалялись, не копировались и не
восстанавливались. Отдельный `.native-test` неизменен. CloudKit этой операцией
не включался. Mac-пара собрана, но здесь ещё не устанавливалась: вопрос об
обновлении второго устройства оставлен Амиру; действующий помощник остаётся
на протоколе 16, новые фигуры требуют пары версии 17. Рабочий LAN/CloudKit этой
установкой не объявлен проверенным.

Амиру отправлен запрос проверки настоящим Pencil: круг, квадрат, плюс,
одно-/многоштриховая стрелка с удержанием в конце последнего штриха.
На момент этой записи ответа ещё нет. Синтетический PASS не заменяет эту
калибровку; GUI-205 остаётся In Progress.


## 17 сентября — задержка QuickShape при оставленной ладони (GUI-205)

Амир подтвердил улучшение распознавания в 0.3.63 (66), но обнаружил долгое
превращение после подъёма Pencil. Уточнение на настоящем устройстве: после
подъёма всей руки фигура появляется сразу. В синтетическом воспроизведении
`NotebookContactObserver` продолжал держать input barrier за scene-палец,
чей жест уже отменён началом Pencil. Это объясняет найденный тестовый случай,
но ещё не устанавливает причину задержки настоящего контакта.

Исправление оставляет один существующий путь команды и записи. Наблюдатель
хранит для контакта активность `scene / restingHand / independent`; только
пересёкшийся с Pencil scene-палец перестаёт задерживать idle после Pencil-up.
Его идентичность остаётся до физического lift/cancel. Сохраняются независимый
native input, оконный Pencil-up, новый пальцевый жест и перенос между gate.
Предпросмотр, SQL, конфликтные правила, undo, MCP и облако здесь не меняются.

На физическом iPad `00008103-001E059934D9001E`, iPadOS 27.0 (24A435):

- `.build/quickshape-latency-baseline-20260917`: 2 PASS на пустом пространстве
  без оставшейся руки; публикация модели страницы 172 мс, когорты доски 333 мс.
  Это показало, что один лишь тест без остальных оконных контактов не
  воспроизводит жалобу.
- `.build/quickshape-hand-baseline-20260917`: 2 FAIL, ожидаемые регрессии до
  исправления. При оставшемся пальце за 3 с не наступают ни idle, ни
  преобразование. После подъёма пальца shutdown сохраняет исходные точки и
  фигуру. PASS-квитанция для этого прохода не создавалась.
- `.build/quickshape-hand-fix-v1-20260917`: 32 PASS предварительной проверки.
- `.build/quickshape-latency-final-20260917`: 67/67 native PASS, ноль skips и
  runtime warnings. Source
  `09d735983c06ec0f68ad5e45aae049a47d19ec5467bc301395d7edf8a9a8d418`.
  Проверены QuickShape input/scene/model, finger ownership, ввод/камера и
  native-control regions. Core/MCP/Mac native не повторялись: их поведение
  этим срезом не менялось. Полный `--full` не запускался.

Контрольные точки финального Debug-прохода после Pencil-up, мс:

| Поверхность | Рука остаётся | Idle | Модель | Когорта доски |
| --- | --- | ---: | ---: | ---: |
| Доска | да | 11 | 200 | 260 |
| Доска | нет | 11 | 211 | 266 |
| Лист | да | 26 | 171 | — |
| Лист | нет | 26 | 180 | — |

Измерение ограничено пустым тестовым пространством и синтетическими
UIKit-контактами на физическом устройстве. `paintMS` в attachment означает
наличие фигуры в опубликованной модели/индексе когорты, а не системное время
показа пикселей или FPS. Времена не выдаются за p95, десять повторов или
Release-измерение на человеческой тетради. Три секунды baseline — предел
наблюдения теста, а не встроенная задержка: барьер ожидал сам контакт.
Рабочая приёмка исправленной Release-сборки настоящим Pencil остаётся отдельной.


В 15:22 МСК проверенная **Notebook Lab 0.3.64 (67)** установлена in-place на
рабочий iPad и запущена без fixture-аргументов. Строгая signed-pair сборка:
`.build/quickshape-latency-release-20260917/build.json` (`verified-build`),
тот же source `09d73598…`. Установка и последующее подтверждение процесса
1717: `.build/quickshape-latency-install-20260917/operation.json` и
`process-readback.json`. Девять относительных путей Notebook сохранились;
метаданные SQLite, WAL и SHM до запуска совпали. Изменился лишь runtime-файл
`input-frames.json` при завершении прежнего приложения. OS переместила data
container `1301749F…` → `9A0D90FC…`; это не удаление базы. Отдельный native-test
не изменён установкой. Базы не копировались/не восстанавливались, pairing и
CloudKit-настройки не менялись. Mac собран, но этой операцией не обновлялся.
В 15:24 МСК Амир проверил тот же Pencil-жест с оставленной на экране ладонью
и ответил: «Нет, всё ещё ждёт». **Физическая приёмка 0.3.64 (67) не пройдена;
пользовательский дефект не исправлен.** Синтетические 67 PASS подтверждают
только перечисленные проверки. В частности, тест оставленной руки подставлял
корневой UIView вместо настоящего hit-test адресата и не воспроизводил весь
UIKit-маршрут пальца. Нужна диагностика фактического владельца активности,
а не ослабление барьера записи или объявление этих тестов приёмкой.

При следующей диагностике около 15:25 МСК CoreDevice перестал возвращать
рабочее `.preview` и отдельное `.native-test` среди установленных приложений.
Сверены UDID и проводное подключение; повторный запрос с `--include-all-apps`
и запуск `.preview` вернули соответственно отсутствие записи и ошибку
«application ... is not installed». В 15:33 повторный read-only запрос вновь
не нашёл `.preview`. Это наблюдение API, не установленная причина исчезновения
и не доказательство удаления человеческих данных. Амиру отправлено уточнение;
до него повторная установка рабочего приложения не выполняется. Никакого
uninstall, копирования базы или восстановления архива здесь не было.
GUI-205 остаётся In Progress; полная парная приёмка не заявлена.

В 15:35 МСК Амир подтвердил, что сам удалил приложение, и попросил не
накапливать старые версии. В 15:37 удалён оставшийся тестовый
`com.amirtlinov.notebook.uitests.xctrunner`; `.native-test` уже отсутствовал.
Повторно установлена и запущена та же проверенная 0.3.64 (67), PID 1745,
**для диагностики, а не как новое исправление**. Readback полного списка
подтвердил ровно один Notebook bundle — `com.amirtlinov.notebook.preview`.
Квитанция: `.build/quickshape-diagnostic-reinstall-20260917/operation.json`.
Удаление рабочего приложения этим запуском не выполнялось; архивы не
восстанавливались, базы не копировались, CloudKit не включался, Mac не
обновлялся. Следующие рабочие обновления остаются in-place; временные
test/runner удаляются по окончании проверки, а не остаются рядом с Lab.

## GUI-205 — владельцы Pencil и перехода камеры, 17 сентября 2026

После отрицательной физической приёмки 67 Амир также сообщил о нестабильном
вводе, похожем на промежуточное состояние между доской и тетрадью. Найден
отдельный воспроизводимый дефект: `notifyAcceptedContact` безусловно вызывал
остановку камеры даже без запроса навигации. Новая модельная регрессия получила
1 вызов stop вместо 0 (`.build/quickshape-routing-baseline-20260917`, 2 PASS,
1 FAIL). Mounted-проверка затем прошла настоящую иерархию приложения:
двойной tap в `NotebookInteractionTouchView`, реальный `SceneCameraSettlement`,
новый scene-палец во время открытия. До правки тетрадь оставалась `.cover`
вместо `.page`: `.build/opening-contact-baseline-20260917/ipad.xcresult`, FAIL.
Это синтетические UIKit-контакты на физическом iPad, не жест Амира.

Переход теперь принадлежит запускающему его navigation ID. Отмена pending
reference/return останавливает только его камеру, не обычное открытие и не
чужую человеческую анимацию, которую ссылка ещё ожидает. `completeShow`
вызывается после посадки камеры, а прерывание settlement очищает его блокировку
content input. Промежуточный прогон GraphicScene + ReferenceNavigation дал
24/24 PASS, включая прерывание собственного reference-перехода и сохранение
человеческого открытия при отмене ожидающей ссылки.

Также удалён второй Pencil-владелец из `NotebookContactObserver`: он и его
UIKit delegate принимают только `.direct`; барьер Pencil завершает обработчик
измеренных чернил. Тест прежнего двойного барьера заменён проверкой одного
владельца, с оставленной scene-ладонью и без необходимости оконного Pencil-up.
Независимый нативный контрол всё ещё удерживает свой контакт; `requireIdleInput`,
правила записи и публичные предусловия не ослаблены. В mounted-тесте ладонь
теперь выбирает настоящий `window.hitTest`, а не корневой UIView.

Окончательный выборочный прогон для 0.3.65 (68):
`.build/pencil-camera-owners-final-20260917/verification.json`, **90/90 PASS**,
0 skips/runtime warnings, только физический iPad
`00008103-001E059934D9001E`, iPadOS 27.0 (24A435). Suites: GraphicScene,
GraphicInput, ReferenceNavigation, CoverOpeningPhysics, SceneFingerOwnership,
NotebookInput, ControlRegion. Source SHA-256:
`68ef54b8fe8bb530fc19605f24b942fde5775870eeaa3fb03146f1e855b1e4f3`.
Строгая подписанная сборка iPad + Mac с тем же source:
`.build/pencil-camera-owners-release-20260917/build.json`, `verified-build`.
Симулятор не использовался. Источник ожидания реальной ладони на 67 до конца
не прослежен: LLDB-диагностика не дала полного Pencil-сценария и была отключена.
Поэтому эти результаты не объявляют исходную физическую задержку QuickShape
исправленной; GUI-205 остаётся In Progress до проверки установленной версии.

В 16:27 МСК **Notebook Lab 0.3.65 (68)** установлена in-place и запущена
без fixture-аргументов, PID 1892 подтверждён отдельным process readback.
`.build/pencil-camera-owners-install-20260917/operation.json` связывает
установку с точным подписанным manifest и тем же source hash. Перед установкой
удалено только `com.amirtlinov.notebook.native-test`; test runner уже отсутствовал.
Полный inventory после установки содержит ровно один Notebook — `.preview` 68.
Девять путей рабочего Notebook сохранены; метаданные SQLite/WAL/SHM и
`runtime/input-frames.json` изменились во время обновления запущенного приложения,
поэтому идентичность байтов базы не заявляется. База не копировалась,
не удалялась и не восстанавливалась; рабочий bundle не uninstall-ился,
CloudKit не включался, Mac не обновлялся. Отладчик не подключён.
Амиру отправлена проверка открытия/стабильности штрихов и QuickShape при
оставленной ладони. Ответ на эту версию ещё не получен; физическая приёмка,
системные ресурсные измерения, десять повторов и 30 минут пары не заявлены.

## 17 сентября 2026 — GUI-209: размер окна и физический лист

Амир сообщил о горизонтально обрезанной тетради после возвращения на лист;
область Pencil оставалась внутри неправильных границ. На исходном коде 68
новый физический UI-сценарий выполнил 20 перелистываний (10 туда-обратно)
без изменения `paper-input.frame` и `page-turn-surface.frame`:
`.build/page-curl-geometry-baseline-20260917`. Снимок последнего возврата
визуально проверен: канонический лист занимает portrait-окно целиком.
Четыре поворота между portrait/landscape с восемью перелистываниями также
прошли на исходном коде: `.build/paper-rotation-baseline-retry-20260917`.
Первая попытка этого второго сценария отказала до запуска runner с сообщением
о доверии подписи; отдельный launch runner затем прошёл, повтор не менял исходники.
Эти фикстуры с правильным размером не воспроизводят пользовательский дефект.

Отдельная регрессия `NotebookPaperGeometryTests` воспроизвела ошибку холодного
запуска: `NotebookRootView` в окне 1194×834 создавал и сохранял лист 1194×834,
несмотря на физическую рамку тетради 834×1194. Следующий лист наследовал размер
стартового окна. Исходный FAIL сохранён в
`.build/paper-geometry-baseline-20260917/ipad.xcresult`; после разведения
`pageSize` и `viewport` узкая регрессия прошла в
`.build/paper-geometry-fix-probe-20260917`. Размер существующих страниц и
координаты содержания этим изменением не переписываются.

Расширенный выбранный прогон обнаружил старую ошибку фикстуры
`PagePresentationTests.testVisibleProgramRegionComesFromThePhysicalClipAfterTheNativeCameraTransaction`:
она не запускала модель, поэтому `permitsBackgroundPreparation` правильно
отказывал. Исправлена фикстура: обычный `start`, ожидание реального callback
вместо двух `Task.yield`; производственный запрет чтения до запуска не ослаблен.
Промежуточные FAIL: `paper-geometry-fix-checked-20260917` и `checked2`.
Они не считаются PASS и не используются для выпуска.

Окончательная проверка этого среза: **36/36 PASS**, 0 skips/runtime warnings,
`.build/paper-geometry-fix-checked3-20260917/verification.json`. Только физический
`00008103-001E059934D9001E`, iPadOS 27.0 (24A435), без Simulator. Выбраны
NotebookPaperGeometry, PagePresentation, PageTurnSelection, PresenceOwnership
и UI-повороты с перелистыванием. Source SHA-256:
`3cd2e37c767aee199cb01d136983b4547ad7cb3a83da7d2af97e0d43eee85667`.
Строгая подписанная сборка пары с тем же source:
`.build/paper-geometry-probe-release-20260917/build.json`, `verified-build`.

В 17:27 МСК **0.3.66 (69)** установлена поверх рабочего `.preview` и запущена
обычно, PID 2002 подтверждён отдельно. Квитанция:
`.build/paper-geometry-probe-install-20260917/operation.json`. Все девять путей
тетради сохранены; из метаданных путей изменился только `runtime/input-frames.json`.
Это проверка путей/метаданных, не побайтовая копия базы. Рабочий bundle не
удалялся, SQLite не копировалась, архивы не восстанавливались. Удалены только
`com.amirtlinov.notebook.native-test` и `com.amirtlinov.notebook.uitests.xctrunner`;
полный inventory показывает ровно один Notebook — Lab 69. Mac не установлен,
CloudKit не включался. Минимальное наблюдение `PaperGeometry` пишет только
числовой размер монтируемого листа, без содержания/идентификаторов страниц.

Граница результата: конкретная ошибка создания листа подтверждена и исправлена,
но размеры именно прежней пользовательской страницы не получены. LLDB дважды
завис в host attach; оба процесса отладчика остановлены, рабочий iPad-процесс
возобновлён. `log collect` отказал без root, noninteractive sudo — без пароля;
пароли не запрашивались. Console UI недоступен из-за ошибки ScreenCaptureKit.
Эти ограничения не обойдены копированием живой базы. Амиру отправлен вопрос
о прежней тетради на 69; GUI-209 остаётся In Progress до физического ответа.
Нормализация прежних неизменяемых размеров страниц, полный приёмочный цикл,
замеры CPU/GPU/памяти, десять финальных повторов и 30 минут пары не заявлены.


## 17 сентября 2026 — GUI-209: исправление уже сохранённого неверного листа

Ответ Амира после установки 69 и новый скриншот подтверждают: прежний рабочий
лист всё ещё ограничивает чернила горизонтальной полосой. Это **FAIL физической
приёмки 69 для прежней страницы**, не отменённый успехом канонической UI-фикстуры.
Получение OSLog через `devicectl process launch --console` с
`OS_ACTIVITY_DT_MODE=YES` впервые дало размеры живых владельцев:
**1194×834** у первого листа и **834×1194** у второго. Две сетки с разным
шагом на скриншоте соответствуют вписыванию первого листа в вертикальную
тетрадь. Исправление запуска в 69 предотвращало новые неверные листы, но не
меняло неизменяемую геометрию уже сохранённого содержания.

Амир явно разрешил удалить тестовые штрихи **только этого неверного листа**.
В 18:18–18:19 МСК выполнена разовая замена первого листа новым чистым 834×1194
в той же тетради и на том же месте. Служебная сборка 0.3.67 (70) прошла
строгий выпускной маршрут; действие исполнялось в обычном запуске допущенного
`.preview`, внутри `NotebookPersistenceQueue` / `NotebookStore`, одной
SQLite-транзакцией. Перед записью проверены точные workspace/notebook/page ID,
корень порядка, SHA-256 содержания, неверный размер и правильный соседний лист.
Чужой либо изменившийся лист отклоняется до записи. Новый UUID не ослабляет
неизменяемость размера существующей страницы. Удалены 10 тестовых ink-actions
и одна распознанная фигура, не тетрадь и не соседний лист.

До/после/после отдельного перезапуска:
`.build/paper-replacement-service-install-20260917/replacement.json` и
`authorized-replacement-{before,commit,reopened}.log`. Workspace и notebook ID
сохранены; порядок по-прежнему содержит ровно два листа; соседний лист сохранил
ID и SHA-256 `a37e908d16a60874903b8f926541ba5540758641440e449243085f0f9e4a56b5`.
Новый первый лист пуст; оба владельца после перезапуска монтируются как
834×1194. Таймаут console-команды через 15 секунд ограничивает наблюдение,
не означает падение приложения; результат проверен отдельным запуском/readback.
База не копировалась, архивы не восстанавливались, локальные идентичности и
доверие пары не сбрасывались; Mac и настройки облака не менялись.

Разовая реализация и её вход полностью удалены из рабочих исходников после
подтверждения записи. Они остались только в неизменном source-снимке служебной
проверенной сборки, не в итоговом приложении и не как автоматическая миграция.
Свидетельства служебного среза: `paper-replacement-check2-20260917` и
`paper-replacement-service-build-20260917` внутри `.build`; source SHA-256
`a83bb91147e90ad49ffda2e780ffc35fefc4cd3a0285521e68d0654a0945fbf0`.
Core: три теста, включая пять вариантов неверного/stale адреса, сохранность
соседа, повтор и rollback до commit; всё PASS. Native/UI: 3/3 PASS на физическом
iPad, без skips/runtime warnings. Первая служебная проверка остановилась на
неподготовленном presence тестовой фикстуры; исправлена фикстура, не ослаблена
проверка владельца записи. Эта неудачная попытка не является допуском.

Постоянное изменение минимально: пустой следующий лист и заглушка загрузки
больше не наследуют размер первой старой страницы. Они используют
`NotebookAppModel.notebookPageSize` — тот же размер, которым владеет создание
и сохранение новых листов. Старый обход к первой странице удалён. Регрессия
начинает с сохранённого 1194×834 и доказывает, что следующий лист использует
834×1194, а запуск самовольно не меняет прежнее содержание.

Финальные неизменные исходники 0.3.68 (71) проверены отдельно, уже без разового
кода: `.build/paper-geometry-final-check-20260917/verification.json`,
source SHA-256 `b1626363f1a15af113370df7795054ccae0b2c33a9c8938e6a899f39c13b80fe`.
**4/4 PASS**, 0 skips/runtime warnings: две native-регрессии и два настоящих
UI-сценария на физическом iPad `00008103-001E059934D9001E`, iPadOS 27.0 (24A435).
Двадцать последовательных свайпов (10 туда-обратно), затем ещё восемь свайпов
при четырёх сменах ориентации сохранили границы реального `paper-input` и
исходное число чернильных действий. Screenshot после двадцатого свайпа и
финального возврата в portrait осмотрены: линии канонической фикстуры проходят
по всей высоте листа, без центральной горизонтальной отсечки и второго шага
сетки. Экспортированные изображения и manifest лежат отдельно от неизменной
квитанции: `.build/paper-geometry-final-visual-20260917`.

Это проверка физической UI-фикстуры, не утверждение о новых Pencil-штрихах
Амира в рабочей тетради. Полный приёмочный цикл, системные кадры/CPU/GPU/память,
30 минут пары и прежний отдельный сценарий QuickShape с ладонью в этом срезе
не подтверждены. GUI-209 остаётся открытой до проверки рабочей страницы Амиром.

В 18:24 МСК итоговая **0.3.68 (71)** установлена поверх `.preview` после
`verified-build` в `.build/paper-geometry-final-release-20260917/build.json`.
Квитанция установки — `.build/paper-geometry-final-install-20260917/operation.json`.
Сохранены все девять путей данных; после самого обновления менялись только
метаданные `runtime/input-frames.json`. Удалены обе тестовые установки:
`.native-test` и `.uitests.xctrunner`. Полный inventory подтверждает ровно один
Notebook — Lab 71; служебная 70 заменена, рабочее приложение не удалялось.
Обычный финальный запуск **без служебного входа** снова смонтировал два 834×1194;
процесс PID 2074 подтверждён отдельным readback. Журналы
`normal-restart-{console.log,processes.json,readback.json}` находятся в каталоге
установки. Амиру отправлен запрос проверить длинный Pencil-штрих сверху донизу
и перелистывание в его рабочей тетради; ответ пока не получен.

**18:26 МСК — физическая приёмка GUI-209 подтверждена Амиром.** На вопрос о
Pencil-штрихе сверху донизу и перелистывании туда-обратно в установленной
0.3.68 (71) ответ: «Да, теперь всё правильно». Это подтверждает устранение
горизонтальной отсечки в настоящей рабочей тетради, не только в тестовой
фикстуре. GUI-209 можно закрыть; отдельная задержка QuickShape с ладонью и
полная приёмка совместной работы устройств этим ответом не закрываются.

## 17 сентября 2026 — GUI-205: фигура удержания остаётся тем же объектом после lift

Амир сообщил новый конкретный дефект: ровная фигура видна при удержании,
на подъёме Pencil исчезает, возвращается измеренный набросок, затем через
0,5–1 секунду снова появляется фигура. Уточнённое требование: результат
удержания уже является фигурой, а не отдельной предварительной картинкой.
В прежнем коде `finish()` снимал CAShapeLayer до асинхронной подготовки,
записи и публикации; сохранение создавало элемент с новым UUID. Это давало
два владельца показа и явный разрыв между ними.

Теперь `NotebookAppModel` владеет `NotebookWorkingGraphic` с ID Pencil-контакта
с момента распознавания. Его рисует обычный нативный графический путь листа
или доски, а SQLite принимает те же ID, геометрию, стиль и исходники. Lift
не снимает объект и не возвращает активный raw mesh. Отдельные CAShapeLayer,
previewPath и расчёт второго layout-графа с временным UUID удалены. Маска
листа скрывает принятые исходные чернила до асинхронной подготовки; позднее
уточнение силы не возвращает набросок поверх фигуры. Следующая фигура встаёт
в ту же очередь команд, а не теряется из-за предыдущей записи. Порог
намеренного удержания **500 мс не изменён**; новые правила конфликтов,
отмены, MCP или отдельный владелец SQLite не вводились.

Расширенная регрессия выявила ещё одну гонку: позднее перемещение могло
продвинуть cursor создания и вернуть старую геометрию ожидающего объекта.
Теперь этот cursor назначается только `convertInkToElement`, не последующим
правкам. Проверены перенос, причинная отмена, агентская правка, две подряд
принятые фигуры и немедленный shutdown/cold reopen.

Итоговые неизменные исходники **0.3.69 (72)**:
`7cc93dc2bc59e15cb18d1eccc843000acca66189d9055446b47f18f8921d9f5e`.
Выборочная квитанция `.build/quickshape-identity-final-20260917/verification.json`
имеет `passed`, маршрут `./verify.sh:selected`, explicit-only. **10/10 Core и
92/92 native PASS**, 0 skips/runtime warnings. Native-сценарии исполнялись на
физическом `00008103-001E059934D9001E`, iPadOS 27.0 (24A435), без Simulator:
NotebookGraphicScene/Input/Model, AcceptedPageInput, NotebookInput,
NotebookLiveScenePublication, InstalledInkAttention.

Новая проверка листа и доски монтирует настоящий `NotebookRootView`, проводит
синтетический Pencil-контакт через оконный recognizer и намеренно задерживает
публикацию. За 30 выборок с интервалом 20 мс после подъёма тот же объект
сохраняет ID/геометрию; поздняя отмена старого контакта его не удаляет. PNG
при удержании и после lift до commit совпадают побайтово на каждой поверхности.
Экспортированные свидетельства отдельно от неизменной квитанции:
`.build/quickshape-identity-final-visual-20260917/hold-lift-comparison.json`.
SHA-256 пары доски `1b24e22b01036722f2063328aa0897c098fbef20b8c95481080fbf4bf075aa85`,
пары листа `1ab38d0881af922cb7b90b2953d57a904119e7dd74f1f9e38c479f3cda7332d3`.
Это доказательство стабильности модели и двух снимков физической фикстуры,
**не покадровое измерение GPU и не жест настоящего Apple Pencil**.

Строгая подписанная сборка пары с тем же source —
`.build/quickshape-identity-final-release-20260917/build.json`, `verified-build`.
В 19:08 МСК 72 установлена **поверх** рабочей `.preview` и открыта; PID 2166
подтверждён отдельным readback. Квитанция:
`.build/quickshape-identity-install-20260917/operation.json`.
Все девять путей данных сохранены; изменились только метаданные
`runtime/input-frames.json`. Это проверка путей/метаданных, не копия базы.
Удалена тестовая `.native-test`; полный inventory содержит ровно один
Notebook — Lab 72. Рабочее приложение не удалялось, SQLite не копировалась,
архивы не восстанавливались; Mac и настройки CloudKit не менялись.

Амиру предложено проверить удержание и подъём только Pencil с оставленной
ладонью. Ответ для 72 пока не получен; GUI-205 остаётся In Progress.
Полная приёмка, системные кадры/CPU/GPU/память, десять физических повторов и
30 минут совместной работы не заявляются. Промежуточный
`quickshape-identity-checked-20260917` (91/92) и прерванная ранняя сборка
`quickshape-identity-release-20260917` не использованы для установки; финальный
допуск получен заново после исправления гонки и удаления старого layout-пути.

**19:36 МСК — обратная связь Амира на установленную 72:** «стало значительно
лучше работать». Это подтверждает заметное улучшение настоящего Pencil-сценария,
но не является утверждением об отсутствии любого мигания или полной приёмкой.
Оставшееся замечание — неинтуитивное изменение формы при продолжающемся
удержании — проверяется отдельно. GUI-205 остаётся In Progress.

## 17 сентября 2026 — GUI-205: изменение формы от места удержания Pencil

Исправлен геометрический путь `NotebookQuickShapeSession.move`. Прежняя формула
всегда прибавляла `2×dx` к ширине и `2×dy` к высоте относительно центра:
удержание слева/сверху не учитывалось, поэтому движение наружу могло уменьшать
фигуру. Новый путь выбирает ближайший край/угол по месту удержания; выбранный
край перемещается на расстояние Pencil, противоположный фиксирован. У середины
края поперечное движение не меняет другую размерность. Выбор не перескакивает
во время контакта, минимум 12 экранных точек не допускает переворота. У стрелки
движется ближайший конец, а не всегда наконечник. Нулевой сдвиг возвращает
точно исходную геометрию. Старое вычисление удалено; распознаватель, порог
удержания, стабильный объект hold/lift, запись и правила конфликтов не менялись.

Проверка **0.3.70 (73)**: source SHA-256
`5f2acb3bd850cd49773c973ef9dc122486abbe197bd14de02157f5ac135705b0`,
`.build/quickshape-hold-control-checked-20260917/verification.json`, `passed`,
`./verify.sh:selected`, explicit-only. **8/8 Core и 31/31 native PASS**,
0 skips/runtime warnings; физический iPad `00008103-001E059934D9001E`,
iPadOS 27.0 (24A435), без Simulator. Native-наборы — NotebookGraphicInputTests
и NotebookGraphicSceneTests. Проверены четыре стороны для эллипса, прямоугольника
и плюса при трёх масштабах, четыре угла, минимум/возврат, оба конца стрелки,
неизменность измеренных чернил. Сценарии установленной сцены на листе и доске
проводят синтетический контакт через реальный оконный recognizer: движение
левого края на 30 экранных точек влево расширяет фигуру только влево; высота
и правый край сохраняются. После lift и cold reopen сохраняются тот же объект
и изменённая геометрия, а не исходный fit.

Публикация намеренно задерживается на 600 мс. PNG изменённой фигуры во время
удержания и после lift до commit совпадают побайтово на обеих поверхностях.
Осмотренные изображения показывают расширение влево без сдвига правого края.
Экспорт и сравнение находятся отдельно от неизменной квитанции:
`.build/quickshape-hold-control-visual-20260917/hold-drag-lift-comparison.json`.
Это снимки и синтетический контакт на физическом устройстве, не подтверждение
удобства настоящим Pencil и не системное измерение кадров.

Первая попытка `quickshape-hold-control-20260917` — 29/31, не допуск выпуска.
Она выявила округление координат на нулевом сдвиге и прежнюю гонку тестовой
фикстуры: после выбора соединителя тест немедленно требовал drag до обычного
допуска живого владельца. Нулевой сдвиг больше не пересчитывается; фикстура
ожидает фактический `presentedElement`, а не фиксированную задержку и не
ослабление рабочего запрета невидимой манипуляции. Окончательный прогон прошёл
заново на неизменных исходниках. Полная приёмка, десять настоящих Pencil-повторов,
системные кадры/CPU/GPU/память и 30 минут пары этим срезом не заявляются.

В 19:48 МСК подписанная **0.3.70 (73)** установлена поверх рабочей `.preview`
и открыта, PID **2223** подтверждён отдельным readback. Строгая сборка пары:
`.build/quickshape-hold-control-release-20260917/build.json`, `verified-build`,
тот же source. Установка:
`.build/quickshape-hold-control-install-20260917/operation.json`.
Все девять путей данных сохранены; отличаются лишь метаданные
`runtime/input-frames.json`. Рабочий bundle не удалялся, SQLite не копировалась,
архивы не восстанавливались. `.native-test` удалена, полный inventory содержит
только Notebook Lab 73. Mac и CloudKit не менялись. Амиру отправлена проверка
настоящим Pencil: закончить круг/квадрат слева или сверху, удержать и потянуть
наружу. Ответ пока не получен; удобство нового жеста остаётся открытым.

## 17 сентября 2026 — GUI-205: обе оси на протяжении одного удержания

В 20:15 МСК Амир сообщил о 73: «лучше, но иногда почему-то фигуру можно только
по одной оси изменять». Это физически выявленное ошибочное UX-ограничение
предыдущего среза: рядом с серединой края код намеренно выключал вторую
размерность. Блокировка оси и её геометрические пороги удалены из
`NotebookQuickShapeSession`. Место удержания по-прежнему задаёт движущиеся
стороны, но обе размерности доступны весь контакт, включая смену направления
без отрыва. Противоположные стороны, минимальный размер, единый объект при
hold/lift и обычный путь записи сохранены. Другой recognizer/режим не добавлен.

Итоговые исходники **0.3.71 (74)**:
`229a64f0cdd7fb79f5d819eb260f4e69ca95e2844330a518b6249800522d42d6`.
Квитанция `.build/quickshape-free-axes-20260917/verification.json`: `passed`,
`./verify.sh:selected`, explicit-only. **8/8 Core и 31/31 native PASS**, без
skips/runtime warnings, физический iPad `00008103-001E059934D9001E`, iPadOS 27.0
(24A435), без Simulator. Проверки прежнего ограничения заменены регрессиями
свободных обеих размерностей для четырёх сторон, трёх типов фигур и масштабов.
В смонтированной сцене листа и доски один синтетический Pencil-контакт сначала
тянет левую сторону на 30 экранных точек, затем нижнюю на 20, не отпуская Pencil.
Обе правки приняты; движение по второй оси не отменяет первую. После подъёма
и cold reopen сохраняются тот же ID, оба размера и исходные измерения.

При намеренной задержке публикации на 600 мс снимки изменённого объекта во
время удержания и после lift до commit побайтово одинаковы на каждой
поверхности. Экспорт/сравнение отдельно от неизменной квитанции:
`.build/quickshape-free-axes-visual-20260917/hold-drag-lift-comparison.json`.
Финальные изображения осмотрены: фигура расширена влево и вниз, противоположные
стороны не сдвинуты. Это синтетический контакт через настоящий UIKit-владелец,
не физическая приёмка новым Apple Pencil-жестом. Системные кадры/CPU/GPU/память,
десять настоящих повторов и 30 минут пары не заявляются.

В 20:22 МСК **0.3.71 (74)** установлена поверх рабочей `.preview` и открыта,
PID **2263** подтверждён отдельным readback. Строгая подписанная сборка пары:
`.build/quickshape-free-axes-release-20260917/build.json`, `verified-build`,
тот же source. Установка:
`.build/quickshape-free-axes-install-20260917/operation.json`.
Все девять путей данных сохранены; изменились лишь метаданные
`runtime/input-frames.json`. `.native-test` удалена, inventory содержит ровно
один Notebook — Lab 74. Рабочий bundle не удалялся, SQLite не копировалась,
архивы не восстанавливались; Mac/CloudKit не менялись. Амиру предложено без
отрыва Pencil сменить горизонтальное изменение на вертикальное. Ответ пока
не получен; GUI-205 остаётся In Progress до физического подтверждения.

## 17 сентября 2026 — GUI-205: частичный ластик для нативных элементов

Амир уточнил, что ластик должен стирать часть фигуры, а не удалять объект
целиком. Прежний ластик менял только слой обычных чернил; нативная геометрия
рисовалась отдельно. Теперь тот же измеренный eraser-action содержит targets
затронутых элементов и их установленную локальную рамку. Общий рендер вычитает
его измеренные полосы; ID, исходная геометрия, редактируемость и единая отмена
сохранены. Отдельной команды удаления/растрирования фигуры нет. Вырез движется
и масштабируется вместе с объектом. Live-контакт и принятый после lift контакт
переходят одному модельному владельцу до публикации обычных чернил. Подготовленное
значение листа повторно не декодируется ради масок после каждого своего штриха.
Пассивные painter bands с затронутыми элементами требуют новой публикации.

Новые операции: transport **18**, manifest **5**. Прежний получатель не должен
подтвердить действие, отбросив неизвестные targets. Новый получатель принимает
уже накопленные manifest 4; они не переписываются. SQLite schema, идентичности,
trust и правила разрешения конфликтов не меняются.

Выбранная проверка **0.3.72 (75)**:
`.build/element-erasing-final-20260917/verification.json`, `passed`,
`./verify.sh:selected`, explicit-only, **902 исходника**, SHA-256
`c4029fc3e79e77590d80530e8e20a1dabd14a95acb43883be017bea66b02cf05`.
**32 Core / 7 suites, 33 native iPad, 5 native Mac — PASS**, 0 skips/runtime
warnings. iPad `00008103-001E059934D9001E`, iPadOS 27.0 (24A435), без Simulator.
Core проверяет swept contact, union независимых ластиков, старые действия без
целей, неизменность UUID/targets, точность дальних tiled-world координат,
адресный spatial writer, SQLite reopen, доставку/повтор/отмену и manifest 4/5.
В выбранную область вошли проверки нового checkpoint и зависимостей страниц.

Настоящая смонтированная UIKit-сцена листа и доски получает синтетический
Pencil-eraser через установленный оконный recognizer. У прямоугольника исчезает
только участок левого края уже до lift. После записи тот же вырез остаётся,
новый экземпляр NotebookStore читает неизменную фигуру и те же targets; одна
отмена восстанавливает контур и сохраняется на диске. На доске основание —
тайлы 90 000 000 / −120 000 000, scale 0.8. Проверены также прежние сценарии
обычного ввода, распознавания, удержания, обеих осей и hand/lift. Mac-renderer
проверяет пиксели эллипса, прямоугольника и плюса: повторные перекрывающиеся
ластики не возвращают вырез; перенос сохраняет вырез; отмена возвращает оригинал.
Дополнительный сценарий применяет к старому PaperInputView прежнее значение
чернил сразу после lift, до асинхронной подготовки: поздняя отмена этой
поверхности не может убрать уже принятое моделью стирание. Владелец принятого
действия явно защищён, как и у распознанной фигуры. После этого уточнения весь
выбранный набор выполнен заново. PNG осмотрены, экспорт вне неизменной квитанции:
`.build/element-erasing-final-visual-20260917/contact-saved-undo.png` и
`mac-cutout-move-undo.png`. Пиксели contact и saved на обеих поверхностях
совпадают (`contact-saved-comparison.json`); это сравнение двух кадров, не
измерение непрерывного видеоряда.

Неудачные проходы не являются допуском выпуска. Первый diagnostic
`element-erase-check-20260917`: board PASS, page остановлен вручную. Второй
`element-erase-check2-20260917`: page timeout 60 s; системный spindump показал
цикл SwiftUI update → inactive spatial cancel → повторная запись отсутствующей
working-mask. Это регрессия нового кода, не проблема теста: no-op cancellation
больше не меняет наблюдаемое состояние. Окончательный полный выбранный native
набор после исправления прошёл заново. Промежуточный более широкий Core
`element-erasing-20260917` был остановлен после 11 нарушений в семи старых
BoardPlacementMigration-сценариях: они требуют SQLite user_version 4 и считают
5 неизвестной, тогда как неизменный HEAD уже использует schema 6 с `1f7bb25`.
Эти устаревшие ожидания не переписывались в исправлении ластика. Финальная
область явно ограничена затронутыми операциями; общий Core PASS не заявляется.

Это проверка синтетическим контактом на физическом устройстве, не приёмка
настоящим Pencil. Живое стирание пассивных тяжёлых web-элементов до публикации,
плотная сцена, системные кадры/CPU/GPU/память, десять настоящих повторов и 30 минут
пары этим срезом не подтверждены. MyScript этим изменением не интегрировался;
чужой завершённый документационный commit `31acfc5` не менялся.

В **21:10 МСК** окончательная подписанная **0.3.72 (75)** установлена поверх
рабочей `.preview` и открыта, PID **2349** подтверждён отдельным process readback.
Строгая сборка обоих приложений:
`.build/element-erasing-final-release-20260917/build.json`, `verified-build`,
тот же окончательный source. Установка:
`.build/element-erasing-final-install-20260917/operation.json`.
Все девять путей данных и их метаданные до запуска совпали. `.native-test`
удалена; полный inventory содержит ровно один Notebook — Lab 75. Рабочее
приложение не удалялось, SQLite не копировалась, архивы не восстанавливались,
CloudKit не включался. Предыдущая промежуточная установка того же номера
заменена in-place после проверки защиты принятого действия. Копий приложения
на iPad не осталось. Mac собран, но не установлен; для обмена требуется
обновление его помощника до protocol 18. Амиру отправлена проверка настоящим
Pencil: частично стереть круг/стрелку на листе и доске, поднять Pencil и отменить
одно действие. Ответ пока не получен; GUI-205 остаётся In Progress.

## 17 сентября, 21:38 МСК — GUI-205: распознавание по реальным неудавшимся штрихам

После ответа Амира «готово» с физического iPad прочитаны измерения оставленных
набросков. Диагностическая копия SQLite снята при нулевом WAL; метаданные до и
после копирования совпали, `quick_check=ok`. Обратной записи на устройство не
было. После извлечения геометрии копия базы удалена. Свидетельства:
`.build/recognition-user-samples-20260917/sample-extraction.json` и
`baseline.txt` / `after.txt`. Прежние рисунки и уже распознанные объекты на
рабочем листе не переписывались.

`Tests/NotebookCoreTests/Resources/QuickShapeMeasured.json` содержит только
измеренные пары x/y: 12 прямоугольников, 3 двухштриховых плюса и 6 неподдерживаемых
треугольников/ромбов. У каждой фигуры убран общий сдвиг; порядок, количество и
геометрия точек сохранены. В фикстуре нет идентификаторов, времени, давления,
страницы или прочего содержания. На этих конкретных данных прежний классификатор
дал 5 правильных rectangle, 2 ошибочных ellipse и 5 отказов; все 3 плюса
отклонил. Новый даёт 12 rectangle и 3 plus; шесть неподдерживаемых многоугольников
остаются чернилами. Это результат на предоставленной выборке, не общая оценка
точности распознавания чужого или будущего почерка.

Причина — сравнение с краями bounding box: изгиб одной стороны/выход при
замыкании сдвигал шаблон всей фигуры. Этот путь в `NotebookQuickShape` заменён
подгонкой измеренных сторон с ограниченным наклоном. Четыре прохода по максимум
384 равномерным по длине точкам; затем проверяются реальные углы, остаточная
ошибка и покрытие каждой стороны. Наличие углов отделяет прямоугольник от овала.
Плюс проверяется относительно измеренного пересечения, а не центра box, и
обязательно имеет четыре луча. Его короткий размер допускается от 16 экранных
пунктов при длинном от 24; прежний минимум 24 по обеим осям отсекал маленький
предоставленный плюс. Таймер удержания 0.5 s, контракт контакта, стабильный ID,
обе оси изменения, сохранение и отмена не изменены. Второго распознавателя,
фонового преобразования старой страницы или запасного прежнего fit нет.

Выбранный маршрут `.build/quickshape-measured-20260917/verification.json`:
**10 Core-тестов и 36 native-тестов на физическом iPad**, без ошибок, пропусков
и runtime warnings. Source:
`b525f08b81dc8738f20c9b7331904ad5a94f84cab7c96462af43a713a2faa3bf`.
Реальные геометрические фикстуры проходят в трёх масштабах и зеркальном
отражении; проверки сохраняют различение кругов, линий/стрелок, неполных фигур
и букв. Все 15 положительных примеров также пройдены через синтетический UIKit
контакт, hold, lift и принятие исходных измерений на настоящем устройстве.
На 75 вызовах fit в Debug: median **3.018 ms**, p95 **5.663 ms**, max **7.269 ms**.
Это время классификации после удержания, не задержка от начала жеста и не
системные кадры/CPU/GPU. Вычисление не добавлено в обработку каждого Pencil sample.

Неровный прямоугольник отдельно прошёл сцену страницы с оставшейся рукой и
сцену доски, задержанную публикацию и новое чтение после shutdown. PNG при hold
и через 100 ms после lift осмотрены и побайтно совпадают на каждой поверхности:
`.build/quickshape-measured-visual-20260917/`. Обычные сценарии круга/стрелки,
двух осей и частичного ластика также прошли. Физический iPad здесь исполнял
автоматические контакты; это не подтверждение нового ручного жеста Амира.
Simulator, полная 30-минутная приёмка пары и системное профилирование не запускались.
Треугольники, ромбы и MyScript этим исправлением не добавлены. Параллельный
документационный срез `034fa89` удалил отменённый MyScript-план; его удаления
сохранены, документ не восстанавливался.

В **21:40 МСК** подписанная **0.3.73 (76)** установлена in-place поверх
`com.amirtlinov.notebook.preview` и открыта; PID **2398**, версия и bundle
подтверждены отдельным readback. Строгая сборка пары:
`.build/quickshape-measured-release-20260917/build.json`, `verified-build`,
тот же source. Установка:
`.build/quickshape-measured-install-20260917/operation.json`.
Все девять путей данных сохранились. Метаданные SQLite до запуска совпали;
изменился только диагностический `runtime/input-frames.json`.
`.native-test` удалена; inventory содержит ровно один Notebook Lab 76.
Рабочее приложение не удалялось, архивы не восстанавливались, CloudKit не
включался. Mac собран, но не установлен; прежнее ограничение пары protocol
16/18 этим срезом не решается. Амиру отправлена просьба проверить новые
неровные квадраты и двухштриховый плюс настоящим Pencil. Ручное подтверждение
пока не получено; GUI-205 остаётся In Progress.

## 17 сентября, 22:33 МСК — GUI-205: конец под Pencil, линии и многоугольники

Амир сообщил смещение линии/стрелки и при первом распознавании, и при движении
удерживаемого Pencil; у составных стрелок оставались исходные штрихи. Из его
новых измерений пополнена та же обезличенная x/y-фикстура: всего 60 примеров —
12 прямоугольников, 3 плюса, 9 треугольников, 8 ромбов, 16 линий/минусов и
12 стрелок. Прежний fit распознавал 7/16 этих линий и 6/12 стрелок; треугольники
и ромбы не поддерживал. Новый fit на данной выборке даёт все 60 ожидаемых
типов, включая три масштаба и отражение. Это регрессия предоставленных
примеров, не оценка общей точности на новом почерке.

Диагностика `.build/recognition-polygons-samples-20260917/capture-evidence.json`:
SQLite/WAL до и после чтения не изменились, WAL был пуст, `quick_check=ok`;
из метаданных изменился только `.sqlite-shm`. Копия SQLite после извлечения
геометрии удалена; обратной записи и преобразования старого рабочего листа нет.

В `NotebookQuickShapeSession` ближайший конец соединителя закрепляется под
реальным контактом **до первого показа** и затем следует за ним по обеим осям.
Автоматическая привязка сохраняет эту точку, а не оттягивает её к соседнему
объекту. У стрелки покрытие стержня и обоих перьев проверяется независимо:
прежнее эксклюзивное распределение точек у стыка отсекало неровное перо,
после чего только последний штрих превращался в линию. Короткие минусы
допускаются от 6 экранных пунктов с контролем поперечного отклонения и
возвратного движения. Нового распознавателя и работы на каждом Pencil sample
нет; удержание 0.5 s не менялось.

Треугольник и ромб используют общий нативный контур для показа, привязки,
выбора и частичного ластика. Нормализованные углы сохраняют ориентацию при
изменении рамки. Углы — одно необязательное причинное поле; отдельно проверены
явная очистка, принятие фигуры другим автором и отмена. Протокол 19 / manifest 6
защищает новые типы от старого декодера; очереди manifest 4/5 продолжают читаться.

Окончательный выбранный маршрут:
`.build/quickshape-polygons-release-check-20260917/verification.json`,
source `97199aa3601cc7733409e073445b0cf819917105e5e043332a640e6d9b00f031`.
**45 Core, 56 MCP, 38 native на физическом iPad и 5 Mac-rendering тестов**
прошли без ошибок и пропусков; native runtime warnings отсутствуют. Проверены
адресная доставка с повтором и restart, сохранение исходных измерений,
стабильный объект при hold/lift и поздней публикации, обе оси и новое чтение.
В промежуточном проходе исправлено неверное ожидание нового board-теста:
существующий ввод может дописывать один совпадающий terminal sample при lift;
тест теперь проверяет его совпадение по координатам и времени, а не требует
удалять измерения. После этого выбранный набор выполнен целиком заново.

Все 60 измеренных примеров прошли синтетический UIKit-контакт на настоящем
iPad. 300 вызовов fit в Debug: median **4.700 ms**, p95 **12.139 ms**,
max **28.748 ms**. Это вычисление после удержания, не задержка всего жеста,
системные кадры или сравнение ускорения с иной выборкой. Для треугольника,
ромба, двух составных стрелок и короткой линии кадры при hold и через 100 ms
после lift побайтно совпадают на странице и доске — все десять пар:
`.build/quickshape-polygons-visual-20260917/{page,board}/comparison.json`.
PNG осмотрены; частичные вырезы треугольника/ромба, перенос и отмена проверены
Mac-renderer, изображения сохранены в подкаталоге `eraser`.

Подписанная **0.3.74 (77)** установлена in-place и открыта на рабочем iPad;
PID **2465** подтверждён отдельным process readback. Сборка обоих приложений:
`.build/quickshape-polygons-release-20260917/build.json`, `verified-build`,
тот же source. Установка:
`.build/quickshape-polygons-install-20260917/operation.json`.
Все девять путей данных сохранены; метаданные SQLite совпали, изменился только
`runtime/input-frames.json`. iPadOS переместила data container при обновлении.
Рабочая `.preview` не удалялась; `.native-test` удалена, inventory содержит
ровно один Notebook Lab 77. Архивы не восстанавливались, CloudKit не включался.

Mac собран, но **не установлен**: рабочий помощник всё ещё 0.3.62 (65),
protocol 16; обмен пары с protocol 19 не подтверждён и требует обновления Mac.
Simulator, системное профилирование и 30-минутная приёмка не запускались.
Автоматический контакт на устройстве не заменяет настоящий Pencil: Амиру
отправлена проверка линии/стрелки при распознавании, движении и отрыве, а также
новых многоугольников. Ручной ответ пока ожидается; GUI-205 остаётся In Progress.

## 17 сентября, 23:08 МСК — GUI-205: выбор фигур, управление связью и акцент агента

Амир сообщил постоянный перламутр после создания, недоступный выбор треугольников
и непредсказуемое управление стрелками. Уточнение: акцент на действиях агента
нужно оставить, но сделать спокойнее. Новые человеческие квитанции больше не
попадают в подсветку. Только новый `author=agent` получает тонкий приглушённый
край на 1.4 s. Срок принадлежит модели, не `task` перемонтируемого вида; история,
повторное чтение и возврат на страницу его не продлевают.

Общий picker выбирает настоящую внутренность замкнутой фигуры, сохраняя приоритет
видимого контура, вложенных фигур и программ. Углы bounding box треугольника/
ромба не превращаются в фигуру, охватывающий viewport пустой объект не забирает
навигацию. Добавлены боковые ручки независимого изменения ширины/высоты; все
восемь ручек имеют экранные области касания 44 pt. Тело стрелки переносит её,
не включает изгиб неявно: связанные концы отсоединяются по видимой геометрии,
frame и концы сохраняются атомарно; Undo восстанавливает привязки. Конец пальцем
можно привязать внутри многоугольника или возле его края; удержание текущей
цели у границы уменьшает скачки. Синий контур цели существует только во время
этого жеста. Удерживаемый Pencil по-прежнему закреплён под кончиком.

Сравнение с актуальным локальным tldraw и его первичными описаниями ручек/
привязок записано в `docs/editable-graphics-contract.md`. Не добавлены второй
редактор, новый владелец жеста, модель документа или журнал. Проценты ускорения
и превосходство над tldraw этим срезом не заявляются.

Выбранный маршрут `.build/graphic-interaction-check3-20260917/verification.json`:
source `eae51051d5395c7591e636765802398b8fa78b1175e8bad8bfe8da7932f2bc5e`.
**16 Core, 38 native и 3 UI-сценария на физическом iPad, 5 Mac-rendering** —
без ошибок, пропусков и native runtime warnings. В UI-сценариях XCTest реально
нажимает/перетаскивает треугольник и ромб изнутри, меняет их ширину и высоту,
привязывает конец стрелки, двигает узел и повторно открывает сохранённое.
Отдельный прежний сценарий проверяет изгиб и редактирование подписи связи.
Native покрывает отмену/второй палец/Pencil, удержанный прежний состав сцены,
совместный commit рамки и отсоединения, причинную отмену, отсутствие человеческой
подсветки и истечение агентской без видимого компонента.

В промежуточном проходе исправлена оставшаяся ссылка теста на переименованный
enum четырёх углов. Следующий проход дал 37 native PASS, но UI runner не получил
системное разрешение Enable UI Automation. После того как Амир ввёл код на
самом iPad, окончательный выбранный набор исполнен целиком заново; ограничение
не обходилось и не записано как успешная проверка.

Физические PNG осмотрены:
`.build/graphic-interaction-ui-20260917/manifest.json` — выбор/ручки/связи на
странице и доске; `.build/graphic-interaction-visual-20260917/manifest.json` —
акцент на показанном элементе, исчезновение и повторное монтирование. Два
последних кадра побайтно совпадают: истёкший эффект не появляется снова.
Это UI-жесты и native-сценарии на устройстве, не ручная приёмка новым почерком,
не системное профилирование, десять повторов или 30 минут совместной работы.

В **23:10 МСК** подписанная **0.3.75 (78)** установлена in-place и открыта на
рабочем iPad; PID **2558** подтверждён отдельным process readback. Обе Release
сборки проверены: `.build/graphic-interaction-release-20260917/build.json`,
тот же source. Установка: `.build/graphic-interaction-install-20260917/operation.json`.
Все девять путей данных сохранены, метаданные SQLite до запуска совпали;
изменился только `runtime/input-frames.json`, iPadOS переместила data container.
Оба временных bundle `.native-test`/`.uitests.xctrunner` удалены, остался один
Notebook Lab 78. Архивы и облачная настройка не менялись. Снимок рабочего листа
`.build/graphic-interaction-install-20260917/opened.png` осмотрен.

На реальном листе фигуры значительно меньше крупных тестовых узлов. Это выявило
дополнительную ошибку маршрута: 44-пунктовые области ручек покрывали середину
маленькой выделенной фигуры. Перед завершением среза добавлена конкуренция
центра с ближайшей ручкой в том же `handle(at:)`, используемом UIKit и gate.
Середина остаётся переносом; точка ручки и наружная область — изменением размера.
Нативная регрессия проверяет 12×12, 40×32 и 64×100 pt, а оба UI-сценария теперь
начинаются с треугольника **40×32 pt**, а не 200×160. Сборка 78 не выдаётся за
окончательную проверку этого добавления.

Окончательный повторный маршрут:
`.build/graphic-interaction-check4-20260917/verification.json`,
source `2efc53493c3f18a5bafd388c431ffa5a8062d7c093347ef979031479cbb415aa`.
**16 Core, 39 native + 3 UI на физическом iPad, 5 Mac-rendering** — PASS,
0 ошибок/пропусков/runtime warnings. До запуска Xcode дождался разблокировки
устройства самим Амиром; проверки не переносились в Simulator. Оба физических
UI-сценария прошли перенос из середины уже выбранного маленького треугольника,
увеличение боковыми ручками и привязку/следование связи. Финальные PNG осмотрены:
`.build/graphic-interaction-small-ui-20260917` и
`.build/graphic-interaction-small-visual-20260917`.

В **23:20 МСК** окончательная подписанная **0.3.76 (79)** заменяет 78 in-place,
запущена без fixture-аргументов; PID **2648** подтверждён отдельным readback.
Проверенная сборка обоих приложений:
`.build/graphic-interaction-small-release-20260917/build.json`, `verified-build`,
тот же финальный source. Установка:
`.build/graphic-interaction-small-install-20260917/operation.json`.
Девять путей данных сохранены, SQLite-метаданные до запуска совпали; изменился
только `runtime/input-frames.json`. Data container перенесён iPadOS. Рабочий
bundle не удалялся; `.native-test` и `.uitests.xctrunner` удалены, inventory
содержит ровно один Notebook Lab 79. Исторические архивы, ключи, сопряжение и
облачная настройка не менялись.

Mac собран, но **не установлен**; текущий bundle отдельно прочитан как
0.3.62 (65). Совместимость установленной пары и доставка нового агентского
действия с этого старого Mac на iPad данным срезом не доказаны. Акцент агента
проверен через настоящую квитанцию в изолированном native-сценарии и показ
его компонента на физическом устройстве. Амиру отправлен конкретный запрос
ручной проверки своих маленьких фигур/ручек/привязок; ответа на момент записи
нет. GUI-205 остаётся In Progress, остальной согласованный объём и полная
физическая приёмка не объявляются завершёнными.

## 17 сентября — перламутровый проход по самому элементу (GUI-205)

Амир не принял слабую внешнюю рамку из 0.3.76 (79): она почти не видна и не
совпадает с геометрией. Этот визуальный отзыв не является приёмкой прежнего
акцента. Рамка и её тень удалены; `NotebookAgentPearl` делает один широкий
бирюзово-лиловый / бело-розовый проход за **1.8 секунды**. Маску замкнутой фигуры,
плюса, кривой связи, наконечников и подписи рисует существующий
`NotebookGraphicView`. Сохраняются настоящие вершины, камера, layout, частичные
стирания и обрезка листом. Максимум белого блика ограничен, чтобы подпись не
выбеливалась. Фильтр доверенного авторства `agent`, модельное истечение срока,
отсутствие повторного запуска при remount и статичный Reduce Motion сохранены.
Хранение, конфликтные правила, ввод и undo не менялись.

Окончательный выбранный маршрут:
`.build/agent-pearl-sweep-check3-20260917/verification.json`,
source `c292d9909257c11529de45097e0119ef4886bb7b5d1403aadf446c2ab002f32a`.
**12 native + 2 UI на физическом iPad, 5 Mac-rendering — PASS**, без ошибок,
пропусков и runtime warnings. UI повторяет выбор, перенос маленького
треугольника, боковые ручки и привязку связи на листе и доске. Native проверяет
точную опубликованную геометрию в обеих сценах, полный проход через внутренность
фигур, отсутствие окраски пустых углов bounding box, стирание, масштаб 1.75/2,
границу листа, истечение, авторство и Reduce Motion.

В первом проходе исправлены типизация координат тестовой сетки и недостающий
`await shutdown`. Во втором изображение уже имело полный градиент, но проверка
ошибочно требовала цвет в одной точке именно в момент белого блика над белой
бумагой. Теперь проверяется изменение этой внутренней точки за проход, а не
искусственное запрещение белой части градиента. Порог заметности не снижен.
Финальный набор после изменения теста и интенсивности блика выполнен заново.

Физические PNG до/во время/после и отдельные сцены осмотрены:
`.build/agent-pearl-sweep-final-visual-20260917/manifest.json`.
Тест также сохранил **18 кадров настоящего смонтированного TimelineView**
в `agent-pearl-physical-pass` (GIF, 2.5 s вместе с финальной паузой). Проверены
вход, середина и выход; GIF имеет ограниченную палитру и не используется для
оценки гладкости цвета — для неё служат PNG. Истёкший и повторно смонтированный
виды побайтно одинаковы. `devicectl screen-record` на этом iPad возвращает
`Screen Recording is not supported`; запись экрана этой командой не заявляется.
Это не измерение FPS/CPU/GPU, не десять повторов и не 30-минутная приёмка.
Ручная оценка нового вида Амиром и свежая межустройственная доставка не заменяются
изолированным действием настоящего Store и native-отрисовкой. GUI-205 остаётся
In Progress.

В **23:46 МСК** подписанная **0.3.77 (80)** установлена поверх рабочего Lab
и открыта без fixture-аргументов; PID **2753** подтверждён отдельным process
readback. Сборка обоих приложений:
`.build/agent-pearl-sweep-release-20260917/build.json`, `verified-build`,
тот же source. Установка:
`.build/agent-pearl-sweep-install-20260917/operation.json`.
Девять путей данных сохранены, SQLite-метаданные перед запуском совпали;
изменился только `runtime/input-frames.json`. Рабочий bundle не удалялся,
временные `.native-test` и `.uitests.xctrunner` удалены; остался один Lab 80.
Снимок открытого рабочего листа `opened.png` осмотрен. Mac в этом срезе не
устанавливался. Архивы, содержимое рабочего пространства, ключи, сопряжение и
настройка облака этим изменением не редактировались. Оценка нового эффекта
самим Амиром ещё не получена.

## 18 сентября — непрерывное управление элементами и нативные меню (GUI-205)

Амир не принял прежнее управление и прислал четыре примера Freeform. Это
исправление существующего редактора, не заявление о полном наборе Freeform/tldraw.

* У маленьких фигур четыре круглые угловые ручки; боковые полоски появляются
  только при достаточном экранном расстоянии. Геометрия больше не ограничена
  размером touch-target 44 pt и максимумом доски 2048. Угол меняет обе оси,
  противоположный остаётся на месте. Нажатие без движения не начинает запись.
* Выбранный материал переносится без повторного удержания. При resize меняется
  само содержимое, не только рамка: тот же WebKit проецируется по обеим осям,
  не пересоздаётся и сохраняет runtime до канонического изменения размера.
* Удалён общий запрет новых графических действий до завершения предыдущего
  сохранения. У каждого элемента удерживается последнее принятое значение;
  следующий жест/цвет продолжает его. Один writer и прежний action executor
  сохраняют точный результат предшественника. Проверка этого источника и запись
  атомарны; чужая правка не становится новой молчаливой базой. Ошибка отменяет
  зависимые команды, человеческое авторство и причинная отмена сохранены.
* Разрозненные кнопки и вложенные текстовые списки цветов заменены одной
  системной glass-капсулой, нативным UIMenu и popover-палитрой. Есть линия/заливка,
  образцы цветов/толщины/пунктира, системный произвольный цвет, подпись, красное
  удаление, порядок и наконечники. Палитра не закрывает редактируемую фигуру в
  проверенном сценарии; её закрывающее касание не выбирает холст. Перестановка
  получает полное членство из SQL, а не из ограниченного окна доски.

Неизменный source **50cf9644751815e5c4011b61bb816a733ed63d4bad9ed12dc9251d3ae5651d56**:
`.build/element-controls-final-20260918/verification.json`, selected PASS:
**13 Core, 55 native + 5 UI на физическом iPad, 5 Mac-rendering**, без failures,
skips и runtime warnings. Xcode runners выполнялись последовательно, Simulator
не использовался. UI проходит маленький треугольник, уменьшение/увеличение,
боковые ручки, перенос ромба и перепривязку стрелки на листе/доске, повторное
открытие; четыре угла материала; живую соседнюю программу; палитру, закрытие,
повторное открытие, порядок и удаление. Native отдельно удерживает SQLite занятой
на шести последовательных действиях, проверяет результат после reopen и Undo,
отказ при внешней правке, а также размер того же смонтированного WebKit ещё
до отпускания пальца и его реальные пиксели/идентичность после принятия жеста.
Core проверяет off-screen членство порядка.

Промежуточные проходы выявили настоящий aspect-fit вместо изменения двух осей,
перекрытие центра связи панелью под верхним узлом и попадание закрывающего
popover-касания также в сцену — исправлены владельцы геометрии/контакта.
Отдельно исправлены ошибки проверки: выбор последней операции через неверный
порядок receipts, точное сравнение floating-point CGRect вместо погрешности,
координата внутри стрелки popover и отсутствие ожидания его закрытия перед
следующим нажатием. Исправлены компиляционные ошибки новых тестов/адаптера и
scope нативной перестановки; предусловия публичного MCP не ослаблены.
Окончательный маршрут целиком выполнен после этих изменений. PNG итоговых
жестов и панели осмотрены в `.build/element-controls-final-visual-20260918/`;
положение палитры отдельно осмотрено в `element-controls-palette-visual8-20260918`
на том же source.

Ручная оценка ощущений Амиром ещё не получена. Это не системное измерение FPS,
CPU/GPU/памяти, не десять повторов и не 30 минут совместной работы. Вращение,
множественное выделение, группы, clipboard/дублирование и весь остальной объём
GUI-205 этим срезом не объявляются готовыми. Перламутр агентских действий не
менялся; никаких новых подсветок человеческим фигурам не добавлено. Полная
приёмка и GUI-205 остаются открытыми.

В **00:51 МСК 18 сентября** подписанная **0.3.78 (81)** установлена поверх
рабочего Lab и открыта без fixture-аргументов; PID **3072** подтверждён отдельным
process readback. Сборка обоих приложений:
`.build/element-controls-release-20260918/build.json`, `verified-build`, тот же
source. Установка: `.build/element-controls-install-20260918/operation.json`.
Все девять прежних путей данных и их метаданные перед запуском сохранены.
Рабочий bundle не удалялся; временные `.native-test` и `.uitests.xctrunner`
удалены, остался один Lab 81. Снимок рабочего листа `opened.png` осмотрен.
Mac собран, но не устанавливался; синхронизация этой установленной пары здесь
не проверялась. Архивы не восстанавливались, рабочие материалы, идентичности,
ключи, сопряжение и настройка облака этим изменением не редактировались.
Амиру предложена ручная проверка немедленной последовательности
«маленькая фигура → уменьшить за угол → перенести → открыть палитру»;
её результат пока не получен.


### Обратная связь по 0.3.78 (81) и следующий срез

После установки Амир сообщил: «стало значительно лучше». Следующее замечание:
средняя точка линии не смещается нужным образом; нужны и отдельные вершины,
и скругление углов, вероятно с переключением режима в контекстном меню.
Это положительная ручная оценка базового среза, не приёмка ещё отсутствовавших
режимов. Прежняя запись «результат пока не получен» описывает момент установки.

Реализуются три явных режима одной selection session и двухосная средняя точка
связи. Проверка этого среза ведётся отдельно от квитанции 81. Промежуточные
check1–check3 не являются PASS: сначала новый тест пытался принять снимок в
неинициализированный Store; затем проверка выявила не обновлённый генерируемый
SDK reference; после генерации общий help вырос до 24,681 байта и превысил старый
порог 24 KiB на 105 байт. Инициализация теста исправлена, ресурс сгенерирован
штатным владельцем, предел help поднят до 25 KiB с дополнительной структурной
проверкой одной общей target union и повторного использования её board-only
варианта. Check4–check5 дополнительно выявили ошибки именно новой структурной
проверки (optional в TypeScript и предположение о плоской схеме); проверка
уточнена по реальному $ref/oneOf, не по ожидаемому числу сырых определений.
Check6 остановился на недоступном setter selection session: переключение режима
перенесено к её существующему владельцу в NotebookAppModel, доступ не расширен.
В check7 прошли 58 из 60 iPad-проверок. Два новых UI-сценария успешно изменили
вершины, скругление и обе координаты изгиба, но после reopen нажимали в пустой
центр bounding box уже изогнутой линии. Повторный выбор исправлен на фактическую
точку контура, сохранённую перед закрытием. Это ошибка координаты проверки,
не основание расширять выбор линии на пустую область. Дополнительно ограничено
перетаскивание вершины с сохранением направления обхода: треугольник не может
перескочить через противоположное ребро и вывернуться.

### 0.3.79 (82): проверенные режимы геометрии

Окончательный неизменный source
**dc3967a619a5c69e3eb00c160964b0b34a67fa80f7d27591ab8e24f8737e104d**:
`.build/geometry-edit-final-20260918/verification.json`, selected PASS:
**15 Core, 57 MCP, 55 native + 5 UI на физическом iPad, 6 Mac-rendering**;
без failures, skips и runtime warnings. Runners выполнялись последовательно,
Simulator не использовался.

На листе и доске проверены меню трёх режимов, перемещение отдельной вершины
треугольника и прямоугольника при неподвижных остальных, видимое скругление
контура без изменения рамки, возврат к обычному resize, движение средней ручки
свободной линии по двум осям с неподвижными концами и сохранение после reopen.
Прежние сценарии привязанных стрелок и палитры также прошли. Соседняя программа
не меняет положение. Итоговые PNG осмотрены в
`.build/geometry-edit-final-visual-20260918/`: скруглённый вытянутый треугольник,
скошенный скруглённый четырёхугольник, привязка стрелки и асимметричный изгиб.

Native отдельно проверяет занятый SQLite writer: вершина → скругление → стиль
сразу продолжают принятое состояние, затем сохраняются; Undo радиуса не
отменяет вершины и стиль. Core проверяет доставку/повторное открытие/Undo на
листе и доске, контур и привязку у круглого угла. Mac проверяет реальные пиксели
скруглённого многоугольника. Это не приёмка всей GUI-205, не системный профиль
производительности и не десять повторов/30 минут смешанной работы. Ручная оценка
новых режимов Амиром остаётся отдельной проверкой.

В **01:28 МСК 18 сентября** подписанная **0.3.79 (82)** установлена поверх
рабочего Lab и открыта без fixture-аргументов; PID **3240** подтверждён отдельным
process readback. `.build/geometry-edit-release-20260918/build.json` —
`verified-build` обоих приложений с тем же source; установка записана в
`.build/geometry-edit-install-20260918/operation.json`. Рабочий bundle не удалялся.
iOS переназначила UUID data container, но все девять прежних путей остались,
включая SQLite/WAL; из сравниваемых метаданных изменился только
`runtime/input-frames.json`. Снимок открытого прежнего рабочего листа `opened.png`
осмотрен. Временные `.native-test` и `.uitests.xctrunner` удалены; остался один
Lab 82. Mac собран, но не установлен: работа установленной пары и облачная
доставка новых полей этим срезом не подтверждаются. Архивы не восстанавливались,
данные не копировались и не очищались; ключи, доверие пары и включение облака
не менялись. Амиру предложена ручная проверка новых режимов на рабочем листе.

### Обратная связь по 82: прямые кнопки в таблетке (GUI-205)

Амир оценил режимы как «неплохо», попросил одну кнопку переключения в таблетке
и отдельные «Начало»/«Конец» для линий. Сообщил о нераскрывающихся вложенных меню.
На прежнем runtime 82 новая физическая регрессия дошла до верхнего меню,
но подменю не открылось: XCTest дважды сообщил незавершённую анимацию, затем
получил hit point {-1,-1}. После двух минут ожидания проход остановлен вручную;
`.build/capsule-endpoints-baseline-20260918/` не является PASS. Снимок верхнего
меню осмотрен. Это подтверждает сбой маршрута, а не доказывает единственную
причину по одному сообщению XCTest.

Из пути убраны вложенные режимы и наконечники. Кнопка режимов меняет состояние
одним нажатием, а две кнопки концов открывают плоские списки. Прежняя установка
нового UIMenu при каждом SwiftUI update заменена одним стабильным UIKit menu
со свежим содержимым на открытие. Время показа/закрытия системного меню включено
в существующий input gate, как уже было сделано для палитры. Проверка новой
сборки 0.3.80 (83) ведётся отдельно.

Check1 прошёл 30 из 32 физических проверок; два новых сценария остановились
до открытия меню: скрытая кнопка режимов оставалась в вручную собранном
accessibilityElements линии. Исправлена доступность самой поверхности — в
accessibility включаются только видимые кнопки. Проверка не ослаблена до
isHittable: скрытый режим не должен предлагаться и VoiceOver. Остальные три UI
сценария режимов/палитры и 27 native в этом проходе прошли.


### 0.3.80 (83): режим и наконечники прямо в таблетке

Неизменный source
**e49562cc1e323651a660016debefcbcf96f47827cf300aa6624fe7b3fc44bee3**:
`.build/capsule-controls-check2-20260918/verification.json`, selected PASS:
**27 native + 5 UI на физическом iPad**, без failures, skips и runtime warnings.
Simulator не использовался. Core, MCP, Mac rendering и алгоритмы геометрии этим
срезом не менялись и отдельно заново не прогонялись.

На листе и доске проверены прямое открытие обоих списков наконечников,
независимый выбор круга у начала и треугольника у конца, видимое изменение
линии, повторное открытие, сохранение после перезапуска и последующая смена
конца на стрелку. Закрывающее касание вне меню сохраняет выделение, положение
линии и соседнего материала. Прямой цикл режимов проверен вместе с настоящими
жестами изменения вершины, радиуса и середины линии; прежняя палитра и команды
порядка не сломались. Native проверяет неизменную идентичность UIKit menu
при двадцати обновлениях controls, отсутствие скрытых кнопок в accessibility
и touch-target 44×44 pt даже при ширине поверхности 320 pt.

Снимки прямого списка, итоговой таблетки и активного режима скругления осмотрены
в `.build/capsule-controls-visual-20260918/`. Это проверка названных сценариев,
не полная приёмка GUI-205, не системный профиль производительности и не десять
повторов/30 минут совместной работы. Оценка удобства Амиром остаётся отдельной.


В **01:52 МСК 18 сентября** подписанная **0.3.80 (83)** установлена поверх
рабочего Lab и открыта без fixture-аргументов; PID **3353** подтверждён отдельным
process readback. `.build/capsule-controls-release-20260918/build.json` имеет
статус `verified-build` для обоих приложений и тот же source; установка —
`.build/capsule-controls-install-20260918/operation.json`. Рабочий bundle не
удалялся. iOS переназначила UUID data container; все девять прежних путей
сохранены, включая SQLite/WAL, из сравниваемых метаданных изменился только
`runtime/input-frames.json`. Снимок открытого прежнего рабочего листа `opened.png`
осмотрен. Временные `.native-test` и `.uitests.xctrunner` удалены, на устройстве
остался один Lab 83. Архивы не восстанавливались, данные не копировались и не
очищались, ключи/доверие/включение облака не менялись. Mac собран, но не
установлен: приёмка установленной пары этим изменением не заявляется. Амиру
отправлен вопрос о ручной проверке прямых кнопок на обновлённом рабочем листе.


### GUI-220: компактное единое оформление и сплошной чат

Амир подтвердил заметное улучшение 0.3.80 (83), затем попросил согласовать
оформление iPad без новой UI-архитектуры: чат не должен быть прозрачным,
таблетка выделения и её иконки слишком велики. Рабочий срез 0.3.81 (84)
заменяет разрозненные поверхности общим `NotebookChrome`: видимая панель
40 вместо 52 pt у элемента, символы 15 вместо 20 pt, цели касания 44×44 pt.
Навигация, инструменты, чат/компаньон, палитры, файлы, код и заголовки терминала
используют одинаковые фон/границу/тень. Системные меню остаются нативными;
содержание и прежние владельцы жестов, геометрии, записи и разговора сохранены.
Непрозрачность чата задана также в контейнере подготовки, WKWebView, scrollView
и HTML, не только в SwiftUI-обрамлении.

Первый физический проход `.build/unified-chrome-check-20260918` прошёл
42 из 45 проверок, но **не является PASS**. У настроек пера и стрелок страниц
Accessibility показывала границы самого символа, а не 44-point label:
декоративный неинтерактивный фон выявил отсутствующий `contentShape`.
Исправлены сами полноразмерные label; регрессии теперь нажимают возле края и
проверяют размер кнопки. Третья остановка была в сценарии палитры до выбора
объекта: перенесённый предыдущим сценарием чат перекрывал маленький треугольник.
Сценарий теперь сначала обычным жестом убирает компаньон в свободное место,
не кликает сквозь него и не очищает пользовательские настройки. Снимки и
иерархии первого прохода сохранены; проверка неизменного исправленного среза
запущена заново отдельно.


Второй проход `.build/unified-chrome-check2-20260918`: **44/45**, не PASS.
Оба исправленных 44-point hit target и сценарий палитры прошли; также прошли
все 34 native-проверки и 10 UI-сценариев. Составной сценарий страниц дошёл
через кнопку на лист 2, миниатюру на лист 3 и до результата поиска, но после
выбора «Живая математика … Глава 1» остался на странице 3 спустя 6 секунд.
Это вновь наблюдаемый симптом прежнего поиска после обзора, не доказательство
той же внутренней причины. Он записан в GUI-199; владельцы загрузки документа
и перехода этим срезом не меняются. Полный тест сохранён, его условия не ослаблены.
Для текущего оформления добавлен отдельный прямой сценарий кнопок, миниатюр,
полных целей касания и открытия/закрытия поиска, без утверждения о переходе
из поискового результата. Общая навигационная приёмка остаётся открытой.

Полная область панели также получила явный прямоугольный `contentShape`:
одного label оказалось недостаточно для касаний возле скругления. Прямой
сценарий страниц прошёл в `.build/unified-chrome-nav-hit-20260918` и в повторном
наборе `.build/unified-chrome-final2-20260918` (39/40; снова только переход из
поиска не завершился). На физическом снимке виден статус «Открываем страницу 1…»
при прежнем счётчике 3/3: запрос принят, а не потерян на строке результата.

Дополнительный тест отдельной круглой кнопки удаления сначала ошибочно нажимал
пустой угол её квадратных AX-bounds: выбор снимался вместо удаления. Нажатие
центра прошло. Контракт уточнён явно: цель отдельной круглой кнопки — диск
44 pt, а не квадрат; проверка нажимает видимую подложку сбоку от символа.
Пробные дополнительные control-region и изменения hit-testing фона удалены;
новых владельцев контакта не добавлено. У кнопок внутри панели остаются
прямоугольные 44-point цели, включая проверенные углы.

В **02:52 МСК 18 сентября** неизменный финальный срез прошёл выбранный маршрут
`.build/unified-chrome-final-pass-20260918`: **40/40 на физическом iPad**
(34 native + 6 UI) и **1/1 Mac** для общего HTML чата; ноль skips и runtime
warnings. Source SHA-256:
`a9aad42a9a647039d94c980645d84c22115fbee9beb11775a44973c1fc5a6a7d`.
Проверены непрозрачность всех слоёв чата, его перенос/размер/настройки, компактные
цели нажатия, страницы/миниатюры, перо, прямые окончания линии, палитра/меню и
удаление предмета из стопки. Финальный снимок выделенного маленького треугольника
в `.build/unified-chrome-visual-20260918/accepted` осмотрен: уменьшенная панель
не перекрывает фигуру, навигация/перо/компаньон используют то же оформление.
Это выбранная проверка UI, не полная приёмка, не системный профиль и не
десять повторов/30 минут совместной работы. Переход из поиска выше остаётся
в GUI-199; удобство оформления требует отдельной оценки Амиром.

В **02:55 МСК 18 сентября** подписанная **0.3.81 (84)** установлена поверх
рабочего Lab и открыта без fixture-аргументов; PID **3818** подтверждён отдельным
readback. `.build/unified-chrome-release-20260918/build.json` — `verified-build`
для обоих приложений с тем же source; установка и опись —
`.build/unified-chrome-install-20260918/operation.json`. Снимок `opened.png`
рабочего листа осмотрен. Все девять прежних data paths сохранены, включая
SQLite/WAL; из сравниваемых метаданных изменился только `runtime/input-frames.json`.
Рабочий bundle не удалялся; временные `.native-test` и `.uitests.xctrunner`
удалены, остался один Lab 84. Архивы, ключи, доверие пары и включение облака
не менялись. Mac собран, но не установлен. Оценка Амиром запрошена отдельно.

В **02:57 МСК** Амир ответил «гуд» на проверку масштаба таблетки/иконок и
цельности оформления установленной 0.3.81 (84). Этот UI-срез принят; GUI-220
закрыта. Это не закрывает оставшийся переход из поиска GUI-199 и общую
длительную приёмку.


## 18 сентября, 01:37 МСК — MCP S1: адресные чтения (GUI-210)

Исходный checkout `codex/notebook-ipad-reliability`, base `f38416d`.
`pageHeader`/`documentHeader` читают версии без тел; `pageElement` возвращает
элемент, его заголовок и вычисленную геометрию из одного WAL-снимка.
`observe` принимает точный адрес, выбирает не более 32 записей индексом до
декодирования и сравнивает версии до загрузки содержания. Отсутствующий
presence не блокирует явный адрес и возвращается как неизвестный контекст.
Старый полный `observe` удалён; картинки запрашиваются явно.

Три регрессии на прежней реализации действительно упали при повреждённом
непрочитанном элементе: адрес после первых 32, unchanged, ограниченное превью.
После исправления проходят 14 Swift-тестов Core/host (включая существующий
адресный documentBlock). Нагрузка 100 000 элементов: оба адресных чтения —
207 SQL-инструкций, 445 bytes сериализованного результата, 1.338/1.351 ms.
Нагрузка документа с 100 000 посторонних состояний — 335 SQL-инструкций.
Повреждённые чужие тела не декодируются. Это первые/повторные чтения в процессе
фикстуры, **не** холодный запуск приложения или системное измерение памяти.
Логи: `/tmp/notebook-s1-red.log`, `/tmp/notebook-s1-suite2.log`,
`/tmp/notebook-s1-host-final.log`.

55 MCP-тестов PASS; отдельный настоящий подписанный QuickJS/XPC сценарий
читает элемент №39 и повторный unchanged через тот же SDK. Неизменная
выборочная квитанция: `.build/mcp-s1-verify2-20260918/` (1 Mac XCTest, без
skips/runtime warnings). Первая native-проверка в `mcp-s1-verify-20260918`
выявила зависимость явного адреса от наличия presence; исправлен рабочий путь,
а не подставлено выделение в тесте. Устаревший счётчик справки исправлен
с 19 на реальные 20 операций; новый инструмент или операция записи не добавлены.

На момент этой квитанции установленный Mac ещё не обновлён. Физические жесты,
доставка/показ на iPad и полный набор системных метрик этим срезом не доказаны.
Рабочие контейнеры, доверие, пользовательское содержание и графические правки
другого checkout не изменялись. GUI-210 остаётся In Progress до live readback.

В 01:40 МСК S1 установлен **только на Mac** поверх существующего bundle.
Строгая Release-квитанция: `.build/mcp-s1-release-20260918`, source `34d450dc…`,
Mac manifest `f6132142…`, version 0.3.62 (65). Новая подписанная сборка сначала
проверена в staging; прежний точный процесс 71248 завершён штатным quit,
bundle заменён атомарно, установленный manifest и подпись перепроверены.
Старый bundle не оставлен как backup; данные и Keychain не копировались.
Другой helper из `.build/seven-slices-release-v4` не остановлен.
Квитанция установки: `.build/mcp-s1-install-20260918/install.json`.

Живой `notebook_context.observe` нового владельца socket (PID 58436) адресно
прочитал `physical-chapter-0` документа `43ADB4D3-B796-4231-8258-385C1AFB9682`;
повтор с прежним since вернул unchanged без блока. Workspace
`FAAAC405-8EF9-4FB9-9B93-CBD876FA97A4`, content `2@59adbe6e…` и state
`0@b03518fd…` совпали с read-only квитанцией до обновления. Запись содержания,
камера и показ не запрашивались. Физическая и системная приёмка остаются S10.

## 18 сентября, 01:46 МСК — MCP S2: поисковый срез (GUI-211)

Добавлены фильтры по типу источника и точной поверхности, явная coverage и
stateless keyset cursor. Курсор связан с workspace, нормализованным запросом,
фильтрами, порядком kind/address и currentChangeCursor (не currentReadCursor).
Изменение содержания явно отказывает как search_cursor_stale; присутствие и
камера не инвалидируют поиск. Все версии выбранных результатов остаются в
одном readTransaction. До LIMIT сортируются только ключи, тексты и ссылки
раскрываются адресно; точный total читает индекс на каждой странице.

Отрицательная регрессия отсутствующего continuation воспроизведена на S1.
8 Core-тестов с параметрическими вариантами PASS: все 23 результата при разных
page sizes, короткие строки/FTS, пустая выдача, вставка/удаление/изменение между
страницами, чужие workspace/query/filters, повреждённый cursor, смена presence,
повреждённое тело совпадения за пределами страницы. 512 совпадений (предельное
число блоков одного документа), total+keys+один hit: 12 167 SQL-инструкций.
Логи `/tmp/notebook-s2-red.log`, `/tmp/notebook-s2-final2.log`.
Это не константная стоимость total и не системный cold/warm benchmark.
Настоящий sandbox SDK и установленный readback на момент записи ещё ожидаются.

В 01:49 МСК S2 прошёл настоящий подписанный QuickJS/XPC сценарий: 13 совпадений
дочитаны за 5 страниц, последнее адресно прочитано через nb.page; native PASS,
0 skips/runtime warnings. Квитанция `.build/mcp-s2-verify-20260918/`, также
55 MCP PASS. В установленном Mac пока только S1; публикация S2 и следующих
MCP-only срезов будет согласованной сборкой, не десятью отдельными обновлениями
приложений. Это не отменяет физическую проверку при изменении самого iPad UI.

## 18 сентября, 02:16 МСК — MCP S3: дельты области и зависимой геометрии (GUI-212)

Один Core-читатель обслуживает observe и observation в read/readMany. Удалён
заменённый preview-reader S1. Снимок/дельта выбирают логические адреса до тел,
раскрывают только выбранные поля и одношаговые связи через существующие индексы.
next закрепляет workspace, нормализованную область/fields/expand, through и
позицию; checkpoint появляется только после исчерпания выдачи. Изменение между
страницами, чужая область и истёкшая история дают явный отказ, не полный обход.
Для spatial bounds/расширения действует явный предел 256 адресов; переполнение
отказывает и предлагает сузить запрос, а не выдаёт ложную полноту. Без bounds
владелец читается постранично. Presence имеет отдельное монотонное поколение.

Регрессия отсутствующего продолжения журнала сначала воспроизведена
(`/tmp/notebook-s3-red.log`). 10 Core-контрактов проверили 4103 изменения,
непрочитанные/повреждённые посторонние тела, scope/projection mismatch, stale и
expired курсоры, межвладельческую подделку continuation, nested document state,
выход/вход в spatial window, удаление и восстановление off-scope endpoint,
а также presence A→B→A без изменения журнала содержания. 3 Host-контракта
проверили адресность/повтор/ограничение превью. Дополнительные адресные,
поисковые и нативные element-регрессии также PASS. Логи:
`/tmp/notebook-s3-accepted-core.log`, `/tmp/notebook-s3-cleanup.log`.

Изолированный fixture из 100000 записей элементов: адресное чтение — 207
SQL-инструкций, 445 байт, 1.41/1.21 мс для двух повторов; дельта одного элемента
после записи — 548 инструкций, 1070 байт, 1.73 мс. Это прогретый процесс после
подготовки fixture, не cold start приложения и не системное измерение памяти.
Процент ускорения не объявляется; сопоставимые system/cold/warm/memory — S10.

56 MCP-тестов и два настоящих подписанных Mac/QuickJS/XPC сценария PASS:
адресное чтение/повтор и изменённая derived geometry неизменной стрелки после
перемещения узла. Квитанция `.build/mcp-s3-verify2-20260918/`.
Первый native build отказал из-за обращения теста к internal JSON accessor;
тест исправлен, второй выбранный маршрут завершён на неизменных исходниках.
Ожидали завершения физического runner другого checkout; параллельные Xcode
runners не запускались. Simulator, чужие графические правки, пользовательские
контейнеры и доверие пары не изменены. Установленный Mac пока остаётся S1;
публикация чтений войдёт в согласованное переключение SDK v2. Полная физическая
приёмка и системные показатели этим результатом не заменяются.

## 18 сентября, 02:49 МСК — MCP S4: согласованный SDK v2 и установленная запись (GUI-213)

Публичные чтения теперь возвращают Snapshot(data,basis,coverage,cursor), а
readMany — согласованный кортеж с отдельным coverage каждого запроса. Основания
собираются в том же WAL-снимке; Core объединяет их без освежения и проверяет
необходимые владельцы/компоненты отдельно от разрешённой области изменения.
ActionResult и effect.value записываются атомарно с domain commit; первоначальная
версия, её страницы и краткая модель квитанции не переписываются при undo.
Новые v1 starts отвергаются, исторический v1 run читается через v2 transport.
Короткое ожидание по умолчанию — до 1000 мс, ранний emit его не обрывает.
Схемы результатов, справка и notebook-sdk.d.ts генерируются одним маршрутом;
TypeScript пока только проверяет декларации, не является языком исполнения.

Регрессии сначала упали на v1 (`/tmp/notebook-s4-red2.log`). Итоговый scoped
Swift-проход: 15 Codex + 16 Host + 38 Core тестов PASS
(`/tmp/notebook-s4-core-final2.log`). 59 MCP тестов PASS, в том числе проверка
деклараций настоящим закреплённым TypeScript CLI, положительные и отрицательные
примеры, формы настоящих Native IPC ответов. Пять подписанных Mac/QuickJS/XPC
сценариев PASS без skips: label/basis/ранний emit, адресное чтение, дельты
зависимой геометрии, страницы поиска, отмена уже принятой записи.
Окончательная квитанция `.build/mcp-s4-verify3-20260918/`, source SHA256
`46cce79e5ac069c5c291fbec48c4f52ce2570c56eb802a42ea948d5b7bf23f85`.
Предыдущий verify2 честно отказал: Xcode incremental copy изменил декларации
в resource bundle, не обновив подпись вложенного xctest. Удалён только
производный Mac build cache этого checkout; чистая сборка прошла неизменённую
строгую проверку подписей. Права worker не расширялись, проверка не обходилась.

Подписанная пара `.build/mcp-s4-release-20260918/` собрана из этого точного
снимка. Установлен **только Mac**: source тот же, manifest
`a6442d28074017fd79cb3eb7bbc954396823a67a27bf380548b00ace1b087bc8`.
Точный прежний PID 58436 завершён штатно, новый PID 82348 владеет production
socket; bundle заменён атомарно, без retained backup/смены контейнера и ключей.
Другой helper/checkout не остановлен. Первая попытка чтения во время старта
получила ipc_unavailable; после появления production socket новая проверка
прошла. Это не доказательство нулевой холодной задержки.

Свежий stdio MCP запущен именно из установленного NotebookTools/dist/index.mjs,
не из checkout и не через private acceptance socket. Два инструмента, help API2,
workspace FAAAC405-8EF9-4FB9-9B93-CBD876FA97A4 и исторический terminal v1 run
подтверждены. В отдельной временной тетради через публичный MCP создан ellipse;
read(elementID) → updateElement(label) вернул completed за один start с ранним
emit, 262.9 мс wall времени вызова. Source/frame/style проверены неизменными.
Action 4137338D-A456-4ECE-87FB-0F2E9321E3F7/version
`40f97214ed208340d4c32ee1cffbd3b49b809ed64b546cdbcdf2ae6fa684043d`; полная квитанция хранится
в `.build/mcp-s4-live-20260918/label-result.json`.
После native undo resume вернул побайтно эквивалентный исходный JSON-результат.
Оба тестовых изменения отменены штатно; itemHeader временной тетради вернул null.
Камера не перемещалась; saved подтверждён, received/shown остались awaiting,
показ на физическом iPad этим срезом не заявляется.

Квитанции: `.build/mcp-s4-install-20260918/install.json` и
`.build/mcp-s4-live-20260918/` (точные исходники/UUID каждого run, все запросы,
ответы и длительности). Внешний навык `/Users/amir/.codex/skills/notebook/`
согласован с v2: basis, Snapshot, checkpoint, неизменный результат, справка
по необходимости. Уже работающий sidecar этой задачи остался загруженным v1
и честно получил api_version_mismatch; свежий установленный MCP — v2.
Это не поддержка второго v1 пути и не повод менять данные или доверие пары.
Полный restart/fault/физический lifecycle продолжается в S5; общий release и
системные сравнительные измерения — S10.

## 18 сентября, 03:00 МСК — MCP S5: окна отмены и восстановления (GUI-214, ещё не закрыт)

Воспроизведены два дефекта (`/tmp/notebook-s5-red.log`): отмена во время возврата
committing-журнала ещё допускала native dispatch; старый unfinished v1 run без
общего recovery-index оставлял эффект несверенным до явного resume. Дополнительная
регрессия transient-эффекта (`/tmp/notebook-s5-transient-red.log`) выявила ложный
outcomeUnknown при наблюдаемом факте неотправки. Host теперь закрывает это окно,
записывая notSaved до броска ошибки; Core не допускает переход admitted→committing
после отмены/закрытия run. Принятый native commit по-прежнему может завершиться.
Startup прерывает старые runs и сверяет их ограниченные локальные индексы до IPC,
без повторного кода и полного обхода истории.

15 Codex + 18 Host + 30 Core PASS (`/tmp/notebook-s5-final-core-host.log`).
59 MCP + четыре подписанных Mac/QuickJS/XPC теста PASS: потерянные ответы commit
и undo, повтор key без новой записи, другой payload key с конфликтом, поздняя
отмена принятого commit, cancel/shutdown с задержанным admission. Один physical
UI test на iPad Pro 11 / iPadOS 27: настоящий drag человеческой доработки,
native undo, сохранённые положение и чернила. 0 skips/runtime warnings.
`.build/mcp-s5-verify-20260918`, source
`3bd8260535e46ee4a2e1e39074b7af6af9bc70aeaae1d10f258ff3230bf7b87e`.
Снимки проверены отдельно в `.build/mcp-s5-ui-images-20260918`; это fixture на
физическом устройстве, не утверждение о ручном действии Амира в рабочей тетради.
Первый старт verifier отказал из-за гонки освобождения общего lock, второй
runner не запускался; повтор выполнен после освобождения ресурса.

Подписанная пара `.build/mcp-s5-release-20260918`; установлен только Mac,
manifest `b2fe8d2e72f891aac51954e154052a8ec290a01ee794a80f497e96abfc2ba6b1`.
Свежий установленный MCP: run 851d7f07-fe93-4b53-a197-6d1ea8778600 продолжил
две транзакции после закрытия stdio-клиента. Новое соединение получило оба events
и два saved эффекта; точный повтор start не создал третий эффект, изменённые
args дали run_id_conflict. После обновления Mac terminal result остался тем же.
Все тестовые изменения отменены, временный itemHeader снова null.
Evidence `.build/mcp-s5-live-20260918/` и `.build/mcp-s5-install-20260918/`.

**Открытая интеграция:** установленный iPad другого checkout уже transport v20
(`edb19e5`), а эта ветка происходила от f38416d/transport v16. Поэтому production
пара disconnected; saved честно остаётся отдельно от received/shown. Повторный
запуск существующего iPad и 20 секунд наблюдения не дали соединения; Mac UI
сохраняет доверенный прежний iPad, ожидая его. Номер протокола, Keychain, доверие
и контейнеры не менялись. S5 не объявлен Done: прежде требуется объединение
завершённых peer-коммитов и проверка согласованного Mac, без отката iPad,
изменения чужого worktree или восстановления архивов.


## 18 сентября, 03:08 МСК — согласование SDK v2 с transport v20 и compact UI

Объединены собственные S1–S5 (`daf2cb1`) и завершённая графическая/UI-ветка
`b5fed1e`, merge `4ed881b`. Причина: установленный production iPad уже говорил
по transport v20, а исходная ветка Mac — по v16. Это несовместимость сборок,
не утрата доверия. Графика и compact UI сохранены; SDK v2 использует их shapes,
vertices, radius и longitudinal bend в общем graphicSchema и заново
сгенерированных типах. Ни номер протокола вручную, ни контейнеры/архивы/ключи
не изменялись.

15 Codex + 18 Host + 54 Core PASS; 62 MCP PASS. Интеграционная проверка
`.build/mcp-integration-verify-20260918`: пять подписанных Mac-тестов (четыре
S5 cancellation/recovery и native rounded contour), один physical iPad
`testSharedActionUndoKeepsTheDrawingAndHumanPlacement`; 0 skips и runtime warnings.
Source `c2a785c43696eeec257e52871f020731b8e1a74150daf8abe087ce3734259bc6`. Это ограниченная интеграционная
приёмка, не полный release gate. Подписанная пара строится из этого неизменного
снимка; production Mac ещё не установлен, парная доставка ещё не подтверждена.


## 18 сентября, 03:14 МСК — общий checkout и фактическая граница S5

Mac из `.build/mcp-integration-release-20260918` установлен на прежнее место
`/Users/amir/Applications/Notebook.app`, исходники c2a785c43696eeec257e52871f020731b8e1a74150daf8abe087ce3734259bc6,
manifest a9d771fe9c82aaeeec13f75b4c233581ad46cc1a1214872c9fb4ea7bbe46760d.
Точная подпись/опись проверены до и после атомарной замены; data containers,
идентичности и доверенная пара не менялись. Первый MCP-запрос попал до готовности
IPC и вернул ipc_unavailable; новый процесс после готовности подтвердил API v2.
Production iPad не переустанавливался, открыт существующий b5fed1e. После
ограниченного ожидания и одного restart он остаётся disconnected: исправление
версии протокола было необходимым, но оказалось недостаточным. Discovery
публикует Mac v20, listen socket открыт, доверенный iPad сохранён. Никакого
reset/re-pair/CloudKit toggle не выполнялось. Новые проверочные элементы
`.build/mcp-integration-live-20260918` ещё не создавались. S5 не закрыт: точная
actionVersion после подключения пока не подтверждена.

По явному указанию Амира обе задачи перешли на один checkout и ветку
`codex/notebook-ipad-reliability`. UI-владелец перенёс и сверил свой текущий
patch из worktree; старый worktree очищен только от перенесённых правок.
Один общий Xcode lock сохранён. SDK/TS и graphics/erasure имеют разные
области изменения; общий Core read-контракт согласуется напрямую.

## 18 сентября 2026 — GUI-221: стирание без невидимого выбора, управление связями

Срез исправляет разрыв между маской рендера и исходным hit-test: общий
`NotebookElementAppearance` использует ту же измеренную тесселяцию и нативную
геометрию. Полностью стёртые фигуры не выбираются; частичные доступны по
оставшемуся рисунку, не по прежней пустой внутренности. Undo не удалён и
история не переписана. Индекс масок адресный; прочие тела не загружаются.
Консервативный HTML/text/label envelope не заявляется точной DOM alpha-геометрией.
Агентскому чтению передаётся явное appearance, partial source не равен виду.

В таблетке две компактные графические кнопки вместо крупных стрелок:
прямая/угловая/кривая и концы линии. Реальные цели касания сохранены 44 pt.
Переход маршрута, перемещение середины по двум осям, наконечники и привязки
сохраняются той же командой/Undo. Старые отдельные кнопки удалены.

На общей ветке `codex/notebook-ipad-reliability` выполнен выбранный маршрут
`.build/erasure-connector-s6-final2-20260918`, source
`82bf383f5f5572add5cb06a611ab9ff53faad0375bbf3a409f65c5de158b1332`:
- Core 28 + TypeScript worker 4 PASS; MCP 62, release guards 78, verification guards 79 PASS.
- 100000 предметов: 96 paint-position/successor reads — 7878 SQL VM steps;
  адресное чтение маски одного предмета и отсутствующей маски другого — 114 steps
  при жёстком бюджете 30 rows / 20 KB, без декодирования чужих тел.
- Физический iPad `00008103-001E059934D9001E`: 29/29 PASS, без failures/skips/runtimeWarnings.
  Два UI сценария на листе/доске открывают оба popover, выбирают наконечники,
  меняют маршруты, двигают середину по двум осям, перезапускают приложение
  и проверяют сохранённый тип. Отдельно проверены манипуляция, mesh и picker.
- Native full/partial erasure проходят существующий measured-input receiver
  физического окна, lift, запись, reload и Undo на листе/доске. Это введённые
  тестом UITouch, не реальные движения аппаратного Pencil рукой человека.
  Осмотрены xcresult PNG: стёртый контур отсутствует, Undo восстанавливает его.

Общий маршрут пока **не завершён**: Mac build остановлен на подписи вложенных
TypeScript .d.ts ресурсов. verification.json не создан, рабочая пара не обновлена.
Предшествующий final1 остановился на моей ошибке вложения closure в iPad-коде;
она исправлена перед final2. Нельзя подменять эти неуспехи выпускной квитанцией.
После исправления Mac packaging нужен новый неизменный маршрут и согласованная
установка версии 0.3.82 (85), wire 21 / manifest 7 / derived DB admission 7.

Человеческая проверка Амира, живое новое MCP API2-подключение, десять повторов,
системные frame/CPU/GPU/memory измерения и 30 минут совместной работы не заявлены.
Текущая Codex MCP-сессия удерживает старый API1 sidecar и получает
api_version_mismatch; это не повод обходить публичный протокол или читать SQLite.

### GUI-221 / S6 — финальный допуск сборки, 18 сентября 00:50 UTC

После исправления Mac packaging весь выбранный маршрут завершён заново на
неизменном source `6e7da8839d4a035b11d7c424cccc26c4320bdde65b6dca0c98a5b0b2c04b5d91`:
`.build/erasure-connector-s6-final3-20260918/verification.json`, status passed,
route `./verify.sh:selected`. iPad 29/29, Mac 2/2, runtimeWarnings/skips/failures 0.
Core 28 + worker 4; MCP 62; release guards 79 и verification guards 79 PASS.
100000 fixture повторно: 7878 VM steps для admission 96 предметов, 114 для
двух адресных запросов масок (1 существующий target, 1 без маски).

Два Mac теста действительно исполняли подписанный sandbox compiler; ранние
final1/final2 остаются незавершёнными, их свидетельства не заменены. Начата
сборка общей пары `.build/shared-0.3.82-s6-boundary-release-20260918`.
Временные `com.amirtlinov.notebook.native-test` и
`com.amirtlinov.notebook.uitests.xctrunner` удалены с iPad после проверки;
рабочий `.preview` сохранён и вновь открыт без изменения его данных.

### GUI-221 — установка рабочей пары, 18 сентября 00:54 UTC

Verified Release-пара 0.3.82 (85) из
`.build/shared-0.3.82-s6-boundary-release-20260918/build.json` установлена поверх
допущенных приложений. Mac установлен отдельной согласованной задачей; его
receipt `.build/shared-0.3.82-s6-install-20260918/install.json`, bundle manifest
`4c3020815b8e8605d0117a97ccf740187bf1db0cb29f905884565af0be8f5598`.
iPad `.preview` прошёл strict signature и сравнение artifact manifest
`81fefaf6954885657c4580fa78aaf9b724c1f7ec9e3a0696a51cc34eeb138ebc` перед install.
Бинарник iPad UUID `D406B6C3-08A4-31B3-A6F6-FA6FDB4BDA5A`, CDHash
`3aa6e0328cc048a63952cbee8d98a8ab607ed5c1`.

CoreDevice подтвердил installation, normal launch и readback 0.3.82/build85.
На iPad ровно один Notebook — `com.amirtlinov.notebook.preview`, Notebook Lab;
старое рабочее приложение не удалялось, временные native-test/runner отсутствуют.
Квитанции `.build/gui221-ipad-install-20260918/{artifact,install,launch,apps}.json`.
Контейнеры, ключи, доверие и человеческие записи не заменялись; архивы не читались.
Срез кода `c02a6ba` pushed; SDK-проекция интегрирована `4e92e37`, packaging `8c8d3cb`.

На момент этой записи свежий установленный API2 live-read и ручная приёмка
стирания Амиром ожидаются. Установка не доказывает доставку/показ на другой стороне.

00:55 UTC: новая установленная API2 stdio-сессия подтверждена владельцем SDK,
но runtime Mac/iPad остаётся disconnected. Production fixture не создавался:
до восстановления связи нельзя доказать live-read текущего iPad или shownOnIPad.
Эта диагностика ведётся отдельно, без сброса доверия. GUI-221 — In Review,
Амиру задана проверка ghost selection и кнопок на установленном build85.

### S6 — TypeScript coordinator и публичный контракт, 18 сентября 01:08 UTC

В общей ветке реализован путь durable TS admission → отдельное compiler XPC
соединение → прежний QuickJS → SDK/Core. Исходный язык/код/args и compiler/SDK
pins остаются идентичностью run; retry не перекомпилирует. Подготовка не держит
writer, отмена закрывает переход к JS, source map убирает служебные строки.

RED: `.build/s6-coordinator-red-20260918`, три настоящих native теста завершились
`compiler_unavailable`. После реализации:
`.build/s6-coordinator-green2-20260918/verification.json`, source
`86c6941eeb1d478ff4036d1b4a7c5e503b184d208c02b2c55e008c4fd7788aa2`,
5/5 Mac PASS, failures/skips/runtimeWarnings 0. Проверены одинаковая запись JS/TS
через writer/normalizer, ошибка типа до раннего emit/read, исходная runtime-строка,
отмена подготовки без позднего JS и одновременные TS/markup/настоящий PDF.
При retry недоступные executors не помешали получить первоначальный результат.

Actual CLI/QuickJS и Core/Host регрессии: 42 Swift tests PASS; MCP 62/62 PASS.
Отдельно прошли все семь ресурсных fences CPU/RSS/temp/wall/diagnostic/JS/map:
тесты сужают пороги внутренним параметром того же CLI-пути, RPC не принимает
пользовательские limits/paths/config. Проверены завершение реально запущенного
PID и уборка временного каталога. RSS/CPU наблюдаются выборочно, это не kernel
high-water измерение. EOF-диагностика ограничена строками исходника. Бюджет
компактной transaction-схемы в Swift приведён к уже существующему MCP-бюджету
25 КиБ: 24343 UTF-8 байта / 24611 с Foundation slash escaping, а не регрессия API.

Публичный language transport сначала отверг TS (`Unrecognized key: language`),
после изменения передаёт точный язык и отвергает неизвестный до IPC. JavaScript —
документированный default; эвристики и TS→JS fallback нет. Схемы/справка обновлены.

Это **проверка исходников, ещё не установленная S6-возможность**. Установленная
пара 0.3.82(85) и отдельный UI snapshot 0.3.83(86) содержат лишь ранее подписанную
compiler-границу. S6 ждёт согласованной установки и installed MCP end-to-end.
S5 production delivery также открыт: fresh installed API2 работает, но runtime
остаётся disconnected. Production iPad85 watchdog в Core appearance/CGPath
записан отдельно владельцем GUI-221; эта запись не объявляет его исправленным.

### GUI-222 — номер страницы на бумаге, 18 сентября

У нижнего счётчика удалены подложка, рамка и тень. Номер набран небольшим
книжным шрифтом, стрелки уменьшены; сохранены положение, исходная область
hit testing, кнопки 44 pt, список страниц и прежний владелец навигации.

Физический iPad: `testCompactPageControlsKeepFullTargetsAndOpenOverviewAndSearch`
прошёл 1/1 без failures/skips/runtimeWarnings. Проверены нажатия у края кнопок,
переход через миниатюру, возврат 3 → 2 → 1 и поиск; осмотрен `paper-page-folio`.
Квитанция `.build/gui222-folio-verify3-20260918/verification.json`, source
`1af001518082f610d55a72958d39916c692ca065f99f19a11f9bb2ad5b0594c5`.
Это узкий UI-сценарий, не полная приёмка. Снимок выпуска — `b584f24` плюс только
NavigationView, UI-снимок и версия 0.3.83 (86); параллельный S6 `1f22681` сюда
не включён. Опись — `.build/gui222-folio2-provenance.json`.

Первый проход прерван watchdog **фонового рабочего .preview 0.3.82 (85)**,
не тестового приложения: `AgentOverlayView.body` → `NotebookElementAppearance`
→ CGPath/Clipper на main, FRONTBOARD scene-update 10 секунд. Crash сохранён в
`.build/gui222-folio-visuals-20260918/0D2F965D-0644-4569-9D4D-803A91A24D51.ips`;
эта отдельная production-проблема GUI-221 не исправлена данным оформлением.
Второй проход поймал пропуск краевого нажатия без прежнего родительского
contentShape; он возвращён перед финальной успешной проверкой. Неуспешные
свидетельства сохранены, ни один из них не выдан за PASS.

Verified Release `.build/gui222-folio-release-20260918/build.json` установлен
поверх iPad `.preview`: CoreDevice подтвердил 0.3.83 / build86 и обычный launch.
Bundle manifest `48506a0152c248cb948443ab352df7e19ef320e208be0ddd6e2c3c42120778de`,
UUID `B1209CCE-61E4-3459-9142-7514BC8B6EBB`. Квитанции установки —
`.build/gui222-ipad-install-20260918/`. На устройстве один Notebook Lab;
временный native-test и XCTest runner удалены. Рабочий контейнер, ключи и
содержание не удалялись и не заменялись. Ручная оценка нового оформления
Амиром ещё не получена; full/30-минутная приёмка этим срезом не заявлены.

### GUI-221 / MCP — независимая регрессия сложной маски, 18 сентября 01:18 UTC

`NotebookAppearanceComplexityTests` воспроизводит повторный проход eraser по
маленькой области одного прямоугольника, 256/1024/2048 samples. Это синтетический
Core-сценарий, не захваченная траектория Амира. До исправления общего владельца:
`.build/appearance-dense-red-20260918`, 2048 samples — **13.388913 s**, RED по
верхней границе 1 s. Partial/selection оставались правильными; процесс сам
завершился exit1, kill0. Это воспроизводимая причина риска scene watchdog,
не доказательство всех причин отсутствующей связи.

После bounded-batch/balanced-union исправления `NotebookElementAppearance`
независимый повтор того же fixture: `.build/appearance-dense-green-20260918`,
256 — 0.001459 s, 1024 — 0.003741 s, 2048 — **0.007688 s**. Все три case PASS,
kill0; прежний RED сохранён. Дополнительно 11 addressed/incremental observation
тестов PASS, включая fully erased → outOfScope, адресный источник и undo.
Owner/fixture проверены неизменными во время повтора; физическая приёмка и
установка общего source с S6 ещё впереди. Эти числа не являются FPS или
измерениями жеста на iPad.

### GUI-221 — нормализация маски без блокировки сцены, 18 сентября 01:30 UTC

`NotebookElementAppearance.erasurePath` больше не передаёт все перекрывающиеся
треугольники одного длинного контакта единой boolean-операции. Те же измеренные
треугольники нормализуются ограниченными пакетами и объединяются сбалансированно.
Соседние пакеты делят исходный треугольник: это не расширение ластика, а защита
от численного зазора при независимом округлении CoreGraphics. Нет прореживания,
area-threshold для объявления пустоты, растеризации или второго UI/MCP пути.

Неизменный финальный source
`043c3f6be081d7064c322bfe2ae78add62e1bf89e2ad008f2c0d4619141d125e` прошёл
`.build/appearance-s6-final3-20260918/verification.json`, selected PASS:
Core 26 + TypeScript worker 6, MCP 62; физический iPad 6/6, Mac S6 5/5,
failures/skips/runtimeWarnings 0. Плотная синтетическая маска 2048 samples —
9.639 ms вместо 13.389 s прежнего владельца; это не FPS и не системная трасса.
Oracle сравнивает покрытие с отдельными Metal-треугольниками, включая
самопересечения, разную ширину, повторы, масштабирование и несколько границ пакетов.

На физическом iPad проверены partial/full/dense стирание на листе и доске,
публикация после lift, reload и одна причинная Undo. Dense-контакт содержит
2049 введённых тестом UITouch через существующий measured-input receiver;
снимки сцены укладываются в проверяемую границу 1 s. Это не аппаратный Pencil
рукой человека. Осмотрены сохранённые снимки частичного и полного стирания.

Первый gate выявил настоящий зазор без перекрытия пакетов; assertions не
ослаблялись. Второй подтвердил все 6 native-сценариев, но старый UI-тест не
создал чернила: finger→Pencil adapter намеренно разрешён только в Simulator,
который не запускался. Admission физических касаний не менялся ради теста.
В final3 выбраны непосредственно затронутые native-сценарии; оба неуспешных
gate сохранены. Ручная приёмка Pencil и живое чтение нового iPad через Mac
ещё ожидаются. Общая версия 0.3.84 (87) собирается отдельно из этой квитанции.

01:32 UTC: выпускной допуск получен новым неизменным проходом
`.build/appearance-s6-final4-20260918/verification.json`: тот же source,
те же Core/MCP и 6 iPad + 5 Mac PASS. `checked_verification` отдельно подтвердил
пригодность квитанции. Final3 имел успешные тесты, но сборщик правильно отверг
старую базу `b584f24`, включавшую уже принятый folio UI без выбранного UI-теста.
В final4 база — принятый `431dc65`, а S6 по-прежнему явно покрыт пятью Mac
тестами. Квитанции/валидатор не исправлялись задним числом; исходники не менялись.

01:36 UTC: общий verified Release 0.3.84 (87) установлен поверх рабочего iPad
`.preview` и запущен обычным launch. Сборка —
`.build/shared-0.3.84-s6-release-20260918/build.json`; iPad manifest
`407217ce685682a973347580fbc9b5eeedeee0734627fca417d440c80467cb9a`, binary UUID
`79316848-995C-35CF-B7C0-6C939FF00EE1`. Проверены подпись и точное совпадение
manifest перед установкой. CoreDevice readback подтверждает 0.3.84 / build87;
на устройстве один Notebook Lab, временные native-test и runner удалены.
Квитанции — `.build/appearance87-ipad-install-20260918/`. Рабочий контейнер,
тетради, ключи и идентичность не удалялись. Номер страницы без панели сохранён.
Ручная проверка аппаратным Pencil запрошена; ответа ещё нет. Установка сама
по себе не доказывает LAN-доставку или живое чтение агентом.

### S6 — установленный публичный TypeScript, 18 сентября 01:38 UTC

Общая подписанная пара **0.3.84 (87)** построена после допущенного final4:
`.build/shared-0.3.84-s6-release-20260918/build.json`, source
`043c3f6be081d7064c322bfe2ae78add62e1bf89e2ad008f2c0d4619141d125e`.
Mac установлен атомарно в `/Users/amir/Applications/Notebook.app` после graceful
завершения только canonical PID9423 и drain: `.build/shared-0.3.84-s6-mac-install-20260918`.
Manifest `b52a295ed7b9b3ea54a3a82ecd6f22b7f68f72f2b7cac3047d216a08012501af` совпал
до/после установки; strict signature PASS. Контейнеры, ключи, trust не заменялись.
Квитанция физического iPad87: `.build/appearance87-ipad-install-20260918`.

Fresh stdio именно **установленного** `NotebookTools/dist/index.mjs`:
`.build/s6-installed-public2-20260918/receipt.json`, PASS, ровно два инструмента.
Валидный TS с типами/args/адресным чтением завершился первым ответом за 163.61 ms;
повтор того же run — 3.97 ms, первоначальные result/events/pins неизменны.
Изменённый язык под прежним ID дал `run_id_conflict`. Type error в строке3 —
`typescript_diagnostic`, events/effects пусты (64.42 ms). Runtime error сохранил
исходную TS строку3 (117.96 ms). JS дал тот же read-result (66.26 ms).
Compiler `7.0.2`, SDK `c9623a73526938be057961005454be0bea5ca72ecfd5910b1552f572db4147ea`.
Первая попытка попала в ещё не готовый IPC сразу после launch; её evidence
`.build/s6-installed-public-20260918` сохранён. Повтор использовал **тот же UUID,
код и args**, а не второй эффект. Доменное содержание этим proof не изменялось;
эквивалентность записей JS/TS отдельно проверена пятью signed native tests.

Обновлены установленный `/Users/amir/.codex/skills/notebook/SKILL.md` и его
`references/tool-map.md`: явный язык, строгая проверка до эффектов, исходная
идентичность/диагностика и отсутствие повторной компиляции. Frontmatter/ссылка
проверены Ruby YAML; bundled quick_validate недоступен в системном Python из-за
отсутствия PyYAML, зависимости ради текстовой правки не устанавливались.

Границы: текущее ранее загруженное подключение Codex всё ещё объявляет API1 —
это не fresh installed sidecar. Legacy fallback не включался. После запуска
обоих87 отдельное `after-ipad.json` снова показывает **disconnected**. Следовательно,
S6-компиляция/исполнение установлены и доказаны, но S5 production delivery,
реальное выделение S7, физический Pencil и полная приёмка S10 не объявлены готовыми.

### GUI-223 — общая таблетка выбранного объекта, 18 сентября 02:11 UTC

Карточки тетради, документа и доски используют тот же `NotebookSelectionControlsView`,
что элементы и фигуры: одна поверхность, экранный размер, размещение и исключение
касания из ввода холста. Отдельная круглая кнопка удаления удалена. Карточкам
доступны «Открыть» и «Удалить»; неподдерживаемые настройки фигуры не добавлены.
Перенос остаётся у `WorkspaceItemPose`, запись/удаление — у существующей модели.
Действия проверяют поколение выделения, чтобы завершение удаления старого объекта
не снимало новое выделение. Для карточек не создаются фиктивные resize-ручки.

Финальный selected gate `.build/gui223-capsule-verify7-20260918/verification.json`
прошёл **8/8 на физическом iPad**, failures/skips/runtimeWarnings 0: четыре native
проверки общего компонента и четыре UI-сценария. Проверены выбор и открытие тетради,
удаление из стопки, long-press перенос, палитра и контекстное меню фигуры. Native
проверка покрывает все три вида карточек, обычный/выходящий за экран размер,
44-point targets и возврат к контролам треугольника. Осмотрены реальные снимки
общей таблетки и меню. Это не ручная Pencil-приёмка и не полная приёмка приложения.

Предыдущие неуспешные evidence сохранены: расширенный Create-сценарий упёрся в
доступность системного submenu; отдельный three-card fixture остановился ещё
до выбора объекта на ожидании ресурсов изображения. Эти сценарии не объявлены
исправленными. Повтор палитры выявил ошибку её подготовки: безусловный перенос
уже перемещённого companion становился zero-distance tap и открывал чат. Теперь
тест двигает его лишь при пересечении фигуры, сохранив прежние проверки палитры.
Verify6 уже прошёл те же восемь тестов, но сборщик правильно отверг неточную
ручную классификацию его metadata. Verify7 заново выполнил их на неизменном
source с обычной классификацией выбранного delta; receipts/validator не менялись.

Release **0.3.85 (88)** построен из `f80a6f7` и только шести файлов этого среза,
без параллельных незавершённых S7-правок. Source
`af637763528c2ef90ab5b288695058cd0bf5c11821816ff78729113c5ebeb1ee`, verified pair:
`.build/gui223-capsule-release-20260918/build.json`. iPad manifest
`afcf21f31bf97ae65c638479999c704a3d8c3f9041221db151ae4e952ffa603d`, binary UUID
`BD723F60-99D5-38B6-B178-85A6A9C6597D`; Mac manifest
`b3631b66a30ae21b03b2454c88f1191a69c1b58fe85c93cf6ccf2031f3f7bc6a`.

Оба приложения установлены и запущены. CoreDevice readback подтверждает единственный
Notebook Lab `.preview`, 0.3.85 / 88. Удалены только isolated native-test и runner;
рабочий iPad обновлён in-place. Mac заменён атомарно после graceful drain, manifest
совпал с проверенной сборкой, старый bundle сразу удалён. Квитанции:
`.build/gui223-ipad-install-20260918/` и `.build/gui223-mac-install-20260918/`.
Рабочие базы, ключи, trust и идентичность не заменялись. Живое соединение пары
и пользовательская оценка этой таблетки не выводятся из успешной установки.

## 18 сентября, 05:18 МСК — GUI-216 / S7: настоящее выделение и источник сообщения

Единственным владельцем выбора остался `NotebookSelectionSession`. AppModel
публикует его точный физический адрес, session/generation и доступность сцены
через заменяемый слот существующего authenticated transient transport. Камера,
режим редактирования и повтор того же выбора не создают новые поколения.
Неактивная сцена публикует unknown, не сбрасывая selection, камеру или принятый
Pencil. Mac сохраняет публикацию существующей очередью; disconnect/startup
делают её неизвестной. Старое соединение/поколение не восстанавливает выбор
после clear. Runtime-запись не реплицируется и не двигает content cursor.

`read({kind:"selection"})` различает known-empty и unknown; basis у этого чтения
пустая, права записи оно не даёт. `observe()` адресно читает выбранный элемент,
включая элемент после первых 32. Explicit target не подменяется средой.
Исторический contextID больше не заимствует текущие target/basis/пиксели;
attention сохраняет прежние reference/hash либо явную недоступность изображения.
Current-view receipt допускается только для известной активной поверхности
и совпадающих версий. Схема, help и d.ts генерируются прежним маршрутом.
Wire **22**, manifest **7**; это требует согласованного обновления обеих сторон,
но не смены ключей, доверия или формата пользовательского содержания.

RED сохранён в `.build/s7-contract-red-20260918/`: отсутствовало чтение selection,
исторический observe подмешивал текущую камеру/основание. Дополнительные RED:
`/tmp/notebook-s7-session-red2.log` — runtime-публикация двигала content cursor;
`/tmp/notebook-s7-scene-image-red.log` — неизвестная сцена выдавалась за pending.
Первый native gate `.build/s7-selection-native-20260918/` не компилировал новый
тест: он пытался менять immutable presence/camera. Исправлена только подготовка
теста, не ослаблены проверки; неуспешное свидетельство сохранено.

Финальный selected gate `.build/s7-selection-native2-20260918/verification.json`
прошёл на неизменном source
`406ab21290cb178bf1fa259283e9633691c0f99098460d486ab0d925913adf8a`
поверх общего `92161db`: **26 Core/Host, 62 MCP, 6 physical-iPad, 2 signed-Mac**.
Native failures/skips/runtimeWarnings — 0. В compile log есть три прежних
предупреждения `UIWindow(frame:)` в DocumentProgramOverlayHostTests и сообщение
SwiftCompile с exit 0; все восемь запрошенных native/UI тестов действительно
исполнены, что проверено по xcresult, а не по тексту stdout.

Физический iPad проверил owner→clear→surface→reselect, сохранение Pencil/camera
при потере доступности, настоящий TLS transient lane и UI смены выделения.
Подписанный Mac проверил writer/IPC fence и TS→observe→изменение подписи именно
40-го элемента, не первого, с одним сохранённым эффектом. Это изолированные
сценарии, не доказательство production received/shown и не ручной Pencil-тест.
Симуляторы, архивы, удаление рабочих баз и сброс пары не использовались.
Проблемы навигационного зума/случайного выхода (GUI-199) этим срезом не исправлены.

Release **0.3.86 (89)** с тем же source установлен поверх обеих рабочих сторон:
`.build/shared-0.3.86-s7-release-20260918/build.json`. iPad manifest
`717e0d40ffed818c5719e17315cb7784c78f45d9f77b40f0848d723b8e08a802`,
binary UUID `46072225-5754-314D-B8E7-ACF85A138C57`; Mac manifest
`497ac49df12b4fb260073f2555a06eebd57d74bef5fd702e156d3af0d82a448f`.
Install/readback: `.build/shared89-s7-ipad-install-20260918/` и
`.build/shared-0.3.86-s7-mac-install-20260918/`. На iPad единственный рабочий
Notebook Lab 0.3.86/89; удалены только isolated native-test и runner. Mac штатно
дождался drain и заменён атомарно; manifest/подпись совпали, старый bundle удалён.
Контейнеры, ключи, trust и пользовательские архивы не менялись.

Установленный публичный MCP проверен отдельно в
`.build/s7-installed-public-20260918/receipt.json`: ровно два инструмента,
read-selection с пустой basis, observe, приоритет explicit target, типизированный
readonly TS и повтор того же run без нового чтения/эффекта. Первый TS-ответ уже
completed; compiler 7.0.2, SDK
`d2904fecb1a0807092ba7204c8b5e0a2d14d7c129d5039ae9eac4eb439f484f0`.
Навык Notebook обновлён под установленный контракт; удалена противоречивая старая
фраза о недоступности исполнения TS. Текущее подключение этой задачи ещё имеет
старый tool-schema, поэтому проверялся свежий stdio именно установленного bundle,
не прямой SQLite/helper обход.

**Граница:** production runtime после установки сообщает disconnected, selection
честно unknown. Наличие доверенной пары не доказывает живую доставку. Физический
production select/clear/reselect через это соединение и received/shown остаются
неподтверждёнными; S7 не закрыт. Публичная проверка не меняла содержание.

### GUI-224 — устойчивый ввод и цельная файловая панель, 18 сентября 02:30 UTC

`NotebookChatPanel` оставляет composer отдельной полноширинной строкой: файлы
занимают только правую часть области чтения, а не меняют ширину/перенос текста
в редакторе. Вертикальная граница соединяет общую шапку с полной границей ввода.
`NotebookProjectFilesView` использует общий chrome и выделение строк, постоянный
заголовок и 44-point targets, без обрывающегося внутреннего divider.
Крестик вызывает прежнее сворачивание, не удаление чата. Настройки компьютеров
и проектов перенесены в существующее меню шапки; лишняя кнопка возле «Чаты /
Проекты» и отдельный самодельный popover удалены. Владельцы draft, file window,
терминала и записи не менялись.

`.build/gui224-chat-verify2-20260918/verification.json`: **8/8 PASS на физическом
iPad**, failures/skips/runtimeWarnings 0. Пять native-сценариев покрывают обычный,
узкий/короткий чат, проекты, файлы и approval. Toggle файлов сохраняет точные
координаты/размеры и identity редактора. Три UI-сценария проверяют настоящий
keyboard + draft + toggle/collapse/reopen, перенос/resize/настройки окна, открытие,
редактирование и повторное открытие файла; геометрия бумаги и чернила неизменны.
Осмотрены screenshots обычного/компактного чата, файлов, approval и клавиатуры.
Первый gate сохранил 7/8 PASS: новое системное меню показывало правильные пункты,
но UIKit не экспортировал старые accessibility IDs действий. Проверка теперь
нажимает видимые названия; assertions открытия истории/настроек не ослаблены.
Production-код между gate1 и gate2 не менялся. Негативный xcresult сохранён.

Проверенный source `98147ba35b070051ce00172d3ef31dc11f8078aab5f1102bc7a29aeea45f56c0`
(база S7 `cb9886c`) выпущен и установлен как **0.3.87 (90)** на Mac и iPad:
`.build/gui224-chat-release-20260918/build.json`. iPad manifest
`f193ec16cd49543d2604ee3ec60f3f0bbad81cbc89815a454217ccf32424d6b8`, binary UUID
`2AC64A46-3017-36E2-A63A-5E3D918D628A`; Mac manifest
`c558a96f99cba4528365c17eea1bdde5d10e89b187841c2d81851f21d86b38d1`.
Readback: один Notebook Lab `.preview` 0.3.87/build90. Mac заменён атомарно после
graceful drain, iPad обновлён in-place и оставлен в foreground; test app/runner
и старый Mac bundle удалены, рабочие контейнеры/ключи/trust сохранены. Квитанции:
`.build/gui224-mac-install-20260918/` и `.build/gui224-ipad-install-20260918/`.
Это выборочная приёмка chat UI, не доказательство LAN/CloudKit/Pencil или полной
приёмки приложения; пользовательская оценка нового оформления ещё ожидается.

## 18 сентября, 05:41 МСК — S7: Nearby discovery, пара 0.3.88 (91)

После S7 и GUI-224 installed 0.3.87 (90) оставалась `disconnected` более
45 секунд foreground (`.build/s7-on90-public-20260918/receipt.json`). Проверка
живого NearbySync обнаружила три самостоятельных дефекта: NWBrowser использовал
стандартные TCP parameters без peer-to-peer, хотя TLS transport включает эти
интерфейсы; `.waiting` не сообщал причину; callback завершённого browser мог
опубликовать ошибку после перезапуска владельца.

Все три регрессии исполнились и упали на физическом iPad:
`.build/discovery91-red2-20260918/ipad.xcresult`. Первая попытка
`.build/discovery91-red-20260918` остановилась на ошибке Int → Int32 в новом
тесте; она не считается поведенческим RED. Исправление использует тот же
NWBrowser и владельца NearbySync: peer-to-peer параметры, browser/lifetime
fence для state callbacks, обработка waiting/failed, точное сообщение при
DNS policy denial. Версия wire, идентичности, trust и ключи не изменены.
Две info-точки существующего Logger показывают готовность discovery и число
совместимых/несовместимых доверенных peers, не содержание или credentials.

Выбранная проверка `.build/discovery91-green-20260918/verification.json`:
**19 физических iPad + 1 signed Mac**, 0 failures/skips/runtime warnings.
Проверены NearbySync (включая credential lifecycle и framing), настоящий
TLS selection transient и существующий Mac writer/IPC с fencing старого
соединения. Это не полная приёмка Notebook и не системная UI/performance трасса.
Неизменный source:
`d26d0c7160f644c41c4e8b39d811a04cc800f88453ed21933a44504a22017cfa`.
Signed Release: `.build/shared-0.3.88-discovery-release-20260918/build.json`.

Установлена **0.3.88 (91)**, Mac → iPad, обычным in-place обновлением:

- Mac UUID `A2A9A166-5598-3D99-9D17-E785DB1B6AD9`, manifest
  `aa582c644c255ffcbb50dd261f998d308d1dd07f16d2665e5bd8a330b71399e7`;
  `.build/shared-0.3.88-discovery-mac-install-20260918/install.json`.
- iPad UUID `D53804AD-1C11-33C5-8695-D3750228CA35`, manifest
  `67c1c49be17b1a35bc139df9392a066c4220581384aec948c071de379c0471b3`;
  `.build/shared91-discovery-ipad-install-20260918/`.
  Readback подтверждает единственное рабочее приложение `.preview`; удалён
  только отдельный native-test bundle. Контейнеры, архивы и сопряжение не сбрасывались.

Рабочий iPad запущен foreground через обычный devicectl с native console
(без terminate-existing, fixture/env root). Начальное и повторное после 45 с
чтения установленного публичного MCP:
`.build/s7-on91-public-20260918/receipt.json` и
`.build/s7-on91-settled-public-20260918/receipt.json`.
Два tools, readonly TypeScript 7.0.2 с актуальным SDK, законченный первый
ответ и повтор исходного run PASS; доменных изменений нет. **Соединение всё
ещё disconnected, selection unknown.** Причина рабочего разрыва не установлена;
исправленные discovery-дефекты не объявлены его доказанной причиной.
S5/S7 received/shown и физический select → write пока не приняты.

Native console дополнительно показала
`SCENE_COMPOSITION_FAILED ... revision=656 error=snapshot_pending: native_ink_frame`.
Это передано владельцу GUI-199 как наблюдение, а не диагноз жалобы Амира.
Ненадёжное открытие щипком, нежелательный выход при зуме внутри тетради и
зависание листания остаются открытыми UI-дефектами. Этот сетевой срез их не исправляет.

## 18 сентября — GUI-199: готовность возвращаемого листа и foreground

При обратном перелистывании `UIPageViewController` сохранял свой shell без
окна, а его `UIHostingController` оставался дочерним. `onDisappear` содержимого
снимал render readiness, но `prepareContent` принимал только child без parent.
Возврат ожидал кадр, который не мог подготовиться вне окна. Контроллер теперь
возвращает **тот же child** в существующее окно подготовки после фактического
`viewDidDisappear`. Переданный UIKit будущий лист до его появления не забирается
обратно только из-за `window == nil`. Shell identity, четыре живых содержимых,
причинная запись и данные страницы не менялись; таймеров повторного листания нет.

Второй путь пустого экрана: inactive scene начинала подготовку native ink,
требующую foreground window. На установленной 91 наблюдался
`snapshot_pending: native_ink_frame`. Foreground admission теперь наблюдаемый
общий допуск модели, а не ignored-флаг только optional document shell.
Деактивация отменяет незавершённый кандидат, сохраняя опубликованную композицию;
возвращение запускает тот же запрос через прежний SwiftUI task.

Поведенческие RED на физическом iPad: foreground admission —
`.build/gui199-page-turn-baseline3-20260918/`; возврат снятого child —
`.build/gui199-offscreen-red-20260918/`. Native fixture теперь снимает readiness
вне настоящего окна вместо вечного `hasFrame`. Проверка bounded identity
разрешает тому же child находиться в prewarm или shell и требует его точного
возврата в исходный shell. Это не разрешение заменять содержимое.

Новая UI-фикстура содержит шесть сохранённых страниц с чернилами и отдельными
цветными HTML-маркерами. Проверяются реальные кнопки и свайпы вперёд/назад,
пиксели нужного маркера, геометрия/содержание чернил и Home → foreground.
Промежуточный OCR пропускал даже явно видимое `FIFTH` (подтверждено осмотром
изображения и отдельным Vision-запуском). Его заменяет существующий pixelShare
на уникальном цвете содержимого, не чтение model counter. Промежуточные
xcresult сохранены и не являются свидетельством готового выпуска.

Выбранный финальный gate
`.build/gui199-page-turn-green4-20260918/verification.json`: **30/30 PASS**
на физическом iPad, 0 failures/skips/runtimeWarnings: 22 PageTurnSelection,
5 PagePresentation и 3 UI-сценария. Новый сценарий завершил 20 переходов
(10 кнопками, 10 свайпами) с двумя Home → foreground; документ прошёл
1 → 2 → 3 → 2 с совпадением видимых разделов при возврате. Осмотрены изображения
обратного перехода 6 → 5, первого листа после background и возвращённого
документа. Экспорт изображений находится отдельно от неизменной квитанции:
`.build/gui199-page-turn-visuals-20260918/`.

Проверенный source
`e7df0347c25127b1f1a3b00cf7ab0565adb5d419109e82f75345492de6886fc2`
собран в подписанную пару **0.3.89 (92)**:
`.build/gui199-page-turn-release-20260918/build.json`.
iPad UUID `B040E18F-5A0C-31CD-9379-A99D1A424BC3`, manifest
`05790b6cf4a20ffdf73c50abdd58cc5f02c3348e7d68c7d6e26751a356558d62`;
Mac UUID `4E5E7C5C-B83D-3311-A1CE-C5570CFBF009`, manifest
`3a166809a1ce42208ab8eaf4f473456bb0d02c18d6cf1838873d888874b8bdf6`.

Установлена пара 92: Mac заменён атомарно после graceful drain, старый bundle
удалён; iPad обновлён in-place и запущен без fixture/environment overrides
(PID 4750). Readback подтверждает единственный `.preview` Notebook Lab
0.3.89/build92; изолированные native-test и UI runner удалены. Квитанции:
`.build/gui199-mac-install-20260918/install.json` и
`.build/gui199-ipad-install-20260918/{artifact,install,launch,apps}.json`.
Содержимое, контейнеры, ключи и доверие пары не сбрасывались.

Пользователю предложено повторить сценарий на своём содержимом установленной
92; ответ ещё не получен. Это выборочная физическая приёмка листания и возврата
в foreground, не 30-минутная полная приёмка и не доказательство исправления
отдельного pinch/нежелательного выхода из листа. GUI-199 остаётся открытой.

Граница начальной диагностики установленной 91: встроенный обработчик
прерываний XCTest автоматически нажал «Разрешить» на системном запросе локальной
сети при попытке открыть меню приложения. Явного разрешающего шага в тесте не
было; requester bundle по имеющемуся activity log не установлен. Инцидент
передан владельцу сетевого среза, пользователь уведомлён там; повторный доступ
или сброс разрешений здесь не выполнялись. Диагностика рабочего UI с системным
alert должна остановиться до первого tap, а не полагаться на default handler.

## 18 сентября 2026 — S8: адресное основание полного предмета

В общей ветке поверх `bd7303d` готов read/basis-путь `itemLifecycle`, не весь S8.
Чтение возвращает заголовок, фактический parent/cover и frozen lifecycle basis без
декодирования всех страниц. Индекс raw record hashes обновляет единственный
`writeFragment/removeFragment`; source/state/ink и причинные поля входят в extent.
У child board дополнительно учитывается raw content identity, без изменения
исторического смысла cover pixels. Нормальный `itemHeader` не выдаёт это основание.

TDD и независимое ревью выявили и закрыли: незамеченную правку дальнего листа;
неподдержанный публичный read/утерю lifecycle-компонента при merge; позднее присоединение
ранее записанных document bodies; ошибочную принадлежность orphan document одноимённой
тетради; невидимые tombstones child board; повторный проход миграции от начала файла.
При schema admission обнаружено также ложное продвижение read cursor от новых derived
rows: теперь admission продвигает его только при реальной shared publication.
Старые проверки current-schema `4`/unknown-schema `5` заменены обращением к единственному
владельцу версии. Локальная схема — 8; wire/content, ключи и идентичности не менялись.

Выборочная квитанция: `.build/s8-extent-selected-20260918/verification.json`, PASS.
Exact source: `7ae2d4a27d27b5f693b6dbf662668b235df55334f9df9fbec3f76932843cca94`.
Исполнены **50 Core tests / 8 suites**, **62 MCP tests** и generated schemas/types check;
source-before/source-after совпадают. Core занял 248.849 s, включая подготовку 100000
настоящих страниц; это не задержка адресного чтения. Lifecycle этой тетради прочитан
в allowance 80 rows / 32768 bytes / 8192 bytes per value. Native append после100000
страниц: **6950 SQLite VM steps, 13 changed addresses**, count100001, один новый UUID.
Отдельная SQL-metadata нагрузка100000 rows: чтение порций256 на началах0/50000/99000
стало **3862/3869/3869 VM steps** вместо **3868/553868/1092868**. Эта нагрузка проверяет
алгоритм seek, а не выдаётся за полноценный документ. Повреждённое непрочитанное тело
в изолированной фикстуре не мешает заголовку и admission7→8; read/delivery cut сохранён.
Настоящие RED, отдельные compile-only ошибки и область проверки записаны в `red-notes.json`.

В этом срезе **не запускались native/UI runners, не менялась установленная пара**.
MCP проверялся с изолированным `NOTEBOOK_HOME`. Публичных domain operations по-прежнему20:
общие delete/append, compact inverse/delivery и causal undo ещё в работе GUI-217.
S8/S9/S10 и полная физическая приёмка не закрыты.

## 18 сентября 2026 — GUI-199: камера раскрытой бумаги и допуск double tap

После отдельного исправления листания 92 проверен связанный отзыв о щипке:
обложка приближалась без открытия, а движение внутри листа начинало его закрывать.
`SpatialWorkspaceView` ошибочно переводил каждый отсчёт в `.cover`, ограничивал
увеличение fit и при отпускании возвращал камеру в fit. Первый крупный отсчёт
мог назначить начало открытия после его конца. Теперь раскрытая бумага сохраняет
режим, якорь и достигнутый масштаб; вход/выход используют один геометрический
интервал ниже coverScale. Увеличенный лист отдаёт движение камере, не curl;
явные команды folio остаются доступны. Формат содержания и Core не менялись.

Native RED `.build/gui199-paper-camera-red-20260918/` воспроизвёл 3 дефекта.
Промежуточный UI RED оказался ошибкой XCTest: pinch всей страницы ставил один
палец на «Назад». Проверки теперь касаются видимого содержимого; предложенная
правка UIPageViewController полностью удалена. Последующий gate 33/33 прошёл,
но просмотр его кадров обнаружил реальный pinch → редактор исходника. Та
подписанная промежуточная пара **не устанавливалась**.

У `document-shell.html` оба pointerup считались двумя тапами независимо от
движения/второго пальца/отмены. Единственный существующий допуск редактора теперь
проверяет законченные одиночные контакты; touch compatibility dblclick не
создаёт второго действия. Мышиный double-click сохранён. Дискретные отрицательные
проверки дали RED до изменения и PASS после; добавлена физическая положительная
проверка double-tap → клавиатура → изменение → сохранённый текст.

Финальный неизменный gate:
`.build/gui199-paper-input-final-20260918/verification.json`, source
`10716be0a1537138f67db8e11de7f072d85077e4fb2a10b7e474be464b9f0e56`.
**52/52 iPad** (45 native + 7 UI), **30/30 Mac DocumentRuntime**, **13/13 browser
contracts**, без failures/skips/runtime warnings. Проверены удержание увеличения,
малое уменьшение, явное закрытие/повторный вход, частичный изгиб, листание обоих
видов бумаги и редактирование. Кадры документа без редактора после щипка,
увеличенного листа и действительно сохранённого текста осмотрены отдельно:
`.build/gui199-paper-input-visuals-20260918/`.

Подписанная пара **0.3.90 (93)** собрана из этого source:
`.build/gui199-paper-input-release-20260918/build.json`.
iPad UUID `953694D7-4DEE-3F37-905E-A0509B81051D`, manifest
`9be2f8ab4507c954c7f7c82946dd60cb00798b8518e0ffae5b14b48f4b8e708a`;
Mac UUID `3D34844E-6A12-3833-A4DE-75E63F39C5DC`, manifest
`618cde2ce9abcbcba2b6bd6f0eaa40630fabe2ed343907f51a02698ee820c26f`.
Mac заменён после graceful drain атомарно, старый bundle удалён. iPad обновлён
in-place и запущен без fixture overrides; readback подтверждает только один
Notebook Lab `.preview` версии 0.3.90/build93. Native-test и UI runner удалены.
Квитанции: `.build/gui199-input-mac-install-20260918/install.json` и
`.build/gui199-input-ipad-install-20260918/{artifact,install,launch,apps}.json`.
Рабочие данные, контейнеры, ключи, доверие и системные разрешения не сбрасывались.

Это выборочная проверка, не полная физическая приёмка. Ручной ответ Амира на 92/93
ещё не получен. Холодная подготовка документа остаётся асинхронной; отсутствие
любой загрузки на произвольном содержимом не доказано. Плотность растров выше fit,
системные кадры/CPU/GPU/память и 30 минут совместной работы здесь не измерялись.
GUI-199 остаётся открытой до пользовательского подтверждения.

## 18 сентября 2026 — GUI-225: компактные области выбора, физический UI ожидает допуска

Отзыв Амира на 0.3.90 (93): тап рядом со стрелкой/фигурой не снимал выделение.
В `NotebookAttentionProjection` контур имел лишние 12 экранных пунктов;
`NotebookSelectionControlsView` занимал квадраты 44×44 вокруг маленьких ручек.
Без движения pan ничего не делал, но общий выбор уже не получал этот контакт.

Уменьшен общий допуск контура до 6 экранных пунктов; выбранный несохранённый
черновик и стёртые части используют тот же допуск, не отдельную константу.
Физические ручки принимают круг радиуса 12 pt. VoiceOver-рамки 44×44 и их
adjustable-действия сохранены; UIKit и input gate используют один hit-test.
Не менялись графическая геометрия, внутренний выбор полигонов, привязки,
сохранение, Undo, содержимое или сеть.

Две native-регрессии дали настоящий RED на физическом iPad:
`.build/gui225-hit-red-20260918/`. Исправленный неизменный native-срез
`.build/gui225-hit-native-20260918/verification.json` — **28/28 PASS**, source
`45a0a669cbe9f995927dac142c5edb5f125aed7651a83064dd861da2659889af`.
Проверены попадание около контура при scale 0.25/1/3, все виды ручек, свободный
контакт рядом с ними, выбор/перенос маленьких фигур, прежняя геометрия resize,
отмена, переключение меню и отсутствие стёртых призраков.

Шесть физических UI-сценариев добавлены/выбраны: тап рядом и сохранённый drag,
resize/binding и меню концов — на доске и на листе. **Они не исполнились**:
в RED и `.build/gui225-hit-green-20260918/` runner завершился до первого жеста
с `Timed out while enabling automation mode`. Это инфраструктурный отказ,
не доказательство поведения. Пользователю предложено подтвердить системный
допуск на iPad; ответ пока не получен. CoreDevice сообщает passcodeRequired=false.

Сборщик пары отказал native-only квитанции: изменённый UI-сценарий требует
жестовой проверки. Это ограничение не обходилось; UI-тесты не удалялись и
правила выпуска не ослаблялись. Кандидат **0.3.91 (94) пока не установлен**,
рабочая пара остаётся **0.3.90 (93)**. GUI-225 и физическая приёмка открыты.

## 18 сентября 2026 — GUI-226: область не теряет открытый лист за его краем

Жалоба на массовое выделение обнаружила два разных ограничения. В текущем
`NotebookSelectionSession` рамка является `.context`, а не группой редактируемых
объектов; массовый перенос/resize этим изменением не реализован. Конкретный жест
Амира и ожидаемое действие после рамки ещё уточняются; GUI-226 остаётся открытой.

Отдельный дефект воспроизведён на физическом iPad: рамка частично за краем
открытой бумаги выбирала `.board` под ней вместо видимой `.page`. Причина —
требование полного вхождения рамки в item. Теперь открытая страница/документ
владеет пересечением с рамкой; полностью внешняя область не получает скрытую
доску. Выделение остаётся областью, не превращается в тап/разрешение на весь
объект. Сохранение, Undo, публикация выбора и правила доступа не изменены.

RED: `.build/gui226-paper-area-red-20260918/` — target.board вместо target.page
в обоих направлениях протягивания. GREEN: **5/5 native physical**,
`.build/gui226-paper-area-green-20260918/verification.json`, source
`aedcd82ce11eaf7fc16c7c9662d31c7154821bfa5443734aad0a4e0abcc62771`.
Проверены triangle/line/text внутри области и исключённый сосед, отсутствие
расширения tiny cover grant, адрес открытого документа поверх чужой обложки,
неизменность закреплённых источников. Квитанция относится к рабочему дереву
вместе с незавершённым GUI-225, а не к установленной production-сборке.

Настоящие жесты и установка обновления ещё не подтверждены: UI runner
останавливается на системном включении automation (см. GUI-225). Ограничение
выпуска не обходилось. Production-пара остаётся **0.3.90 (93)**; исправление
в рабочее приложение пока не доставлено. Это не полная приёмка и не завершение
единого группового редактирования.

## 18 сентября 2026 — S8: общий lifecycle, сохранённые источники и причинная отмена

Интегрированы `appendPage`/`deleteItem` в SDK v2 (22 операции) через прежние
native owners и очередь Store. Типы, справка и компактные versioned результаты
генерируются тем же маршрутом. Удаление тетради, документа и пустой доски
сохраняет допущенный источник для позднего causal merge, но убирает его из
обычных чтений, ссылок и локальных writes. Undo восстанавливает членство,
не перезаписывая принятый human source историческим телом. Nested child/parent
восстанавливаются в owner-order. Source-before/after inverse входит в ту же
квитанцию и closure доставки; manifest 8, производная DB schema 10.

Неизменные **522 inputs** проверены до/после обоих профилей; SHA-256 файла
полного hash manifest: `2d78dca6465ded9f77096ab0de5628df8fccca5d6dcba48730f3cb33872ef517`.
`.build/s8-lifecycle-native-20260918/` содержит
исходные журналы, hashes и точный manifest переноса 84 Source/Test/MCP файлов
из изолированного checkout. Чужие 9 GUI-225 Application/docs правок не включены.

- Core lifecycle/replication/read-budget: **168 тестов / 30 suites PASS**, 43.285 s.
- Capture, source deletion, native append, vector, migration, erasure:
  **59 тестов / 9 suites PASS**, 249.953 s с созданием настоящего 100k fixture.
- Append к 100 000 PAGE: **7 542 SQL VM steps, 13 изменённых адресов**;
  длительность всего fixture не выдаётся за задержку добавления листа.
- MCP protocol + настоящий native IPC: **16 PASS**; generated SDK types:
  **3 PASS**; `npm run check` и проверка generated resources — PASS.
- Проверены повтор до/после undo, immutable actionVersion, stale/неполная basis,
  повторный UUID, late human PAGE/document/state/board+ink, reopen/fresh peer,
  отсутствие orphan allocation/ACK, скрытые ссылки и bulk native ink guards.

RED сохранён: первый общий профиль дал 2 ошибки старых index fixtures, которые
пытались создавать orphan через публичный save. Следующая попытка подтвердила
отказ уже на raw commit. Проверки теперь требуют rollback этих недопустимых
cuts и публикацию catalogue/source/state вместе, не ослабляя владельца.
Первый types запуск имел неверный cwd (`tsc ENOENT`); повтор в MCP прошёл без
правок кода. Предыдущие реальные RED delete/undo и snapshot-order сохранены
в `/tmp/notebook-s8-document-board-{first,second,thirdb}-gate.log`.

**S8 ещё In Progress.** Последовательная цепь move/create → delete → undo delete
→ undo earlier пока консервативно сохраняет восстановленный placement: typed
receipt provenance нужно довести. Native unstack существует, а public move
пока требует free item; это оставшийся SDK-пробел, не повод добавлять новый MCP.
Общий finite read allowance 65 536 rows / 32 MiB / 8 MiB value не увеличивался;
полный delete/undo 100k PAGE не объявляется допустимым или измеренным PASS.

Это локальное доказательство кода, **не установка и не физическая приёмка**.
Пара 0.3.90 (93) данного среза не содержит. Ни Xcode/Simulator, ни новая пара
в этом профиле не запускались; identity, trust, ключи и живые базы не менялись.
Физические selection/жесты/показ, окончательная цепь undo и согласованный выпуск
остаются открытыми. Жалоба Амира на вход/выход из тетради не объявлена принятой.

## 18 сентября 2026 — S8: последовательная placement-отмена и SDK извлечение из стопки

Закрыты два кодовых остатка предыдущего среза. В том же receipt-derived
индексе хранится typed proof полного placement register из исходного и undo
inverse: цепочки move/create → delete → undo delete → undo earlier работают
после reopen, доставки свежему peer, двух циклов удаления и миграции schema
10 → 11. Canonical receipt hashes и read/change cursors при пересборке не
меняются. Manifest остаётся 8. Human ABA и losing concurrent heads защищены;
shared merger отвергает повтор dot с другим payload. Неканонические placement
rows не становятся основанием отмены; отказ откатывает receipt, proof и cursors.

`moveItem` извлекает выбранного участника через прежний native `unstackItem`,
не переписывая registers соседей. Не добавлены операции или инструменты.
`boardItem` теперь строит basis по предмету и его настоящей содержащей доске,
а не ошибочно использует item UUID как board UUID. Чтение соседей не даёт scope.
Исправлена export-фикстура: документ создаётся вместе с catalogue/state/board,
как в приложении, а не запрещённым orphan save; production guard не ослаблен.

Доказательства: `.build/s8-placement-followup-20260918/`.
- Настоящий RED: placement/stack — 20 issues; три malformed receipt cases —
  14 issues; реальный IPC boardItem — `target_missing`; orphan export fixture —
  4 failures. Ранние compile errors и неверный отрицательный localY в fixture
  также сохранены; это не ошибки native WorldPoint contract.
- GREEN: **128 Core / 14 suites + 1 Host**; ещё **25 Core / 4 suites + 10 Host**;
  **5 export Core**; **17 MCP/native IPC**, **3 SDK types**, `npm run check` PASS.
- Реальное адресное чтение блока среди 100 000 state records: **335 SQL instructions**.
- **551 source inputs** одинаковы до/после Core/MCP; последующее изменение —
  только export fixture, отдельно проверенная с неизменными 551 inputs.

Это локальный Core/IPC результат, не signed XPC, выпуск или показ на iPad.
Пара 0.3.90 (93) этих изменений не содержит; новые приложения не устанавливались.
S8 остаётся In Progress до согласованной физической приёмки. GUI-225 правки
соседней задачи не включены в коммит; жалоба на жесты входа/выхода не закрыта.


## 18 сентября 2026 — S9: программируемые схемы, документы и адресные источники чернил

Через прежний Core добавлены `pageInkActions` (до 64 metadata headers с курсором)
и `pageInkAction` (точные samples одного UUID). Каталог не читает samples/PNG;
чтение источника ограничено двумя physical rows / 4 MiB и прежним общим бюджетом.
Basis включает версии листа и чернил из того же SQL-снимка; retired page не читается.
Порядок каталога — UUID, не порядок штрихов; sequence/eraser/isActive не выдают
источник за видимые пиксели. OCR и новые команды записи не добавлены.

SDK описывает настоящий vision receipt: content/crop cells, points, pixels,
occupied cells и image hashes вместо выдуманного `region`. Spatial `textStyle`
читается типизированно и использует ту же схему, что запись; PAGE не получает
несуществующего обязательного стиля. Обновлены общие generated d.ts/help/schemas.

Доказательства: `.build/s9-programmable-content-20260918/` и подписанный native
XPC run `.build/s9-composition-native-final-20260918/`.
- RED: неизвестные PAGE read kinds; неподдержанная typed vision geometry;
  отсутствующий typed textStyle и принятие spatial read без обязательного стиля.
- GREEN: **32 Core / 6 suites + 1 Host**, **27 MCP/type/native IPC**, npm check.
  Финальные MCP/check выполнены на неизменных **556 inputs**; Swift inputs с
  Core gate не менялись. Board и cover стиль проходят read → edit → undo.
- 100 000 посторонних ink sources: metadata + точный источник — **1 169 SQL
  instructions**, **0.00516575 s**; seed **56.336929 s** измерен отдельно.
  Повреждённые посторонние samples и raster baseline не декодируются.
- Подписанные реальные XPC: **4/4 PASS**, 0 skipped/runtime warnings. JS перестраивает
  граф с bound connector и undo; меняет source/структуру/state документа с
  атомарным stale refusal; обнаруживает UUID человеческого штриха, конвертирует
  и отменяет; настоящий PDF job сохраняется после run и не блокирует writer.
  PDF fixture создаёт полный native document bundle, не orphan document.
- Первый Mac запуск остановился на использовании внутренних JSONValue helpers
  тестом; второй дал 3 PASS / 1 FAIL из-за неверного ожидания HTML у markdown
  блока. Исправлены тесты по native контракту (source, пустой authored HTML),
  production не ослаблен. Последнее SDK-only добавление textStyle проверено
  отдельным финальным MCP/type gate после Mac XPC run, не объявлено его частью.

S9 остаётся In Progress: это не установка и не физическая приёмка. Рабочая пара
0.3.90 (93) не обновлялась и не содержит S8/S9. Read-only MCP refresh в 07:34 UTC
подтвердил два v2 инструмента, TS 7.0.2, исходный результат повторного run и
`selection: unknown` / `connection: disconnected`; содержание не менялось.
Физические жесты, saved/received/shown и вся веха не объявлены принятыми.
GUI-225 peer changes исключены из коммита; жалоба на вход/выход остаётся открытой.


## 18 сентября 2026 — S10: интеграционный код и честные границы окончательной приёмки

В полном маршруте единственная подготовка npm/закреплённого TS stage перенесена
перед Swift tests. Раньше clean/current checkout зависел от старого stage и
останавливался до проверки продукта; тот же подготовленный stage теперь
используется подписанным Mac build. Второго compiler/bootstrap пути нет.

Большая legacy-квитанция v1 теперь продолжается через v2 metadata-разделы.
Frozen v2 model имеет приоритет; при его отсутствии допускается только
существующий receipt-hash-bound read model с **точно совпавшей** actionVersion.
После изменения legacy receipt несохранённая старая версия остаётся unavailable.
Не создаются result/archive записи, новые значения не восстанавливаются из
сегодняшнего содержания, старое действие не запускается заново.

Добавлены два signed XPC сценария: независимые JS и TS одной транзакцией создают
два новых узла и bound connector, затем одним undo удаляют весь граф; повтор
run не пишет ничего. Второй сценарий читает → получает native human edit →
отказывает по старой basis → явно читает дельту → сохраняет дополнение к
человеческой подписи; undo сохраняет человеческую подпись. Это осознанное
продолжение программы, не автоматическое освежение предусловий host.

Доказательства: `.build/s10-history-and-route-20260918/`,
`.build/s10-integration-second-20260918/verification.json`.
- RED: порядок подготовки full route; 3 случая legacy version continuation.
- GREEN: **12 Core** (legacy 3, SDK v2 5, action read model 4), **6 настоящих
  CLI compiler**, **80 route tests**, shell syntax. 380 inputs Swift gate неизменны.
- Последующий единый selected gate: **74 MCP**, **10/10 signed Mac XPC**,
  0 skips/runtime warnings; текущий TS **7.0.2**, SDK
  `a6f192ea3615cfb0e1198a716935e587b7f2ac7febd24ab8edde2a3c10f1f46a`.
  Source identity **996 files**,
  `d615df32d19b3cc24f3713be5afb5360de2ed25ca44968cb2582265ae51c936f`.
  Graph/document/ink/PDF/label/search/lost reply проходят на одном свежем cut.
- Первая команда с Swift suite в XCTest-only `--test` отвергнута до запуска;
  первый Mac build нашёл неверный test-only `updating(graphic:)`. Исправлена
  конструкция fixture по существующему API; production guard не менялся.
  `.build/s10-integration-selected-20260918/` не является PASS.

### Что действительно измерено, а не восстановлено по размеру логов

| Сценарий | Существующее доказательство | Остаток |
|---|---|---|
| Подпись | S4 live: один start → completed, 262.88725 ms | Сопоставимый before/after и серия cold/warm |
| Поиск вне экрана | S2: 13 hits / 5 страниц; 512 matches — 12 167 SQL instructions | Полная серия public calls/bytes и физический сценарий |
| Один блок | S1/S3: 335 SQL instructions среди 100k чужих state records | Полные read/decode counters и latency series |
| Несколько связанных объектов | S10: JS/TS, три новых объекта / одна запись + undo | Производственные calls/bytes/latency/показ |
| Алгоритмический reflow | S9/S10 signed XPC, authored/derived связи, scope refusal и undo | Сопоставимый исходный performance baseline |
| Конкурентная правка | S10: конфликт → delta → явное продолжение → undo сохраняет human | Физическое человеческое продолжение |
| Разрыв связи | S5 live: start 14.975417 ms; resume 13.732708 ms; replay 11.716208 ms, только два эффекта | Распределение, cold restart и точный received/shown |

S1 PAGE read: 207 SQL instructions / 445 B; S3 delta: 548 / 1070 B.
Эти числа не являются измерением всех декодирований или объёма MCP-провода.
Время XCTest не равно времени SDK-call, размер log/artifact не равен ответу.
Исторический commit `1e456d3` и RED тесты не являются измеренным before baseline;
процент ускорения не заявлен. Сопоставимые семь before/after серий остаются открыты.

**S10 не завершён.** Installed pair 0.3.90 (93) не обновлялась. Read-only probe
07:44 UTC после foreground launch физического production iPad всё ещё показал
`disconnected` / `selection: unknown`. CoreDevice: passcodeRequired=false;
Mac показывает trusted iPad и «Ожидается iPad». Причина разрыва не установлена.
Device Hub AX не ответил; Console вернул ScreenCaptureKit -3811. Штатный сбор
iPad logs потребовал root, существующего passwordless допуска нет; обхода нет.
Это ограничения наблюдения, не доказательство дефекта Notebook/доверия.

Не приняты: выпуск S8–S10, physical gestures/selection и точные received/shown,
десять повторов и 30 минут совместной работы, системные frames/CPU/GPU/memory.
9 незавершённых GUI-225 peer paths сохранены отдельно и не включены в коммит;
их присутствие в source inventory selected gate не является приёмкой их UI.
Жалоба Амира на zoom/вход/выход из тетради остаётся открытой. Данные, identity,
ключи и доверие не сбрасывались; Simulator не использовался.


## 18 сентября 2026 — S10: реальные before/after, ожидание завершения и обновление истории

Сопоставимые public MCP серии выполнены на трёх подписанных Mac Release cuts:
API v1 baseline, первоначальный v2 и final v2. По **33 испытания**: шесть задач
по пять повторов и reconnect трижды; дополнительно равная wait policy ×6 и
app/XPC restart. Настоящие coordinator/QuickJS/native writer, отдельные новые
root, никакого production content/архивов или fake delivery receipts.
Подробный метод, таблицы и ограничения: `docs/programmable-notebook-measurements.md`.

Измерения обнаружили 50 ms polling в `NotebookScriptCoordinator.handle`:
короткие v2 reads, несмотря на один внешний вызов, задерживались относительно
v1. Теперь клиент подписывается перед async journal read; durable terminal
reply будит его без polling. Дедлайн/отмена освобождают только attachment;
принятые эффекты дожидаются drain. Нового result cache или исполнителя нет.

- Настоящий RED: wait=160 ms делал четыре journal read вместо двух. GREEN:
  **20 Host tests / 3 suites** (completion 8, deadline 3, recovery 9), 1.444 s.
  Проверены lost-wakeup race, несколько курсоров, client cancellation,
  shutdown, held durable reply и accepted-effects drain.
- Финальный selected gate: **74 MCP + 10/10 signed Mac XPC PASS**, 0 skips
  и runtime warnings. `.build/s10-completion-signed-20260918/verification.json`.
  Неизменные **997 inputs**, source SHA256
  `bf946a863aaac2e17142cf351a8eb79313863237e9803f0c19d7056af0080763`.
- Final Release собран из этого же frozen source; CDHash
  `f53607260b1d549964a3c2676306dcb36ed1f271`. Exact baseline SHA256
  `a9aad42a9a647039d94c980645d84c22115fbee9beb11775a44973c1fc5a6a7d`;
  его точный source commit неизвестен, `1e456d3` — лишь comparison base.
  GUI-225 inputs в inventory не означают приёмку их физических жестов.
- В default серии обычные задачи требуют **2 → 1 MCP calls**. Median wall ms
  v1 → final: label **150.93 → 121.66**, search **16.45 → 16.81**,
  block **15.53 → 15.24**, graph **227.64 → 186.49**, reflow **194.44 → 148.97**,
  conflict **225.58 → 191.44**. Reconnect включает намеренные 3000 ms и не ускорен.
  Ответ graph больше: **5626 → 9154 B**. Универсальное ускорение/сжатие не заявлено.
- 39 различных последовательных проекций страницы совпадают между всеми
  cuts, включая authored frames/bindings и вычисленную геометрию. Это проверка
  перечисленных в measurement doc полей, не всех native fields/styles/state. Сохранённые
  результаты/повтор run после app+XPC restart проверены без нового эффекта.
- Final signed TS micro-fixture: **48.457917 / 51.187334 ms**;
  sampled RSS **39 272 448 / 43 859 968 B**, CPU **713 599 / 844 513 ns**.
  Это 20 ms sampling компилятора, не истинный peak или system-level нагрузка.

На том же **новом isolated v1 root** обычный startup final v2 затем подтвердил
обновление истории без DB copy или ручной миграции. Исходный manifest неизменен,
workspace, исторический actor и проверенные проекции **67 элементов / 81 блока**
сохранены.
`resume v2` старого run возвращает `run_api_version=1` с теми же fingerprint,
result и effects. Большая историческая квитанция по точной actionVersion:
**64 operations (32+32), 65 changes (32+32+1)**. Чтения не создают доменных
эффектов; старого v1-start/исполнителя не возвращали. Private app/XPC остановлены.
Квитанция `.build/s10-legacy-upgrade-20260918/upgrade-proof/report.json`.

Общие измерения и сохранённые drivers/raw receipts:
`.build/s10-programmable-comparison-20260918/` и
`.build/s10-measure-{baseline-r2,current-r2,final}-20260918/`.
Эти серии закрывают прежний пробел **Mac before/after** в предыдущем разделе,
но не physical release, полный read/decode счёт каждого сценария, системные
frames/CPU/GPU/memory или число исправлений запросов автономного агента.
Offscreen search здесь одно совпадение; pagination доказан другими проверками.

**S10/веха остаются In Progress.** Пара **0.3.90 (93)** не обновлялась нами;
физические saved/received/shown, selection/жесты, десять повторов и 30 минут
совместной работы не заменены Mac PASS. Жалоба Амира на zoom, загрузку и
неожиданный выход из тетради остаётся открытой и ведётся совместно с peer.
Его незавершённые source/docs changes не входят в этот commit. Simulator,
смена ключей/identity, сброс доверия и восстановление архивов не использовались.

## 18 сентября 2026 — GUI-200: физический профиль долгого открытия и выхода в канвас

Амир уточнил: задержки заметны при открытии тетради и выходе в канвас.
Диагностика выполнена **без изменения установленной пары 0.3.90 (93)**,
данных, идентичности или доверия. Физический iPad, production Notebook PID
5186; Simulator не использовался. Time Profiler записан через all-processes
после неудачного attach по PID/имени; анализ ниже отфильтрован по Notebook.

Символы соответствуют именно установленному бинарнику: UUID
`953694D7-4DEE-3F37-905E-A0509B81051D` совпал с Release dSYM из
`.build/gui199-paper-input-release-20260918/derived-data/Build/Products/Release-iphoneos/`.
Source identity того выпуска:
`10716be0a1537138f67db8e11de7f072d85077e4fb2a10b7e474be464b9f0e56`.
Нынешние незавершённые UI-правки и новые Core/SDK-коммиты этим профилем не проверены.

Две независимые записи дали один доминирующий путь:

- Первые 20 секунд: суммарный CPU sample weight Notebook **20 763 ms**, main
  **20 743 ms**. Ближайший Notebook frame: `erasurePath.flush`,
  `batch.normalized()` **18 673 ms**, `previous.union(merged)` **1 135 ms**.
- Запись **120.838 s**, 08:41:32–08:43:33 UTC: Notebook **105 057 ms**,
  main **94 250 ms**; стеки с `NotebookElementAppearance.erasurePath`
  **92 074 ms**, все на main — **97.69%** его sampled CPU.
- Непересекающиеся вызывающие пути этих 92 074 ms: `AgentOverlayView.body`
  **70 410 ms**, `NotebookAttentionProjection.pickElement` **19 687 ms**,
  `NotebookElementErasurePaint.clip` **1 977 ms**.
- Instruments `potential-hangs` зарегистрировал **30 интервалов** Notebook
  суммарно **91.776 s**, максимальный **7.977 s**. Интервалы детектора не
  равны числу отдельных пользовательских переходов.

**Причина подтверждена:** синхронное построение/нормализация геометрии масок
ластика выполняется прямо при SwiftUI body, рисовании маски и hit-test.
Один и тот же производный результат не переиспользуется между потребителями.
Уже существующее разбиение по 128 треугольников и balanced union не устранило
дорогой реальный случай. Main не обслуживает интерфейс вовремя — ожидание
выглядит как «подготовка пространства», даже когда причина не в загрузке данных.

Владелец геометрии — `Sources/NotebookCore/NotebookElementAppearance.swift`;
входы UI — `Applications/Shared/AgentOverlayView.swift`,
`NotebookElementErasureView.swift`, `NotebookAttentionProjection.swift`.
Следующий исправляющий срез должен убрать тяжёлое построение из синхронного
UI-пути и переиспользовать одну производную appearance по актуальным geometry /
erasure dependencies для paint/pick/read. Нельзя просто убрать проверку erased:
это вернёт невидимые выбираемые объекты и ложное содержание для агента.
Нужны сохранение точного покрытия, Undo, resize и инвалидация при изменении,
затем повтор физического профиля на том же содержимом.

Evidence: `.build/gui200-preparation-audit-20260918/` — обе `.trace`,
`discovery-profile.xml`, `open-close-profile.xml`, `open-close-hangs.xml`,
их JSON summaries и `erasure-findings.json`. Это sampling CPU, не точное время
каждого вызова, не FPS/GPU/memory; у ручных жестов нет временных меток.
Другие причины загрузок, неожиданный выход и транспорт этим не исключены.
**Диагноз, не исправление:** код/приложения в этом срезе не менялись;
GUI-200 и физическая приёмка остаются открытыми.

## 18 сентября 2026 — S9/S10: SDK соответствует нативным ink/runtime/render results

Продолжение единой вехи GUI-218/GUI-219, без изменения UI или второго пути
записи. Проверка обнаружила три настоящих разрыва публичного контракта:

- `SpatialInkSpan.elementTargets` уже возвращался Core, но отсутствовал в
  сгенерированном SDK. Один общий тип target теперь используется PAGE и
  spatial ink: element identity, исходный frame и optional world origin.
- До первой публикации native runtime reader возвращает `null`, а не статус
  соединения. `Snapshot.data` теперь допускает это и требует проверки в TS.
- Native render diagnostics — объекты `kind`, optional `elementID`, `message`,
  а не строки. Render, pageMap/pageImage/regions, target receipt и action
  snapshots используют одну схему этих данных.

Для каждого дефекта сохранён RED перед исправлением; затем native fixture
проверил действительную сериализацию через прежние read/receipt owners.
Board/cover targets не теряют координаты, code ink без targets остаётся без
этого поля, отсутствующий runtime не превращается в выдуманный disconnected.
Типовые потребители компилируются, неверные формы/непроверенный null отвергаются.
Структурные page-image projections проверены схемой; это не доказательство
производства настоящих пикселей или живого соединения.

Финальная проверка из `MCP/`: **78/78 MCP tests PASS**, затем
`npm run check` PASS (TypeScript + актуальность generated resources).
Все **7** исходных/generated/test файлов неизменны между началом и концом.
SHA256 `notebook-sdk.d.ts`:
`e44af80deba9af955fceb7e117b92052580041b0d53ab7b47558d3cee583a261`.
Frozen native fixture SHA256:
`dfdb18017443aad28bc9784c113bbdfba7560558e7211201a6bbe8c47a46cd52`.
Его exact source commit неизвестен: параллельная сборка peer заменила общий
Debug fixture, после чего executable был отдельно зафиксирован до финального
прогона. Это явно не identity подписанной/установленной сборки.

Evidence: `.build/s10-native-result-contracts-20260918/`, включая RED/GREEN,
`final/{mcp.log,check.log,summary.json,source-before.json,source-after.json}` и
`native-fixture-final.json`. Первый запуск из неверного cwd дал ENOENT к tsc;
лог сохранён, invocation исправлен без изменения harness. Промежуточный
правильный запуск 76/76 предшествовал двум render regressions.

Пара 0.3.90 (93) этим срезом не обновлялась; предыдущие signed receipts
относятся к предыдущему SDK hash. Новая подписанная интеграция, выпуск S8–S10
и физическая приёмка остаются открыты. Чужие Core/UI правки не включены;
Simulator, production DB writes и сброс доверия не использовались.

### Подписанная проверка нового SDK, 09:17 UTC

Предыдущее открытое условие **signed SDK integration** закрыто отдельно:
из immutable `git archive 8c00bbe` штатный selected route исполнил **78/78
MCP + 10/10 Mac XCTest PASS**, 0 failures/skips/runtime warnings. Проверены
JS/TS bound graph, basis/короткий результат, отмена допуска/компиляции/принятого
commit, lost replies и recovery без replay. Это не прогон всех UI-сценариев.

Source SHA256 `8b1a9fc601ae0a4e243a0b189b5594161aef81871d61cad66ce7f4546557a973`
неизменен. Встроенный compiler **7.0.2**, SDK **e44af80deba9af955fceb7e117b92052580041b0d53ab7b47558d3cee583a261**;
Mac acceptance CDHash `37625ba5f42325e4cbfc4b67294efec3b65799dd`, Apple Development
team `M94V58FCVP`; XPC получили точные исходные sandbox entitlements перед
исполнением, не расширенные тестовые права.

Квитанция `.build/s10-sdk-contracts-signed-20260918/evidence/verification.json`,
исходный commit/inventory — соседний `source-identity.json`; команды и raw
xcresult сохранены. Private source copy исключает все незавершённые peer UI
правки. Это не общий release cut и не установленная production пара;
физическая доставка/selection, системные метрики и полная приёмка открыты.

## 18 сентября 2026 — GUI-200: производная геометрия вне синхронного UI-пути

Исправлен подтверждённый выше источник 97.69% main sampled CPU, а не скрыт
индикатор подготовки. У существующего `NotebookElementErasureCache` модели
теперь один результат по адресу, исходной форме, локальной геометрии, размеру
и измеренным стираниям. Отдельный actor готовит boolean paths; body, picker,
paint и новые привязки (в том числе удержание Pencil) не нормализуют их сами.
При изменении входа прежний результат не выдаётся, отменённая задача не
публикуется; остановка модели отменяет и дожидается своих задач.

Пока вычисление не закончено, ластик виден через nonzero fill тех же измеренных
треугольников без boolean union, а устаревшая маска не допускается в hit-test.
Маска и итоговое visible-содержание используют прежнюю Core-геометрию;
семантика агентского read, Undo и сохранённых действий не заменена кешем.
Время жизни результата следует загруженным страницам/доскам, а не произвольному
числу entries: 160 одновременно используемых объектов не вытесняют друг друга.
Камера и простой перенос не пересчитывают маску. Native RED дополнительно
обнаружил округление локальных кривых при переносе стрелки; graph теперь решает
её в локальном базисе, без epsilon-сравнения и смены правил привязки.

**Проверки:** Core geometry/100 000 owners PASS (адресный запрос erasures 114
SQLite VM steps); 14 connector/geometry checks PASS; после QuickShape-provider
**31 Core tests PASS**. Независимый oracle сопоставляет coverage исходных
Metal-треугольников и обеих форм маски (нормализованной и прямой), включая resize.
Первый физический native прогон — 7/8, оставшееся расхождение переноса стрелки
исправлено. Финальный диагностический прогон физического iPad — **37/37 PASS**,
0 failures/skips, неизменный source SHA256
`ee4ed5cdf3f63267ea03265cfbb216482ae716f8d826192229917e80fa1beaff`.
Он включает ещё незавершённый GUI-225 в рабочем дереве, не независимый release
срез этого коммита. Проверены выход main при 8192 samples, reuse одного CGPath,
инвалидация/отмена/resize/Undo/полное стирание, QuickShape binding, 160 соседей,
освобождение владельца, повторное открытие и отсутствие selectable ghost.

**UI не принят, обновление не выполнено.** В combined selected попытках
native 35/35, затем 37/37 прошли, но все три выбранных жестовых сценария не
стартовали: XCTest `Timed out while enabling automation mode` (runner 5309,
затем 5330). CoreDevice сообщал passcodeRequired=false; это не подтверждение
разрешения UI Automation. Пользователю задан вопрос о системном допуске,
ответа пока нет. Последняя небольшая правка page-cache key использует именно
рисуемый draft graphic; после неё native-only diagnostic проверил компиляцию
и 37 тестов. Это **не** замена failed UI gate: он не создал verification.json,
не запускал сборку/установку production и не менял release rules.

Evidence: `.build/gui200-erasure-fix-20260918/` (Core logs, final-summary.json,
`native-final/` с xcresult, исходниками и exact command),
`.build/gui200-erasure-native-20260918/` (RED),
`.build/gui200-erasure-green-20260918/` и
`.build/gui200-erasure-final-20260918/` (два blocked UI прогона).
Реальные измеренные eraser inputs исследованы локально, в git не включены;
временный read-only снимок SQLite удалён после извлечения. Человеческие записи,
идентичности и доверие пары не менялись, архивы не открывались.

Рабочая пара остаётся **0.3.90 (93)**, кандидат 0.3.91 (94) не установлен.
После разрешения UI Automation требуются выбранные жесты, подписанная сборка,
обновление на месте и повтор Instruments на том же содержимом. Ускорение
в процентах, пик памяти, FPS/GPU, десять повторов и 30 минут не подтверждены.
GUI-200 остаётся In Progress; нативный PASS не объявлен физической приёмкой.

## 18 сентября 2026 — S10: настоящие read/decode counts семи сценариев

Закрыто прежнее отсутствие SQL/read/decode измерений: ещё **33 v1 + 33 v2**
public MCP сценария на новых isolated roots и двух signed Mac Release copies.
Одинаковый observer добавлен только в private copies; canonical runtime/API
не менялись. Admitted SQL rows/bytes и successful physical-fragment decodes
измерены вокруг программы, без setup/verify/undo и фонового чтения.
Это не disk I/O, не все JSON conversions и не новая latency серия.

Медианы SQL rows v1→v2: подпись **877→362**, поиск **53→74**, блок **49→67**,
связанный граф **2407→1840**, reflow **1376→682**, conflict **1213→487**,
reconnect **1341→409**. Fragment decodes подписи **680→134**. Удорожание
поиска/блока не скрыто; диапазоны и causal-history рост graph повторов сохранены.
**39** последовательных проекций страницы и **81** блок совпали.
Raw `journal` scope означает script-persistence closure и в v1 включает
SDK reads: не называем его счётчиком исключительно журнала.

Полный метод, bytes/decodes и fingerprints — `docs/programmable-notebook-measurements.md`,
квитанции — `.build/s10-read-metrics-20260918/comparison.json`, `evidence-manifest.json`
и `{baseline,v2}/run/`. Collector 3/3 synthetic tests и отдельный Swift 6 helper
fixture PASS, оба настоящих workload drivers PASS. Две private app и четыре
принадлежащих им XPC остановлены по точным executable paths. Production,
iPad и доверие не менялись; это не приёмка общего release cut.


### GUI-200 / GUI-225: физический UI допущен, 18 сентября, 09:48 UTC

После подтверждения пользователя XCTest действительно исполнил жесты на
физическом iPad. Первый прогон обнаружил несрабатывающий захват конца линии:
UIKit возвращал SwiftUI hosting view в `touch.view`, хотя координата попадала
в нарисованную ручку. Проверка тождества view удалена; допуск принадлежит
существующему window-space registry. Исключается только собственный регион,
чужой chrome, открытые меню и палитры по-прежнему блокируют этот жест.
Физическая область ручки — круг радиусом 12 pt; VoiceOver сохраняет 44 pt.

Готовность erasure-appearance теперь наблюдается в body страницы до отложенного
ForEach. Пока вычисление не закончено, AX не публикует исходный стёртый объект.
Мгновенный `.exists` в XCTest мог опередить публикацию обновлённого AX-дерева;
геометрическая диагностика уже показывала `.erased`. Регрессия ожидает удаление
из дерева не более 2 секунд; она не объявляет полностью стёртое содержание
допустимым и не заменяет проверку фактического выбора.

Диагностический `.build/gui200-ui-owner-green-20260918/summary.json`:
**28 native + 2 физических UI PASS**, 1 failed немедленный AX assert.
После уточнения этой границы и исключения намеренного попадания в боковую
ручку при проверке стёртой части финальные **3/3 UI PASS**, 0 failures/skips/
runtime warnings. Исполнены три цикла выхода/открытия листа с 16 полностью
стёртыми фигурами и одной частично стёртой, снятие выделения рядом с линией,
сгибом и углом, реальное удлинение линии за конец — на странице и доске.
Квитанция `.build/gui200-ui-release-20260918/verification.json`; неизменный
source SHA256 `71203fdc265bbf35ccc3b89b71d6a152d707c27cbe2929f2455ef39377d659ac`.
Видео и screenshots в xcresult. Старые неуспешные попытки сохранены, gate
не обходился. На момент этой записи подписанная 0.3.91 (94) ещё собирается;
рабочая 0.3.90 (93) не объявлена обновлённой. Системный повтор после установки
и приёмка пользователем остаются отдельными границами.


### Установка 0.3.91 (94), 18 сентября, 09:52 UTC

Штатный сборщик пары завершил `verified-build` на том же SHA256
`71203fdc265bbf35ccc3b89b71d6a152d707c27cbe2929f2455ef39377d659ac`,
selected route, Apple Development `M94V58FCVP`. Квитанция
`.build/gui200-release-20260918/build.json`; iPad binary UUID
`63452003-CDBB-3680-8342-87605835E03F`, Mac
`C72E03B0-4ED8-3D78-B1A0-1B98C0220CAA`.

CoreDevice установил **production** `com.amirtlinov.notebook.preview` на месте,
read-back подтвердил **0.3.91 (94)**, launch PID **5482**. Первая команда launch
не приняла порядок CLI options и не запускалась; исправленный вызов успешно
активировал bundle, повторной установки или сброса контейнера не было.
`.native-test` и `.uitests.xctrunner` удалены; apps-clean показывает единственный
Notebook bundle `.preview`. Никакая тестовая фикстура не переносилась в него.

Mac `/Users/amir/Applications/Notebook.app` обновлён после проверки отсутствия
активных project runs, незавершённого voice/input, ожидающих chat/file действий.
Прежний helper завершён через `NSRunningApplication.terminate`, без force kill;
предыдущий bundle заменён, старая версия отдельно не оставлена. Запущен PID
**88268**. Опись установленного Mac совпадает с проверенной подписью:
`9c3414e324468d3ef5f531503bafed189002267b13d67df359327879e8a26f73`.
Контейнеры, SQLite, Keychain/доверие не заменялись; backup и импорт архивов
не выполнялись. Build/install — разные receipts:
`.build/gui200-install-20260918/{artifact,ipad-install,ipad-launch-retry,apps-clean,mac-installed}.json`.

Пользователь уведомлён о настоящей установленной версии. Начат отдельный
120s Time Profiler на production94 с просьбой повторять открытие/выход;
до анализа и обратной связи ускорение и полная физическая приёмка не заявлены.


### Production94 Instruments, 18 сентября, 09:55 UTC

120s Time Profiler сохранён после in-place обновления, symbolicated точным
Release dSYM. В экспортированных frames подтверждён iPad binary UUID
`63452003-CDBB-3680-8342-87605835E03F`, процесс **5482**. Один parser прочитал
обе трассы и разрешил XML ref: исходные production93 результаты воспроизведены.

- Production93: main CPU sample weight **94 250 ms**, из них
  `NotebookElementAppearance.erasurePath` **92 074 ms**; **30** potential-hangs,
  суммарно **91 776 ms**, максимум **7 977 ms**.
- Production94: main CPU sample weight **10 956 ms**, erasurePath на main
  **0 samples**; **0** potential-hangs при том же системном пороге **250 ms**.
  UUID соответствует установленному артефакту, не старой или `.native-test` app.
- К моменту записи кеш мог быть уже прогрет. Пользователю предложено повторить
  открытие/выход, но одинаковое число/порядок жестов и ответ о субъективном
  результате пока не подтверждены. Это **не** сопоставимая wall-time benchmark
  серия, не процент ускорения, не FPS/peak memory/CPU-GPU полная приёмка.
  Оставшийся main weight включает построение graphicGraph/body; новое узкое
  исправление не расширялось до отдельного рефакторинга этих вычислений.

Evidence `.build/gui200-production94-profile-20260918/`: native `.trace`, exact
symbolicate/export logs, `open-close-{toc,profile,hangs}.xml`, `summarize.py` и
`comparison.json`. Историческая трасса production93 не изменена. GUI-200
сохраняет открытыми обратную связь пользователя и полную физическую приёмку;
установка и выполненные жестовые регрессии подтверждены отдельно выше.


## 18 сентября 2026, 09:56 UTC — S10: установленный SDK общей пары 94

После handoff физического профиля владельцем GUI проверен именно установленный
`/Users/amir/Applications/Notebook.app` через свежий public stdio MCP; не private
acceptance app и не native IPC. Общая подписанная пара **0.3.91 (94)** содержит
S8–S10, source SHA256
`71203fdc265bbf35ccc3b89b71d6a152d707c27cbe2929f2455ef39377d659ac`.
Build/install receipts и binary UUID указаны в разделе установки выше.

`.build/s10-installed-94-20260918/installed-proof.json` и сырые call/request/result:
**PASS** два tools, API v2, 22 операции с appendPage/deleteItem, TypeScript **7.0.2**,
SDK `e44af80deba9af955fceb7e117b92052580041b0d53ab7b47558d3cee583a261`.
Первый typed ответ completed; JS и TS читают одинаковый workspace. Повтор исходного
run сохраняет fingerprint/result, смена языка получает run_id_conflict. Ошибка
типа не выполняет даже предшествующий emit; runtime stack указывает исходную
строку 3. Все программы имеют **0 доменных effects**: текущий лист, камера и
внимание пользователя не менялись. Проверена также опубликованная справка 22
операций; это не исполнение полного lifecycle/графа в production.

В 09:56 runtime свежий, но **disconnected**, selection **unknown**; сохранён
workspace `FAAAC405-8EF9-4FB9-9B93-CBD876FA97A4`. Read-only Mac UI в 09:58 показывает
«Ожидается iPad», сохранённый доверенный iPad и отсутствие сообщения об ошибке.
По этим сведениям нельзя установить причину LAN-разрыва. Доверие/ключи не менялись,
CloudKit не включался; запрошен фактический статус подключения на iPad.
Ранее запущенный connector Codex всё ещё описывает v1; свежая сессия установленного
bundle проверена отдельно, обход старым start или второй API не добавлялся.

Общий release/install выполнен, но S5/S7–S10 остаются In Progress: точная
received/shown actionVersion, настоящая публикация select/clear/reselect, полный
installed lifecycle/content сценарий и физическая/системная приёмка не доказаны.
Предыдущие signed/native/метрические результаты этим smoke не заменяются.


## 18 сентября 2026, 10:24 UTC — S8: установленные lifecycle-регрессии и исправления

Через свежий public stdio MCP установленной пары 0.3.91 (94) выполнены создание,
переименование/размещение, appendPage, повтор ключа, delete/undo тетради и документа,
а затем явное удаление детей перед пустой доской и восстановление всей транзакции.
Использованы только три собственных временных предмета на tile (1000,1000), без
attention/present. `.build/s8-installed94-lifecycle-20260918/cleanup-receipt.json`
подтверждает их удаление через SDK, itemCount 7→7, сохранение presence/selection.
Производственное хранилище, ключи и доверие не сбрасывались.

Первоначальное ожидание неявного каскадного удаления доски было неверным:
домен правильно отказал. Обнаружены два настоящих пробела:

- отказ возвращал generic `operation_failed` без полезного объяснения. Теперь
  `board_not_empty` сохраняет индекс/адрес операции, объясняет явное удаление или
  перенос содержимого; предшествующее переименование в той же транзакции откатывается;
- после delete/undo тетради и дерева append-undo ошибочно сохранял неизменённую
  добавленную страницу. Существующее подтверждённое происхождение восстановления
  теперь проверяется и для membership: полная версия должна совпасть на каждом
  переходе. Строгое сравнение PAGE-источников остаётся прежним; реальная последующая
  правка, лишнее causal observation или losing head сохраняют страницу.

Обновлена генерируемая справка deleteItem/renameItem, отдельного каскадного API,
нового хранилища доказательств или ослабления undo нет. RED и GREEN сохранены в
`.build/s8-installed-followups-20260918/`: **30 Core tests PASS**, неизменные 298
Core source/test файлов; **11 help/protocol tests PASS**, `npm run check` PASS.
Подписанный маршрут `.build/s8-followup-gate2-20260918/evidence/verification.json`
имеет source SHA256 `c102267422b159190bd53dd656080668f80fa0d9cd46b7f7d4671b9d6bfd5150`:
**78 MCP + 4 signed Mac SDK tests PASS**, 0 пропусков и runtime warnings.
Новый SDK-сценарий проверяет обе регрессии, атомарность, исторический replay и
неизменность presence; остальные три — stale basis, потерю ответа commit/undo и
короткий законченный ActionResult. Это выборочная, не полная приёмка.

Первый Mac-прогон `.build/s8-followup-gate-20260918/` сохранён как FAILED: новая
фикстура не создала presence до чтения. Исправлена фикстура, не продуктовый контракт.
В компиляции остаются два прежних unnecessary try/await warning в
NotebookGraphicRenderingTests.swift:137; это не runtime warnings и не исправление
этого среза. Кандидат пары — **0.3.92 (95)**; на момент этой записи он ещё не
собран/установлен, повтор исправлений на production не объявляется пройденным.
Связь с iPad всё ещё disconnected, поэтому доставка/показ/физическое выделение
и полная приёмка остаются открытыми.


## 18 сентября 2026, 10:36 UTC — S8/S9/S10: установленная пара 95 и настоящие эффекты

Commit `a01887b` опубликован. `.build/s8-release95-20260918/build.json` —
**verified-build 0.3.92 (95)**, source
`c102267422b159190bd53dd656080668f80fa0d9cd46b7f7d4671b9d6bfd5150`.
Mac UUID `27EAD158-CA23-3039-9563-BDD2E7FA711B`, CDHash
`e0e62cf88c6ad6f0f0f02d0940dfe38c8ff8918c`, bundle manifest
`fa034cbba1d283688bbc5fe6b1d0dae90a0560b64bd770852ed1e2d55a1d6ab2`.
iPad UUID `69A376A7-3135-36ED-8515-885818D2E300`, CDHash
`ead54229226a9eb6ecd8b9543e1e41c51ec585cb`, bundle manifest
`bca27149fe2f0fb709eaee37258a31c95a49dd3f794d746aa8166c52b35b9e67`.

`.build/s8-install95-20260918/` подтверждает замену только bundle после обычного
Mac termination и devicectl update прежнего iPad bundle, затем запуск PID 5520.
Проверены отсутствие активных terminal/voice/file/native deliveries, input и
SDK-run перед остановкой. Первый preflight остановился до изменения приложения:
диагностический reader включил дочерние result fragments вместо только run root;
после уточнения адреса проверка прошла. Force quit, backup, перенос/удаление базы,
архивы и сброс ключей/доверия не использовались.

Fresh installed MCP `.build/s10-installed95-20260918/receipt.json`: **PASS** два
инструмента, JS/TS одинаковое чтение, TypeScript 7.0.2 / SDK e44af80…,
первый typed completed, неизменный retry, конфликт смены языка, ошибка типов до
эффектов и исходная строка runtime stack. Это новые действительные public runs,
не вызов private/native test helper.

Installed lifecycle `.build/s8-installed95-lifecycle-20260918/` подтвердил
`board_not_empty`/operation.index=1 и атомарный откат; create/rename/place/append,
удаление-восстановление notebook/document и явного дерева; историческую actionVersion;
append undo после двух восстановлений действительно removePage/preserved0.
Затем undo исходного создания сохранил тетрадь после уже отменённых rename/move/
append — **новый общий provenance gap**, не PASS полной обратной цепи. Изолированный
Core воспроизвёл rename/append/move независимо при неизменном содержании; direct и
delete/restore controls проходят. Исправление существующего inverse owner в работе.
Все три временных предмета удалены отдельной SDK-транзакцией; cleanup receipt:
itemCount 7→7, presence и выбранные адреса неизменны.

S9 `.build/s9-installed95-20260918/receipt.json` подтверждает реальные production
эффекты: atomic bound graph, адресный алгоритм reflow, отказ неразрешённого
перемещения без частичного label write, computed/authored geometry, reflow undo;
блоки/структура/preamble документа, source/state basis и stale refusal, независимая
отмена source/state; обычный persisted PDF job. Creation undo после reflow undo
также сохранил три неизменённых элемента — тот же общий gap, проверяется вместе
с S8. Первый graph driver пропустил обязательные connection/binding поля;
исправлен сам driver и использован новый ключ после notSaved, без скрытого retry.

PDF экспортирован в 23 711 байт, SHA256
`7ffa1826767bc13b94428cb3785c08f78ba9d3e99ebb405eafd73802b9f73a66` сверён с файлом.
PDFKit подтверждает одну страницу, «Before» и полный interactive ID `counter`.
TeX log честно содержит предупреждения о системных Georgia fonts — это не
доказательство побитовой переносимости экспорта между окружениями.
Все три S9 temporary owner удалены, itemCount снова 7→7/presence unchanged;
экспорт и история действий остались в обычном persisted owner. Не проверялись
визуальная композиция на iPad, физический human ink и конкурентный writer во
время этого export; последняя граница ранее проверена в изолированном signed gate.

В обоих installed сценариях runtime свежий, но **disconnected**: saved не
выдаётся за received/shown. Пара 95 установлена, однако физическое выделение,
точный показ, семь сценариев/десять повторов/30 минут совместной работы и полный
набор системных метрик остаются открытыми. Новые found gaps также блокируют
закрытие S5/S8/S9/S10; веха не закрывается по smoke или установке.


## 18 сентября 2026, 11:02 UTC — S8/S9: полные installed обратные цепи в паре 96

Два найденных на production95 отказа исправлены у прежнего Core inverse owner:
обычная транзакция теперь сохраняет адресные before/after hashes уже существующим
`withActionRecordCapture`/`lifecycleInverse`; undo пишет прежний `restorationInverse`.
Disposable `action_field_restorations` доказывает также неявную existence и полный
placement register. Условная зависимость проверяется при использовании, поэтому
порядок receipt UUID при rebuild/snapshot не создаёт и не теряет авторство.
Полное равенство ContentFieldVersion/frontier обязательно; совпадение видимого
содержания или human A→B→A не даёт права удалить человеческое продолжение.
Новый durable протокол, таблица истории, второй writer или ослабление CAS не добавлены.
Старым receipts без inverse evidence происхождение не приписывается.

`.build/s8-provenance-chain-20260918/` хранит реальные RED lifecycle/graph,
**37 Core tests / 7 suites PASS** (6.333 s), before/after хеши 380 неизменных входов
и overlay proof. Проверены 0/1/2 inverse graph chains, независимые rename/append/
move/full chains, human ABA/frontier negatives, rebuild, received retained sources
и настоящий addressed remote delivery. SequentialUndo fixture больше не обходит
blob dependency admission: missing inverse отказывает до ACK и не сдвигает cursor.
Общий рабочий tree в момент проверки содержал незавершённый чужой feedback/import;
его compile failure не объявляется регрессией этого исправления и не скрывается
как PASS: проверен отдельный неизменный source artifact, не вторая рабочая ветка.

`.build/s8-provenance-signed96-20260918/evidence/verification.json`:
**78 MCP + 8 signed Mac tests PASS**, 0 failed/skipped/runtimeWarnings.
Это реальные sandboxed JS/TS/XPC/queue сценарии lifecycle, graph reflow/create undo,
source/state, ink, conflict/delta, lost replies, immutable results. В build log
сохраняются два прежних unnecessary try/await compiler warning графического теста.
Source artifact — `a01887b` плюс ровно семь собственных code/test/version файлов;
ни tracked, ни untracked peer WIP в него не включён. Все семь overlay побайтово
сверены с рабочими файлами до установки.

`.build/s8-provenance-release96-20260918/build.json`: verified-build **0.3.93 (96)**,
source `dc1a33bcc876e1afe4f8596c39329bb5220ad1c47253e60c648932c0159815a1`.
Mac UUID `7C5779BB-D1FE-30B0-B8BE-BA98D63EDFEC`, CDHash
`d4336525c4dfe4ae308e14169cb1ce0972252b53`, manifest
`06b965120b347bb7f108a99445c6a2b3ceee2f393087626789622089d1e8daeb`.
iPad UUID `AE678DC3-44B0-3B12-8CCC-DD850F5A5313`, CDHash
`9c4dc156842d9c720b3bdd5a1251cbb8da3db891`, manifest
`42fda1dfb18185a20daf1f451d5986a3c09f4668d26bd8a794636b3004818767`.
`.build/s8-install96-20260918/` подтверждает update прежней production-пары и
обычный запуск iPad PID 5569; контейнеры/идентичности/доверие сохранены. Только
bundle replacement после idle preflight/normal Mac termination; без force kill,
архивов, backup и сбросов. Проверена идентичность frozen source, не меняющегося WIP.

**Установленный SDK, не test helper:**
- `.build/s8-installed96-lifecycle-20260918/receipt.json`: PASS 14 действий /
  36 внешних вызовов, весь create→rename/place→append→delete/restore children→
  delete/restore explicit tree→undo append→undo rename/place→undo children→undo board.
  Semantic nonempty refusal/operation index/atomic rollback и исторические
  actionVersion/replay также PASS. Временные предметы удалены именно полной
  обратной цепью, а не отдельной скрывающей сбой cleanup-транзакцией.
- `.build/s9-installed96-20260918/receipt.json`: PASS graph create→algorithmic
  reflow→undo reflow→undo create; scope refusal атомарен, authored/computed geometry
  прочитаны. Document source/structure/state/stale refusal/independent undo и
  persisted PDF export PASS. PDF 23 711 bytes, SHA256
  `a1c17d8512e6de67bb337902a5ebf739f040b3f8660a5037a4d99ce3ef18301b`
  совпадает с receipt; PDFKit: одна страница, Before и counter. TeX system-font
  warnings сохранены; переносимая побитовая воспроизводимость не заявляется.
- `.build/s10-installed96-20260918/receipt.json`: PASS свежий двухинструментный MCP,
  JS/TS read equivalence, TS7.0.2/SDK e44af80…, immutable retry/language conflict,
  type error до любых эффектов/events и исходная строка runtime diagnostic.

В обоих изменяющих сценариях все собственные временные owners удалены:
itemCount 7→7, presence/выбранные адреса не изменены. Normal export/receipt/run
history остаётся у своего владельца. Выявленные S8/S9 provenance gaps закрыты
реальным установленным путём. Runtime всё ещё свежий **disconnected**, поэтому
saved не означает received/shown. Физическое выделение/чернила/композиция,
семь сценариев × десять повторов, 30 минут совместной работы и системные метрики
не объявляются пройденными. S5/S7–S10 и общая веха пока остаются In Progress.

## 18 сентября 2026, 11:27 UTC — S10: физическая приёмка выявила отказ подключения

Установленная production-пара **0.3.93 (96)** проверена на настоящем iPad
`00008103-001E059934D9001E`: standalone XCTest только управляет прежним приложением,
не заменяет bundle, не подставляет acceptance root/fixture и не меняет хранилище.
Открытый штатным меню экран «Подключение и устройства» показывает idle, поле
приглашения и отсутствие доверенного Mac; public runtime — disconnected,
selection — unknown. Это состояние Notebook, не вывод об USB или сети вообще.

После явного согласия Амира на сопряжение в 11:13 UTC Mac создал обычное приглашение
для прежнего пространства. На iPad подтверждено точное равенство введённого текста,
исчезновение клавиатуры и стабильное положение доступной кнопки. Нативные нажатия
«Подключиться» не открыли подтверждение и не показали pairing error; приложение
осталось idle. **Сопряжение не состоялось; received/shown не приняты.** Причина ещё
не доказана. Сохранённое на Mac доверие не отзывалось, контейнеры/ключи/пространство
не сбрасывались. Приглашение истекло; временная plaintext-копия и переменная теста
удалены. Исторические UI/log attachments могут содержать приглашение и публично
не выкладываются. Результат: `.build/s10-live-acceptance96-20260918/receipt.json`.

Во время взаимодействия Cloud-статус стал enabled, источник изменения не установлен.
Агент ошибочно нажал «Выключить», приняв это за побочный эффект проверки, затем
прекратил изменять Cloud. Итоговый UI — paused/error13 с кнопкой включения. Амир
уведомлён; данные не удалялись, повторное включение не выполнялось. Этот побочный
эффект не скрыт под успешной приёмкой. Конкретный отказ и состояние переданы
единственному владельцу подключения **GUI-228**; параллельный pairing fix не создан.
Xcode и iPad освобождены для согласованной очереди 97→98→99. S10 остаётся открыт.

## 18 сентября 2026 — структурная вставка tldraw, GUI-205

Срез добавляет один `NotebookTldrawImport.prepare` для iPad/Mac и `nb.prepareTldraw`.
Выбранные поддерживаемые предметы становятся обычными отдельными элементами,
внутренние привязки получают новые ID; UI сохраняет пакет одной существующей
нативной командой, агент может изменить композицию до обычной `transaction`.
Внешний HTML не исполняется, вложения не загружаются. Выбранный неподдерживаемый
предмет блокирует пакет с явной диагностикой; снять его выбор можно до вставки.
Группы раскрываются в отдельные предметы, не обещается полный профиль tldraw.
Точный профиль и ограничения — `docs/editable-graphics-contract.md`.

Проверено:
- `swift test --filter NotebookTldraw`: 9 Core-тестов и 1 Host-тест, включая
  независимо сжатые v1/v2/v3, Unicode, нормализованный HTML-атрибут, подмножество,
  remap/dependencies, поворот групп/круга, auto-size текста, пределы/невалидный
  ввод, атомарную запись, reopen и undo на листе/доске.
- Физический iPad `00008103-001E059934D9001E`: 3 выбранных XCTest PASS,
  0 skipped/failed/runtime warnings. Системная вставка → снять неподдерживаемое
  изображение → вставить 3 предмета → перенести узел пальцем и проверить
  изменение связанной стрелки → удалить только узел → перезапустить.
  Оба жестовых сценария исполнены на доске и листе; отдельный native тест
  проверяет приоритет HTML и общую отмену пакета.
- Первоначальный UI runner не записал UIPasteboard из фонового процесса:
  непосредственный readback оказался nil. Исправлена подача fixture в DEBUG
  foreground при явном isolated launch flag, не обход системной PasteButton.
  Release не содержит этого seed. Это не доказательство живого копирования
  в Safari/Chrome и не физического Pencil.
- Подписанный sandboxed Mac XPC исполнил TypeScript: prepare подмножества,
  раздельная композиция двух предметов, обычная transaction, адресное чтение
  и одна причинная undo. `saved` confirmed, `shownOnIPad` не выдан за confirmed.
- MCP: strict typecheck/generated-resources check и 78 контрактов PASS.

Источники проверки изолированы от одновременно незавершённых GUI-227/GUI-228.
`/Users/amir/Documents/projects/Notebook/.build/tldraw-final97e` — физический
маршрут 3 iPad + 1 Mac, source SHA-256
`9f047070e7d7a5335f02a410913641e948a29c52a785bf3894e81902a8ccfbc4`.
После него удалена случайно захваченная чужая строка `present.returns`, которая
рекламировала ещё не включённый attention; поменялись ровно
`MCP/src/sdk-contracts.ts` и generated `sdk-reference.json`, ни один вход
приложения iPad/Core не изменился. На финальном source SHA-256
`7fb57891f75e2b02b9f100790b2d8a8a11437c0a850447f7c453bb9057ba5aeb`
повторены MCP и signed Mac SDK:
`/Users/amir/Documents/projects/Notebook/.build/tldraw-final97f`.
Сборка следует этому выбранному маршруту, а не объявляет полный PASS.
Скриншоты preview и отдельных связанных предметов из физической проверки
просмотрены; первая попытка Mac GUI-осмотра ограничена ошибкой CUA/ScreenCaptureKit
-3811 при открытии TextEdit. Это не заменено утверждением о ручной приёмке Mac.

Полная приёмка GUI-205, все формы/изображения/рисунки tldraw, десять повторов,
30 минут смешанной работы и системные измерения этим срезом не закрываются.
Межустройственная доставка не подтверждена: на установленной 96 паре найдена
отдельная проблема сопряжения, её владелец — GUI-228. Локальная вставка не
создаёт нового владельца записи или отдельного канала синхронизации.

Установлена подписанная **0.3.94 (97)** из
`.build/tldraw-release97c/build.json` (`verified-build`) на Mac
`/Users/amir/Applications/Notebook.app` и физический iPad. Версия, подписи,
манифесты и успешный запуск подтверждены в `.build/tldraw-install97/`.
Mac остановлен обычным `NSRunningApplication.terminate`, без принудительного
завершения; контейнеры, ключи, доверие и содержание сохранены. Тестовые
приложение и runners удалены; `apps-clean.json` подтверждает единственный
пользовательский Notebook Lab 0.3.94 (97).

Уже установленный MCP через публичный context и подписанный TypeScript sandbox
вызвал `prepareTldraw` / `nb.prepareTldraw`: одинаковые три редактируемых предмета,
пустой список полномочий подготовки, заголовок пространства неизменен,
0 write effects (`.build/tldraw-live97/receipt.json`). Это read-only smoke,
не подтверждение доставки на iPad. Экспорт staged-исходников совпал с финальной
проверенной сборкой по source SHA-256
(`.build/tldraw-index-source-match.json`); чужие незавершённые правки не включены.

## 18 сентября 2026, 12:02 UTC — Cloud snapshot: устранено устаревшее ожидание теста

Отказ `snapshotRetainsDeletionEvenWithoutHistoricalDeliveryRows` воспроизведён
на чистом `6b12201`, без account/transport WIP. Тест требовал физического удаления
PAGE, хотя S8 (`9949e4a`) намеренно сохраняет скрытый источник для поздних человеческих
правок и undo. Runtime не менялся. Теперь проверяются новый и существующий
получатели Cloud snapshot без `change_records`, затем повторное открытие Store:
каталог/живая принадлежность отсутствуют, правильный PAGE source сохранён, публичные
load/header отказывают, поиск не возвращает скрытый текст (до удаления находил его).
**23 теста / 4 suite PASS**, включая retained lifecycle undo и retired document/board.
Команда: `swift test --package-path .build/s10-cloud-retirement-20260918/source
--filter 'NotebookCloudDeliveryTests|NotebookRetainedLifecycleUndoTests|NotebookRetiredDocumentSourceTests|NotebookRetiredBoardAdmissionTests'`.
Источник — `6b12201` плюс единственный изменённый тест; RED и GREEN2 сохранены в
`.build/s10-cloud-retirement-20260918/`. Физическая связь этой проверкой не подтверждается.

## 18 сентября — единое внимание агента и Shimmer + Mesh (GUI-227), 0.3.95 (98)

`NotebookAgentFeedback` заменил `NotebookAgentPearl` и прежний таймер истории.
Новый результат начинается после установки точного видимого источника, серия
правок сохраняет фазу, внеэкранные и уже потреблённые результаты не воспроизводятся
снова. Перестановка ограничена уже прочитанной сценой. `present.steps[].attention`
использует тот же материал и жизненный цикл представления, без захвата выделения
человека или движения камеры. Канонические снимки не содержат transient-эффект.

Проверенный неизменный срез — `7848fd8` + GUI-227, source SHA-256
`61327b6623686a7a4973185b7c5e487b6cd307611dc1b9ca419416eddfc21618`.
Квитанция выбранного маршрута: `.build/gui227-final98e/verification.json`.
Профили `presentation`, `verification`; дополнительно `NotebookAgentFeedbackTests`,
`NotebookGraphicInteractionTests`, адресный тест `DocumentProgramOwnerTests`
и настоящий жест `NotebookAgentFeedbackUITests`:

- **18 physical iPad native/UI PASS**, iPad `00008103-001E059934D9001E`, iOS 27.0;
  **3 Mac relay PASS**; failed/skipped/runtime warnings — **0**.
- **19 Core/Codex PASS**, **79 MCP PASS**, TypeScript check PASS;
  **79 release-contract + 81 verification-contract PASS**.
- Ещё **10 Core feedback/history PASS** на том же отпечатке:
  `.build/gui227-core98e/{tests.log,source-before.json,source-after.json}`.
- Проверены настоящие добавления фигуры и штриха на лист/доску, одинаковые bounds
  разных штрихов, точное попадание нескольких эффектов в геометрию, отсутствие
  изменённых пикселей вне этих предметов, перекрытие, Reduced Motion и окончание.
  Живой документ сохраняет paper/program owners, DOM, кнопку, ввод и first responder;
  реальный drag не сдвигает камеру или соседнюю программу.

PNG из `.build/gui227-final98e-attachments/` осмотрены: Mesh остаётся внутри
заливки/программы, Shimmer — на контурах/буквах, текст программы не выбелен.
Промежуточный зелёный прогон `98c` **не был принят визуально**: дети Timeline
выстроились вертикально и подсветка ушла с предмета. Единый ZStack viewport и
пиксельная регрессия исправили дефект. Реальный WebKit также выявил ненужную
зависимость служебного SVG ID от `crypto.randomUUID`; теперь локальный счётчик
проверяет коллизии с существующими DOM ID. Прежние реализации удалены.

Release-квитанция — `.build/gui227-release98b/build.json`, `verified-build`,
выбранный, не полный маршрут. Mac и физический iPad обновлены **0.3.94 (97) →
0.3.95 (98)**; `.build/gui227-install98/` содержит preflight, подписи/manifest,
нормальную остановку helper и devicectl install/launch/readback. Контейнеры,
идентичности, доверие и архивы не заменялись; тестовые iPad-приложения удалены.
Установленный sandboxed TypeScript SDK принимает тип attention, отдаёт новый
`help('present')`; read-only smoke завершился с **0 write effects**, неизменным
workspace header и cursor: `.build/gui227-live98/receipt.json`.

После заморозки соседняя задача внесла `d5bf3a5` только с CloudDeliveryTests и
исторической квитанцией. В staged дереве все product inputs совпадают с этим
проверенным срезом; единственное отличие build inventory — уже отдельно проверенный
`Tests/NotebookCoreTests/NotebookCloudDeliveryTests.swift`.
Сравнение: `.build/gui227-staged98-source.json`. Чужие GUI-228/UI WIP не вошли.

Граница: production Mac↔iPad ещё не сопряжены; live доставку новой подсветки между
ними эта проверка **не подтверждает**. Автосвязь относится к GUI-228. Не заявлены
полная приёмка, системные FPS/CPU/GPU/память, десять повторов и 30 минут совместной
работы. Реальные жесты выполнены на физическом iPad, не в Simulator.

## 2026-09-18 — GUI-228, автоматическое подключение: проверенный кандидат, не выпуск

Один account owner заменяет приглашения, QR, ручное подтверждение и установочные
pairing grants. Private CloudKit directory выдаёт собственным Mac/iPad одного
пространства общий ключ; сохранённые установленные ключи сохраняются однократным
чтением данных. Protocol 23 не исполняет старый enrollment. Новый получатель
ожидает существующий материал, не создаёт вторую начальную тетрадь и не публикует
пустой cloud snapshot. Принятый локальный ввод отменяет автоматическое открытие
другого пространства; завершение очереди и финальный cut не оставляют запись
позади. Самостоятельные наполненные пространства не объединяются.

Изолированный candidate `.build/gui228-source99` основан на `b202630` и содержит
только GUI-228, временная версия **0.3.96 (99)**. UI100 из соседней задачи сюда
не включён; корневая установленная версия на момент проверки — **0.3.95 (98)**.

- `.build/gui228-mac99d/verification.json`: **25 Core + 21 Mac native PASS**.
- `.build/gui228-ipad99-native/verification.json`: **49 native PASS** на
  физическом iPad `00008103-001E059934D9001E`, iOS 27.0. Проверены настоящий TLS,
  отказ неверному ключу, admission до курсора/содержания, account lifecycle,
  Keychain, сохранение block/credentials, receive-first и chat state.
- Оба native receipt имеют source SHA-256
  `5454adc61d24baa644bd076c63124c0a3cf903fa027c7fb16205f3ac76f4c345`.
- `.build/gui228-ipad99-ui-final/verification.json`: **2 physical UI PASS**,
  открытие/закрытие «Устройства» без формы подключения и перенос/resize чата с
  открытием настроек без сдвига бумаги. Source SHA-256
  `bc0a27e3d88054a2975117641e1530e0c6902c75e324430b17ca8fe0867d27ca` отличается
  только двумя UI-тестами: системный Menu отдаёт label «Устройства», но не
  SwiftUI accessibilityIdentifier. Фактическая AX-иерархия обнаружила ошибочный
  селектор, исправлен тест, а не системное меню.
- Failed/skipped/runtime warnings в принятых receipt — **0**. PNG
  `devices-without-setup` из xcresult осмотрен; это отдельный `.native-test`,
  не скриншот обновлённого production. Симуляторы не запускались.
- Первые Mac попытки сохранены отдельно: старая проверка manifest 6 заменена
  currentFormat; исправлены bootstrap FIFO self-count и Keychain cleanup на
  main thread. Неудачный UI-прогон `.build/gui228-ipad99-ui-run` не принят.

После этих receipt только callback `shouldOpenDefault` сведён к тому же
`mayAutomaticallySwitchWorkspace`, чтобы первичное обнаружение и переключение
не имели двух разных admission-проверок. Это последующее изменение не
приписывается предыдущим runtime receipt. Полный Shared+Mac Swift 6
strict-concurrency typecheck после него PASS:
`.build/gui228-final-typecheck/result.json`. Перед выпуском нужно проверить
окончательный срез вместе с версией пары.

**Граница: GUI-228 не выпущен.** Новая schema `NotebookDevices` (encrypted private
field, без public grants) ещё не опубликована в Production: CloudKit Console
ждёт входа владельца Apple Developer. Установленная пара, контейнеры, identities,
Keychain и отключённая ранее content sync не изменены. Не подтверждены реальное
первичное account enrollment, восстановление Mac↔iPad, live SDK delivery/shown
и новый cloud observer. До schema и сквозной проверки автосвязь не объявляется
готовой; общий HEAD/версия не меняются до окончания соседнего UI100 выпуска.

### GUI-228 — Production schema опубликована, 12:58:52 UTC

После входа владельца Apple Developer CloudKit Console подтвердила
«Changes Deployed — The schema is deployed to Production» для контейнера
`iCloud.com.amirtlinov.notebook`, команда `M94V58FCVP`. Проверенный diff между
Production `eec85ef0-b276-11f1-9375-874dd3c05d46` и Development
`9c309d20-b360-11f1-9483-b9bc18929f33`: только новый `NotebookDevices`, поля
`directory ENCRYPTED BYTES` и `format INT64`, ноль изменений индексов/ролей.
Автоматические public grants нового пустого Development-типа сняты до публикации;
у `NotebookDevices` нет grants `_world`, `_icloud`, `_creator`. Права Users,
NotebookBlob и NotebookDelivery не менялись. Ни записи, ни ключи вручную не
создавались; application enrollment ещё должен пройти обычный runtime.
Свидетельство: `.build/gui228-cloud-schema/deployment.json`.

## 2026-09-18 — GUI-229, явный вход в тетрадь; меню действий GUI-205

Тетрадь и документ открываются двойным нажатием, закрываются явной кнопкой
«Назад». Зум меняет только камеру: не выбирает другого владельца, не складывает
лист и не сбрасывает выбранную страницу. Прежняя физическая обложка раскрывается
в том же camera settlement за 0.30 s с bounce 0.025; новая параллельная анимация
не добавлена. Короткий переход заканчивается целиком, а отложенные callbacks
предыдущего жеста не перезаписывают его назначение. Старые opening/docking
типы и заменённые пути удалены. Переходы вложенных **досок** через zoom сохранены;
выбранная закрытая тетрадь остаётся объектом доски, а не владельцем её камеры.

Отдельная синяя вставка заменена монохромным ключом «Действия». Непрозрачный
native popover содержит раздел «Добавить», строку «Из tldraw» и системную
PasteButton. Открытие меню clipboard не читает. Существующие импорт, выбор
объектов, bindings, undo и физическое назначение не переписаны; после вставки
закрывается и popover. NotebookTldrawPasteControl удалён.

Область — собственный cut `.build/actions-source` от `b202630`, без незавершённого
GUI-228. Исторические архивы, содержимое, identities и trust не изменены.

Проверки и границы:

- Core camera/world-address/document geometry: **28 PASS**, `.build/gui229-core.log`.
- Первый физический `.build/gui229-physical100a`: **26 PASS / 1 FAIL**. Жесты
  тетради, документа и Actions прошли; selected closed notebook блокировал
  выход из вложенной доски. Исправлен runtime predicate принадлежности камеры
  и добавлена native-регрессия. Этот прогон не принят как выпускной.
- Предшествующая `.build/actions-physical-a` не дошла до test body из-за
  `Timed out while enabling automation mode`; это не PASS.
- На неизменном исправленном SHA `83404218a0c2c36f4159c02f6b0470b08fde0e2343dfe2f5d5419e69d6d981ac`
  `.build/gui229-physical100b`: **26 PASS / 1 FAIL**, а отдельный повтор
  `.build/gui229-portal100c`: **1 native PASS / 1 UI FAIL**. Оба UI-сбоя произошли
  до проверяемого выхода из portal: после синтезированного касания «Тетрадь»
  системное Create menu осталось открытым. Запись экрана, AX-иерархия и точные
  координаты сохранены; runtime/test не обошли ретраями. Это отдельный **GUI-230**,
  пока без заключения «продуктовый дефект» или «ошибка automation». Полный
  physical portal round-trip не заявлен; mounted native passage включая
  выбранную закрытую обложку подтверждён. Финальная выбранная область ниже
  исключает только этот незавершённый UI-сценарий создания, не скрывает его сбой.
- Окончательная выборочная квитанция `.build/gui229-final100/verification.json`:
  **20 native + 6 UI PASS** на физическом iPad `00008103-001E059934D9001E`,
  iOS 27.0; failed/skipped/runtime warnings **0**, source SHA тот же.
  Подтверждены сильное уменьшение без выхода, перелистывание после zoom,
  Back, double tap на выбранной/смещённой обложке, документ и обе поверхности
  вставки из tldraw с редактированием и восстановлением после перезапуска.
  PNG финального раскрытого листа и Actions на бумаге осмотрены.
- `.build/gui229-index100-match.json` подтверждает побайтовое совпадение build
  inputs подготовленного commit с проверенным cut. Чужие account/chat правки
  и их записи verification не включены.

**Установка на момент этого commit ещё не выполнена.** Срез имеет версию
0.3.97 (100), но по согласованию с одновременно завершающимся GUI-228 он войдёт
в одну подписанную пару 101, чтобы не выполнять две последовательные установки.
Production пока 0.3.95 (98). Установку и очистку `.native-test`/runner подтверждает
отдельная последующая квитанция GUI-228/101. Полная приёмка, системные
FPS/CPU/GPU/память, десять повторов и 30 минут совместной работы не заявляются.

### GUI-228 — финальный source 101c, 13:25 UTC

Проверенный общий срез **0.3.98 (101)** основан на `3c7e35e` и включает
GUI-229/Actions100, но не следующий отдельный clipboard WIP. Источник:
`.build/gui228-source101c`; SHA-256
`73e87b34266940ad4e54624a6d88041eb3b923d5aff848ac8d818194a4914073`.
`.build/gui228-final101c/verification.json`: **25 Core + 22 Mac native +
50 physical iPad native + 4 physical UI PASS**, без failed/skipped/runtime
warnings. UI покрывает «Устройства» без формы подключения, перемещение/resize
чата и открытие настроек, pinch без semantic enter/exit с double-tap/Back,
редактируемую вставку объектов. PNG `devices-without-setup` осмотрен, это
подписанный изолированный test host, а не live production.

Итоговый review обнаружил запрещённые Apple два CKSyncEngine для одной private
базы. До выпуска account observer заменён на прямую private-zone push-подписку
с AppDelegate; прежний второй engine удалён полностью. Push только запрашивает
повторное account-чтение, не несёт доверие; смена владельца/устаревший stop и
чужие payload проверены native-тестом. Cloud content остаётся единственным
CKSyncEngine. Полный Shared+Mac Swift 6 typecheck PASS, журнал
`/tmp/notebook-account-push-mac2.log` пуст. Предыдущий успешный receipt101
предшествует этой правке; failed101b содержит промежуточную compile-ошибку,
не использован для выпуска. Установка и живое соединение на этом этапе ещё
не проверены.

### GUI-228 — установленная пара101, разные сохранённые пространства

`.build/gui228-release101/build.json` имеет `verified-build`, тот же source101c,
Mac manifest `353b8333e19cd9c76af6acb0aa9491b872bff56d17fb8d30aaf47104bed3bc31`,
iPad manifest `40976c6da8612731ff20fa694ee9571633faccd4dde5ff5217dc0acbb0a29f32`.
Пара **0.3.98 (101)** установлена 18 сентября около13:27:58 UTC:
`.build/gui228-install101/{artifact.json,mac-installed.json,apps-after.json}`.
Mac PID80671 запущен из `~/Applications/Notebook.app`; helper98 завершён обычным
NSRunningApplication.terminate, без forced kill. Контейнеры, SQLite, identities,
Keychain и архивы не удалялись/не восстанавливались. Перед заменой app bundle
проверены нулевые активные native/SDK задания, терминалы, голос, файл и ввод.

Реальный Mac показывает новый статус устройств и два account-пространства,
то есть directory enrollment прошёл. Соединение пары пока не подтверждено:
read-only чтение фактических баз установило **разные** workspaceID:
Mac `FAAAC405-8EF9-4FB9-9B93-CBD876FA97A4`, iPad
`6E14684D-3135-4A86-8E26-289CEB06835E`. На iPad сохранено `cloudEnabled=0`,
на Mac `cloudEnabled=1`; оба bound, выбор не переопределён.
`.build/gui228-live101/workspace-identities.json` хранит только эту диагностику.
MCP сохранил workspace/board revision и cursor11133; presenceGeneration0 не
выдаётся за живую доставку. Приложение верно не слило два наполненных пространства.
Амиру задан выбор общего пространства с сохранением второго отдельно; до ответа
не выполняется скрытое переключение. GUI-228 остаётся In Progress: live
connection, delivery/shown и reconnect после выбора ещё открыты. Это отдельная
граница от успешно установленного и проверенного исходного среза.

## 18 сентября 2026 — обычная вставка без отдельного tldraw-входа, GUI-231

Версия 0.3.99 (102). В Actions осталась одна компактная системная PasteButton,
без карточки, заголовка источника и поясняющего экрана. Цвет приведён к общей
нейтральной палитре. Текст, HTTP(S)/mailto-ссылка, обычный JSON и изображение
определяются по представлениям буфера; простые материалы сразу записываются.
Структурный фрагмент автоматически открывает композицию с выбором объектов,
а не превращается в снимок. На Mac обычный пункт «Вставить…» явно показывает
поверхность назначения и захватывает содержимое по команде пользователя.

Удалены прежние `NotebookTldrawPaste`, `NotebookTldrawPasteView`,
`NotebookTldrawDestination` и `NotebookMacTldrawWindow`; совместимых обёрток нет.
Форматный `NotebookTldrawImport` сохранён как действующий конвертер.
`NotebookPasteFragment.operations` и `insertClipboardFragment` ведут в прежний
атомарный native action / persistence / undo, без второй записи или модели.
Произвольный HTML не запускается, удалённые ресурсы и локальные file-URL
не загружаются; неподдерживаемый или слишком большой материал отклоняется
целиком. ImageIO нормализует изображение без персональных метаданных.

Проверен неизменный source
`3d8daee7de9501e65dcf76be98510d7da7914a5d2a7147574de2d6c61f42088d`:
- `.build/gui231-final102b/verification.json`: 8 iPad native + 6 физических UI
  + 2 Mac native, 0 ошибок, пропусков и runtime warnings.
- На физическом iPad пройдены обычные текст/ссылка/изображение, выбор текстового
  представления HTML, закрытие popover, выбор/удаление и перезапуск; структурная
  схема на листе и доске сохраняет отдельные фигуры и привязку при переносе.
- Mac проверен через настоящий NSPasteboard с изолированным именем,
  сохранение/undo через AppModel. Это не отдельный ручной жест в macOS menu bar.
- `.build/gui231-core102.log`: 9 Core-тестов структурного импорта PASS.
- Скриншоты `.build/gui231-final102b-images/` просмотрены: компактная серая
  вставка, материал на листе, композиция. Первый 102a тоже прошёл 16 тестов;
  отдельный ранний `.build/gui231-mac102a` выявил ошибку новой undo-фикстуры
  без активного owner; исправлена настройка presence, не рабочий undo.
- `.build/gui231-index102-match.json`: входы staged-среза совпадают с source;
  чужая незавершённая GUI-228/103 переработка CloudKit не включена.

Это проверка затронутого clipboard-сценария, не полная приёмка:
все внешние приложения/форматы, 10 повторов и 30 минут не заявляются.

Подписанная Release-пара собрана существующим строгим маршрутом
`.build/gui231-release102/build.json` и установлена 18.09 около 13:50 UTC:
`.build/gui231-install102/{artifact.json,mac-installed.json,ipad-install.json,
ipad-launch.json,apps-clean.json}`. Mac PID после штатного graceful quit/start —
90441; установленные Info.plist и iPad app inventory подтверждают 0.3.99 (102).
Прежние приложения заменены in place, контейнеры/идентичности/история сохранены.
Собственные `.native-test` и `.uitests.xctrunner` удалены; SDK installed-acceptance
runner передан владельцу S10 для следующей живой проверки, не оставлен архивом.
Отдельная незавершённая переработка account-доставки GUI-228 остаётся за этим
выпуском; обычный рестарт Mac не объявляется исправлением её push-пути.

## 18 сентября 2026 — единый CloudKit owner и применение первого снимка, GUI-228

Пара 0.3.100 (103), исходники
`60381ed1803e1a20bf40cedf4e13ac9e495e8c7ae8d924b2cff07fa2064107fa`.
Ручного подключения по-прежнему нет. После разрешения Амира на выбор/удаление
старых пространств iPad через интерфейс открыл Mac space `FAAAC405…97A4`.
Другой локальный каталог сохранён; объединение не понадобилось.

Live101 обнаружил устаревший ключ на Mac после выбора пространства iPad
(`unknown PSK identity`). Перезапуск в отдельном выпуске102 обновил ключ,
но сам по себе не исправил доставку directory events.103 удаляет direct
CKRecordZoneSubscription/AppDelegate-маршрут: account zone и optional content
zone обслуживает единственный CKSyncEngine. Выключенный обмен содержанием
не разрешает engine читать/писать материалы; scope ограничен account zone.

Live102 затем показал `placement_checkpoint_required`. Read-only копия новой
реплики iPad доказала, что coherent snapshot679 уже скачан (3408blobs,
missing=[]), а применение падает на `board member address`: историческое
отсутствие неизвестного board member ошибочно требовало живую схему.
Теперь отсутствие на обеих сторонах ничего не декодирует и не создаёт;
непустой неизвестный член по-прежнему отклоняется. Нет декодера старой доски,
поднятия cursor, очистки журнала или восстановления архива. Тот же скачанный
snapshot применён на одноразовой изолированной копии: `apply 679` PASS.

Проверки выбранной области:
- `.build/gui228-final103/verification.json`: 10 Mac native, 35 physical iPad
  native + 1 physical UI, 0 ошибок/пропусков/runtime warnings.
- `/tmp/gui228-cloud103-core.log`:14 Cloud delivery Core-тестов PASS, включая
  новую регрессию пустой реплики с историческим отсутствием board member.
- `/tmp/gui228-103-typecheck.log`: strict Swift6 Mac typecheck PASS.
- `.build/gui228-release103/build.json`: подписанная Production CloudKit пара
  из указанного неизменного source103, не из текущих GUI232-правок.
- `.build/gui228-install103/`: установка поверх102 около14:05UTC, проверка
  manifests, штатное завершение Mac и запуск PID94183. Контейнеры, UUID,
  Keychain и активация не менялись.

После установки реальный SDK-сценарий delivery/shown/selection передан S10.
Эта запись фиксирует проверенный срез и установку, не подменяет его результат
зелёными XCTest. Полная приёмка/30 минут/10 повторов не заявляются.

## 18 сентября 2026, 14:07–14:17 UTC — S5/S7/S10: настоящая связь и физический полный цикл действия

Установленная production-пара **0.3.100 (103)**, source
`60381ed1803e1a20bf40cedf4e13ac9e495e8c7ae8d924b2cff07fa2064107fa`.
GUI-228 исправил применение уже скачанного snapshot; дополнительное сопряжение,
сброс контейнеров, восстановление архивов и ручное продвижение курсоров не понадобились.
Свежий установленный MCP подтвердил `connected` и `selection: known`.
Workspace `FAAAC405-8EF9-4FB9-9B93-CBD876FA97A4`; действующий iPad actor
`5124BDCA-7613-4E48-B09B-928D81A03D4E` (не исторический actor другой локальной копии).

Через установленный SDK v2 выполнена настоящая TypeScript-программа
(compiler **7.0.2**, SDK `37cac796b3fa7ea5d34401f67d189f37b21b9ef5693f7cc851cb02037cc28df8`):
создание своей временной тетради/фигуры → поиск названия обычным UI → double tap
по обложке → изменение подписи/положения → реальные select/clear/drag → SDK undo.

- Изменение `4C5369EB-64B4-4475-8B20-673BFBA29233`, версия
  `14d75c81c71caea3ba6c722cbb3e7778a378ece29ce4192c730eb2afb26c9115`:
  **saved / receivedByIPad / shownOnIPad confirmed** у одной точной версии.
  Снимки физического экрана до/после осмотрены: обе подписи действительно показаны.
- Native tap → blank tap → drag: `element(g12) → empty(g13) → element(g17)`;
  один session, точные page/element ID. Нет догадки о выборе по камере.
- Реальный drag передвинул фигуру из `(125,160)` в `(205,220)` и дошёл до Mac
  как human continuation. Undo восстановил подпись, **сохранил `(205,220)`**:
  `restored=1`, `preservedCount=1`; его exact-version received/shown также confirmed.
  Финальный физический screenshot осмотрен, не только прочитана квитанция.
- Своя временная тетрадь удалена штатной командой. Item count **7 → 7**, адрес
  больше не виден в каталоге; iPad сам вернулся на прежнюю доску. Последний blank
  tap снял наше выделение: `known empty`, root board, g20; связь осталась connected.
- Историческая ссылка после drag/undo сохранила прежний регион `(125,160)`.
  Это было указание без отправленного сообщения: attention честно вернул
  `pending / attention_not_delivered`. Приёмка исторических пикселей **не заявлена**.

Evidence: `.build/s10-physical-live-20260918/receipt.json`, public call/request/result
JSON и physical AX/PNG рядом; `.build/s10-live-acceptance96-20260918/installed103-*.xcresult`.
Первый selector ошибочно запустил **0 tests**, он исключён. Поиск по graphic label
не дал результата; навигация выполнена поиском названия тетради. Оба ограничения
сохранены в receipt, не выданы за успешные проверки.

Физический остаток **S5 закрыт** вместе с ранее проверенными fault/replay/cancel/
upgrade контрактами. S7 и S10 остаются открыты: отправленный исторический источник,
полная семёрка сценариев × 10, 30 минут совместной работы и системные кадры/CPU/GPU/
память этим коротким сценарием не заменяются. Simulator не использовался.


## 18 сентября 2026 — пространства как отдельные vault, GUI-232

Пара **0.3.101 (104)**, source
`6aace95157a5fb0613f8d19fb7ecdd1b641235c7eeedffabf945408dc0112dcc`.
«Пространства» — отдельный UI на Mac и iPad: создание с именем, открытие,
переименование, локальное удаление и удаление везде. Единственный lifecycle
owner — `NotebookApplicationLaunch`; заменённые callbacks открытия/возврата
и список пространств из «Устройств» удалены. Локальный каталог однократно
забирает прежний файл выбора и дальше записывает только новый формат.

Удаление последнего vault сохраняет пустую библиотеку при перезапуске,
не создаёт новое пространство автоматически. При удалении исходного vault
сохраняются installation activation marker, общий каталог работы Codex
и независимые исторические архивы. Global deletion сохраняет намерение,
затем CAS tombstone UUID, удаляет membership/keys, cloud zone и локальную копию.
Офлайн-реплика не может повторной регистрацией воскресить этот UUID.
Именование не меняет UUID, SQLite-адреса или существующие ключи.

Выбранная проверка неизменного среза:
- `.build/gui232-final104f/verification.json`: 28 Core, 24 Mac native,
  12 physical iPad native и 1 physical UI; 0 ошибок, пропусков/runtime warnings.
- UI прошёл настоящий ввод имени → создание → переименование → переключение
  → удаление обеих копий → перезапуск пустой библиотеки → повторное создание.
  Это изолированная `.native-test`, не подмена материалов установленной пары.
- Ранние UI104c/d не приняли нажатие Create; они не выданы за PASS.
  Диагностический срез подтвердил рабочий lifecycle; финальный редактор владеет
  своим черновиком, dismiss и ошибкой действия, не наследует запоздалую ошибку
  чтения каталога. Тест ждёт доступный hit target, не повторяет нажатия вслепую.
  Временной трассировки в выпускном коде нет.
- `.build/gui232-release104/build.json`: проверенная подпись Production CloudKit.
  `.build/gui232-install104/`: штатное завершение Mac, проверка bundle manifests
  и установка поверх103; рабочие контейнеры, идентичности и ключи сохранены.

Живое открытие Mac-окна104 обнаружило настоящий дефект, которого не показала
проверка lifecycle: NSHostingController с гибким List сжимал новое окно до 1×32.
В105 размером владеет AppKit: отключён preferred sizing hosting controller,
заданы minimum/content size; добавлен native regression настоящего NSWindow.

Финальная установленная пара **0.3.102 (105)**, source
`1b453f49c744a984c885e064c6dc4c3cd7a5c53e63fe45947044b64dc314fed9`.
Delta после104: только Mac window sizing, его тест и версия. Lifecycle/iPad UI
остались теми же. `.build/gui232-final105/verification.json`: 3 Mac native
и 2 physical iPad native, без ошибок/пропусков/runtime warnings.
`.build/gui232-release105/build.json` и `.build/gui232-install105/` фиксируют
подписи, bundle manifests и установку поверх104 с сохранением контейнеров.
Живой Mac105 действительно показывает окно нормального размера и создаёт vault.

Межустройственная приёмка установленной пары записана ниже отдельно; локальный
PASS и установка не заменяют её. Полный маршрут, 10 повторов и 30 минут не заявлены.


Живая пара105 (обычные установленные приложения, не fixture):
- Mac UI создал временное пространство `67AC36E0-F198-4C47-AD83-B04B24C216AE`;
  оно само появилось в библиотеке физического iPad и было открыто без pairing.
  Публичный установленный MCP подтвердил `connected` в этом UUID. Первое
  установление связи заняло около двух минут, мгновенность не заявляется.
- Переименование Mac → iPad подтверждено совпавшими локальными каталогами.
  Затем iPad UI переименовал его в «Проверка iPad 105», а Mac UI показал точное
  новое имя. PNG обеих платформ осмотрены; UUID остался прежним.
- Две ранние попытки iPad rename остановились до редактора: системное меню
  оставалось открытым после element/coordinate tap; XCTest каждый раз ждал
  `App animations complete notification` 60 секунд. После обычного перезапуска
  того же установленного105 menu → редактор → сохранение прошли. Причина
  первоначально непринятого контакта не установлена; эти отказы сохранены,
  не названы исправлением production-кода или доказанным дефектом XCTest.
- Ранние Mac-проверки неверно заменяли текст через Cmd+A/End. Проверка точного
  draft до Save и обычный Cmd+Right + delete устранили ошибку драйвера;
  финальное имя подтверждено UI и каталогом, не только отсутствием исключения.

Evidence: `.build/gui232-installed104/` (имя папки сохранено после обновления
на105): `mac-create105`, `ipad-open105`, `mac-rename105-keyboard`,
`ipad-rename105-restart`, `mac-remote-rename105` — по одному исполненному PASS
в соответствующих xcresult; `temporary-runtime.json` — публичный MCP.

- iPad UI: «Удалить везде» → явное подтверждение → исчезновение временного vault
  → открытие исходного пространства. Mac UI подтвердил удалённый vault и также
  открыл исходное. `ipad-delete105` и `mac-remote-delete105`: ещё по 1 PASS.
  Финальные PNG осмотрены. Всего 7 исполненных live UI-проверок установленной105.
- Оба каталога выбрали `FAAAC405-8EF9-4FB9-9B93-CBD876FA97A4`; временного UUID
  нет ни в entries, ни в pending/deleting, ни в локальных папках обеих платформ.
  Свои native-test и UI runner приложения удалены; production-контейнеры и
  отдельно идущая SDK-приёмка не затронуты.
- Публичный MCP в 15:35 UTC: **connected**, исходный workspace, **7 items**,
  физическое iPad selection **known empty**, root board. Сохранены
  `final-runtime.json`, `mac/ipad-final-catalog.json`, `ipad-final-spaces-files.json`
  и сводный `live-receipt.json`. Runtime источники105 совпадают с финальным tree;
  после сборки менялась только эта документация.

Xcode/физический слот передан отдельной приёмке SDK S7–S10 на неизменной105;
выбранный сценарий пространств не выдаётся за её длительную полную приёмку.

## 18 сентября 2026 — S7: реальный выбор после первых32 и источник отправленного сообщения

Production **0.3.102 (105)**, неизменный source
`1b453f49c744a984c885e064c6dc4c3cd7a5c53e63fe45947044b64dc314fed9`.
Установленный Mac совпал со всеми363 записями release manifest; physical
`00008103-001E059934D9001E`, bundle `com.amirtlinov.notebook.preview`105.
После GUI-232 pair вернулась в `FAAAC405-8EF9-4FB9-9B93-CBD876FA97A4`,
connected, исходный itemCount7. Архивы, идентичности и доверие не менялись.

В собственной временной тетради публичный SDK создал64 посторонних элемента,
затем два узла/связь и настоящий ink stroke. Физический tap выбрал `node-a`
(позиция64 из67), `observe({})` вернул именно его. Tap в пустом центре страницы
снял выбор: `known/empty`, новая generation, тот же physical page. Native PNG
показывает исходную схему A→B и штрих; публикация не двигала их.

Через настоящий iPad chat отправлено сообщение с выбранным объектом; отдельная
временная задача `01a0b52e-18a5-78b0-9775-b95cf658ab94` завершилась ответом
`SDK-HISTORY-OK`, без tools/изменений модели. Контекст
`324BCD5E-7A8A-4238-B079-780F8C787EE8`, reference
`D9897D43-9AF9-415C-B6D0-CF7141CB62C9`: attention действительно
`source_pixels`,200×200, SHA256
`aa2eca3ddd2cf5599c6c4216d3803aa86c74dc1dfcbabbd6cdc22225c505c837`.
`emitImage` прочитал исторический артефакт; прозрачный PNG содержит чёрную рамку
и исходную A, а не новый рендер. После SDK-подписи `Now`, физического next/previous
page и проверки новой подписи **artifact/hash/payload побайтно по JSON совпали**.
S7/GUI-216 закрыт; S8–S10 ещё принимаются.

Evidence: `.build/s10-complete-20260918/history-receipt.json`,
`history-before.json`, `history-after.json`, `history-source-1.png`, public
requests/replies и native `.xcresult`/AX/PNG. В принятых UI-запусках строго один
исполненный тест, без skipped. Ранние ошибки драйвера сохранены и исключены:
перенесённый xctestrun с неразрешённым `__TESTROOT__` дал0тестов; tap справа
попал в filler/зону перелистывания вместо пустого центра; строка setup-документа
с неверным escaping отказала до эффектов. Это не объявлено runtime-регрессиями.

### Системные измерения production105 на физическом iPad

`.build/s10-complete-20260918/physical105.trace`: настоящий Instruments,
app-targeted launch `com.amirtlinov.notebook.preview`, PID7241,
15:44:24–15:46:39 UTC, **135.816 секунды**, не Simulator/fixture/CADisplayLink.
Time Profiler + Activity Monitor + Core Animation FPS + GPU. Попытки attach
по PID/именам не нашли процесс; принят только завершённый launch trace с TOC
и фактическими samples. Остановка этого профиля завершила запущенный им процесс;
приложение затем открыто штатно. Это не crash и не непрерывный30-минутный trace.

| Системный показатель | Наблюдение |
|---|---|
| Notebook physical footprint,133 samples | median89.142 / p95 91.985 / max133.063 MiB |
| Notebook CPU,132 samples | median7.927 / p95 25.105 / max109.057%; CPU time14.088s |
| Core Animation display FPS estimate,134 samples | median8 / p95/max60; включая ожидание/покой |
| Device GPU hardware,134 samples | median17 / p95 37 / max63% |
| GPU intervals именно Notebook PID7241 | 42 интервала, сумма37.899ms; перекрывающиеся каналы не wall utilization |

FPS/GPU hardware относятся к дисплею/устройству, **не изолированному FPS Notebook**;
из них не следует обещание60FPS или отсутствие dropped frames. Time Profiler
содержит14024 samples процесса Notebook. Hitches/SwiftUI lanes отсутствуют;
ноль извлечённых hang rows не является доказательством отсутствия всех зависаний.
Есть сохранённое предупреждение `Data stream: Time Mapping`. CPU/память других
приложений не анализировались. Scope — запуск/поиск, не все70 сценариев и не
память TS-компилятора на Mac; его отдельные измерения сохранены в
`docs/programmable-notebook-measurements.md`.

На этой beta-паре Xcode/iPadOS повторялись60-секундные ожидания XCTest
`App animations complete notification not received`, при доступных AX/PNG
и завершённых жестах. Перезапуск того же105 временно убирал ожидания, но не
считается исправлением production. Эти паузы нельзя выдавать за обычную
пользовательскую latency или время CPU. Raw trace/XML, `system-metrics.json`
и `system-profile-analysis.{json,md}` сохранены рядом с квитанциями сценариев.

## 18 сентября 2026 — S8–S10: полный сценарный цикл и найденная граница старой отмены

На неизменной установленной105 завершены **семь задач ×10 =70 сценариев**:
подпись (JS/TS попеременно), внеэкранный материал и все80 совпадений поиска
страницами по7, один блок79 из81, атомарные два узла/связь, алгоритмическая
перестройка, конфликт после настоящего iPad drag и восстановление после
разрыва MCP-клиента. Каждый повтор менял данные, не был replay/no-op.
В каждом цикле шесть точных публикаций подтвердили saved/received/shown
для actionVersion и физического actor5124…; native AX/PNG/жесты проверялись
отдельно. В документе native button продолжил агентский state до11…101;
undo сохранила человеческое значение. Reconnect присоединился к тому же run,
повтор start вернул тот же результат с одним эффектом. Это разрыв MCP, не
имитация потери радио; commit fault-injection и offline semantics проверены
отдельными ранее принятыми контрактами.

Работа на паре шла с15:40 до16:20 UTC, включая настоящий источник сообщения
и последовательные native/MCP действия; это более30 минут совместного
сценария, не обещание непрерывной30-минутной записи Instruments. Из серии
не скрыты паузы XCTest/исправления драйвера. После третьего цикла test runner
отключил только своё ожидание animation-idle и перестал повторно activate
уже foreground app; event-loop waits и конкретные UI assertions сохранены,
анимации production не отключались. Ошибочный ранний drag попал в connector,
развязал его и потребовал явного исправления **собственной** fixture через SDK;
попытки repair с синтаксической ошибкой/без movement scope не записали эффект.
Это не изменения SDK ради теста и не измерение автономной успешности агента.

Экспорт большого документа: **21 страница,45395B**, SHA256
`22fb3656dae14e5f1fcc866dc97ffd582029a369e53d50170295ac45bd7b786b`.
PDFKit прочитал Section0 и Section79,53153B текста. Пока persisted export
до/после записи оставался `running`, независимая SDK-подпись сохранилась
за179.223ms; её точный shown подтверждён через2.040s polling. Это верхние
границы round-trip/наблюдения, не внутренний timestamp кадра. Исходный ink
PNG действительно содержит красный штрих, без OCR; его revision не изменился
от всех предыдущих правок/жестов схемы.

Финальная отмена этого старого ink-action выявила дефект105: штрих уже исчез
на физическом iPad, но новая версия квитанции не подтверждалась. Native refresh
брал последние64 **созданных** действия; старая запись с новым undo выпадала.
Регрессия с70 более новыми действиями сначала получила три отказа. Исправление
`6bf6159` индексирует время текущей фазы отдельно от времени создания; delivery
и display owner читают этот ограниченный индекс. Публичная creation-history
pagination не меняется. Schema12 перестраивает только derived descriptions,
не records/версии/идентичности/journal/read cursor. **11 Core tests /2 suites
PASS**, включая v11 admission,14MiB receipt и запоздалую старую квитанцию.

Физический native refresh regression также PASS. Первый общий source gate
честно отказал: параллельная незавершённая графика изменила checkout. Для
повторной проверки и выпуска106 взят immutable cut ровно `6bf6159`, без этих
чужих изменений: `.build/s10-phase106-source`,
SHA256 `fc9812ab5043d5bb0eeb181e3f740d291f475f601dc0150aca3f834ed075971d`.
`.build/s10-old-phase106-verify-final`: **1 physical native PASS**, без skips
и runtime warnings. Полная семёрка105 не переименовывается в70 прогонов106;
последняя дельта принимает адресную регрессию и живую старую отмену отдельно.

Evidence: `.build/s10-complete-20260918/cycle-01…10-receipt.json`, public
`calls/`, native xcresult/AX/PNG, `export-concurrency.json`, `export-result.json`,
`pdf-proof.log`, `old-undo-{red,green}.log`. Системный профиль, разрешённый
Амиром в16:08, был оборван прерыванием turn и не финализировался (`Document
Missing Template`); его начало **не засчитано как измерение**.

## 18 сентября 2026 — все десять срезов MCP TDD приняты, production106

Финальная пара **0.3.103 (106)** установлена поверх105 без удаления контейнеров,
смены workspace/actor/ключей/доверия. Source `6bf6159` и fingerprint указаны выше;
signed build `.build/s10-release106-pinned/build.json`, установка
`.build/s10-install106/`. iPad UUID `4FA30C0C-1C0A-37EC-8A3F-F4F3106F0068`,
CDHash `3ac43ae641ae8782940c6287b23b606cba3be361`; Mac UUID
`18C26EFF-34DF-3DA4-AE68-EDDCA0DF21B8`, CDHash
`3f2c1e85bf43b9b8ee375af4216e8f910e3d5823`. Ровно два installed tools:
`notebook_context`, `notebook_execute`. Это принятие MCP-вехи, не незавершённых
параллельных изменений графики или следующего Mac UI.

На106, **без повторного выполнения старой отмены**, action
`BBD42B8A-40F4-44D8-85AB-AAB4B17A4445`, версия
`bb5b8747c26b31934cdbe0e7cc5822add35b6c0772d08f7bcec5e18dfc859429`
получила saved/received/shown confirmed. Физически красного штриха нет,
схема `R10 → PDF` сохранена; настоящий ink PNG белый, pageMap ready,
revision2, regions/occupiedCells пусты. Ошибочная105-квитанция сохранена отдельно.

Физический lifecycle106: открытые тетрадь и документ исчезают после SDK delete,
undo возвращает тот же предмет и число записей; повторное открытие показывает
`R10 → PDF` и **SDK count101**, включая человеческое продолжение. После удаления
трёх собственных детей проверены пустая доска, её delete/undo и повторное
открытие. Последующий cleanup удалил только собственные четыре предмета.
Итог в16:46 UTC: **itemCount7→7**, четыре адреса `null`, runtime `connected`,
selection `known/empty` на корневой доске. PNG итоговой поверхности осмотрен;
пользовательская тетрадь/чернила остались. Собственный standalone UI runner
удалён с iPad. Тестовая задача с историческим сообщением сохранена: штатное
архивирование отказало `active writer`, обхода app/bridge не делали.

Две попытки cleanup-навигации не закрыли search sheet: XCTest нажимал пустой
центр короткой строки с plain button. Tap по видимому заголовку открыл доску;
production не менялся. Эти failed attempts не засчитаны как успешные сценарии.
Итоговый агрегатор строго проверил **70 сценариев,60 точных публикаций** и
**125 успешных native summaries** выбранной серии, исключив5 failed/invalid
summaries; отдельные S7/106 native proofs хранятся рядом. Это не заявление,
что весь исторический test suite или `verify.sh --full` запускался и зелёный.

### Завершённый системный профиль106

Разрешённый системный trace `physical106-joint.trace`, **16:37:49–16:42:50 UTC,
300.948s**, финализирован и экспортирован. Это ограниченная5-минутная запись
lifecycle/undo и последующего ожидания, а не30 минут активных жестов. Анализ
CPU/memory/GPU intervals ограничен Notebook **PID7976**; другие процессы не
анализировались. Display FPS/hardware GPU — показатели всего устройства.

| Показатель | median / p95 / max |
|---|---|
| Notebook physical footprint,293 samples | 279.361 / 288.470 / 457.127 MiB |
| Notebook CPU,292 samples | 25.681 / 72.051 / 127.697%; CPU delta93.539s |
| Device Core Animation FPS estimate,298 samples | 8 / 60 / 60, с покоем |
| Device GPU hardware,298 samples | 0 / 55 / 68% |

Notebook GPU:817 intervals, сумма854.219ms; перекрытия не дают wall utilization.
Xcode27 export сохранил предупреждения об overlapping dylib timelines;
числовые Activity Monitor/CA/GPU rows присутствуют. Не выводим из этих данных
изолированный FPS приложения, отсутствие hitches или обещание60FPS. Память
компилятора на Mac и сравнение v1/v2 — отдельные измерения, не этот iPad trace.

На installed105 обычные публичные программы подписи, поиска, адресного блока,
создания графа и reflow завершались одним внешним вызовом; медианы round-trip
соответственно201.123 /31.541 /43.760 /271.207 /180.396ms. Setup, UI и отдельная
проверка публикации не входят в эти числа. Reconnect включает явное3-секундное
ожидание: медиана3170.716ms,5 вызовов. Полные диапазоны/байты и идентичности
в `final-receipt.json`; сравнение до/после и read/decode counts —
`docs/programmable-notebook-measurements.md`. Общий процент ускорения и
автономная частота исправления запросов не заявляются.

S8/GUI-217, S9/GUI-218 и S10/GUI-219 закрыты по совокупности прежних контрактов,
полного installed SDK цикла и этой физической приёмки; S1–S7 уже приняты.
Все десять срезов одной вехи завершены. Unsupported groups/rotation/import/OCR
не объявлены реализованными. Evidence: `.build/s10-complete-20260918/`
`final-receipt.json`, `lifecycle-*-receipt.json`, `ink-acceptance-receipt.json`,
`final-read.json`, `public-tools106-final.json`, `joint-system-metrics.json`,
trace/XML, native AX/PNG и public requests/replies. Физический/Xcode слот
передан следующей задаче в16:47 UTC; здесь дальнейших запусков нет.

## 18 сентября 2026: GUI-233 — рабочее приложение Notebook на Mac

По прямому запросу Амира прежняя headless-only граница отменена. Notebook
остаётся одним процессом с одним NotebookAppModel/SQLite writer/транспортом,
но теперь имеет обычное рабочее окно и иконку в Dock. Закрытие окна не завершает
связь и IPC; повторный запуск открывает то же пространство. Окно использует
общую композицию, материалы, WebKit-документы и журнал чернил, а не снимок iPad.
Мышь/трекпад/клавиатура имеют собственный Mac-ввод.

Содержание общее, навигация независимая: локальная камера/страница/выбор не
подменяются присутствием iPad. Удалён wire `documentPageSelection`; protocol24
требует обновлённой пары. Удалён прежний read-only `PencilDrawingView`.
Наблюдение MCP/preview по-прежнему адресует подключённый iPad, отдельно от
локального Mac-окна; без peer наблюдается локальная поверхность.

### Проверенный и установленный срез

Пара **0.3.104 (107)**, sourceSHA256
`1370aff318574b86a0f816dccc5f66e3d68d617fe1eaa8ec1320cf0235b4c428`.
Квитанции в worktree `/Users/amir/.codex/worktrees/notebook-mac-workspace/Notebook/`:
`.build/gui233-selected107-final/verification.json`,
`.build/gui233-release107-final/build.json`, `.build/gui233-install107-final/`,
`.build/gui233-live107/final-receipt.json`. Подписи и установленный Mac manifest
сверены с собранным артефактом; контейнеры, ключи, идентичности и архивы не менялись.

- **9 Mac native +3 native на физическом iPad PASS**, без runtime warnings:
  независимая камера и IPC peer-контекст, закрытие окна, адресный preview,
  локальное перелистывание, native camera conversion и hit-testing.
- Release contracts **79 PASS**, verification contracts **77 PASS**.
  Отдельные Core selection-publication **4 PASS** на том же Core-срезе.
- Живой установленный Mac: обычное окно; поиск; двойной щелчок обложки;
  открытие существующей вложенной доски; Markdown-редактор и сохранение;
  создание тетради и следующего листа; закрытие/повторное открытие с работающим IPC.
- Общий документ: Mac UI изменил счётчик0→1, физический iPad показал1;
  iPad UI изменил1→2, Mac показал2. Сохранённое состояние содержит человеческие
  версии обоих акторов. Mac оставался на странице2, iPad — на странице1.
  Аналогично создание второго листа на Mac не переключило первый лист iPad.
- Два нажатия ручкой на Mac записались в журнал `2@fe3f4542…`;
  physical iPad показал эти чернила и AX `2 действий пера`. Непрерывный drag-штрих
  и ластик не объявляются проверенными: CUA drag завершался ошибкой захвата.
- Два собственных проверочных материала удалены через SDK lifecycle;
  `saved` и `receivedByIPad` подтверждены, физический скриншот показывает возврат
  к существующей доске. `shownOnIPad` квитанций удаления остаётся awaiting_display,
  не подменяется скриншотом. Исходные7 материалов сохранены; временный UI runner удалён.

Живая проверка первой сборки107 обнаружила отбрасывание NSHostingView в
`SceneCameraPlaneView.hitTest`: вместе с пустым фоном терялись SwiftUI gestures
обложек. Финальный срез оставляет responder только в геометрии опубликованного
workset; пустой фон проходит к владельцу камеры. Исправление подтверждено native
регрессией и реальным двойным щелчком, а не только наличием AX-элемента.
CUA также давал ScreenCaptureKit3811/3812 и timeout; это не засчитано за жесты.

Полный gate/100000 предметов/30 минут совместной нагрузки здесь не запускались.
Дополнительно проверенный `DocumentDocumentTests.storePublishesAndDeletesDocumentBundle`
падает и на чистом6bf6159 из-за ожидания физического удаления tombstone-записи;
это существующий сбой, не исправлявшийся в GUI-233 и не скрытый общим PASS.
Данный срез не обещает полного паритета всех жестов iPad на Mac.

## 18 сентября: GUI-233, повторно открытая приёмка Mac 107

Скриншоты Амира выявили непокрытый сценарий: на существующей заполненной доске
растровые обложки/SVG распадались и меняли размер при зуме; существующий лист
оставался «Открываем лист…». Предыдущая проверка новых материалов не подтверждала
этот сценарий и не закрывает эти дефекты.

Регрессия `.build/gui233-zoom-regression-before` воспроизвела обе причины:
`NSImageView` занимал 1024 точки вместо запрошенных 51.2/358.4/716.8 (размер
bitmap ошибочно становился intrinsic layout); Mac открывал холодную тетрадь
без вызова существующего адресного владельца подготовки страницы.
После исправления 9 Mac native-тестов PASS, без runtime warnings:
`.build/gui233-hotfix-final`. Последующие изменения только выровняли отступы;
установке требуется новая квитанция объединённых исходников выпуска 108.

Растр больше не задаёт intrinsic size. Завершение zoom отдельно запускает
уточнение плотности. Публикация пикселей не меняет опорную камеру во время жеста.
Открытые материалы имеют одну отдельную поверхность чтения вместо соседей,
обложек и чернил доски; общие PageSurface/DocumentWebView и writer сохранены.
Документ открывается по ширине, тетрадь — целым листом; прокрутка ограничена
бумагой, доступны «По ширине», «Вся страница», «100%». Возврат использует ту же
историю мест и точную прежнюю камеру. Холодный лист загружает prepareNotebookPage.

В изолированном DEBUG-окне через CUA наблюдались живой текст и 4 страницы
документа; захват изображения вернул миниатюру фонового окна, поэтому визуальная
приёмка по нему не заявляется. Установленная пара и zoom/открытие исходных
материалов требуют отдельной проверки после сборки 108. Полного/performance
PASS этот срез не объявляет.

## 2026-09-18 — GUI-234: исполняемые рецепты навыка Notebook

Добавлен версионируемый источник `MCP/skills/notebook`: основной навык — 51 строка,
подгружаемые примеры, восемь рецептов (mindmap/flow/compare/visual/plot/sketch/point/document)
и композиционные заготовки технического дизайна, исследования, абстракта и эссе.
Подготовка создаёт обычный запрос SDK v2; файловый клиент вызывает только публичный
`notebook_execute`. Исполнение, запись, отмена и доставка остаются у прежних владельцев.
Изображения встраиваются в Markdown-источник; большой растр при `fit:true` получает
отдельную уменьшенную копию с сохранением формата и PNG alpha, исходник не меняется.

Проверено: `tsx --test MCP/test/recipes.test.ts MCP/test/recipes-ipc.test.ts` — 10 PASS
с изолированным `notebook-ipc-test-host`; схема SDK, отсутствие пересечений узлов,
привязки, tile-переходы, неизменная supplied basis, сохранение SVG, документы/добавление
блоков, native ink, undo, упаковка файлов и большой PNG. `tsc --noEmit -p MCP` и
`skill-creator/quick_validate.py` — PASS. SVG-график и пример раскладки просмотрены в PNG.
Публичный файловый клиент прошёл установленный QuickJS без эффектов:
run `9aad8493-a24a-4f7f-a50d-34ae714ea83b`, completed, effects=[]; это не UI-приёмка.
Приложение/iPad, пользовательское содержимое и упаковка выпуска не менялись.
Mermaid-парсер не добавлен; готовый SVG проходит обычный visual-рецепт.

## 18 сентября, 21:16 МСК — GUI-205: множественный выбор установлен и проверен через рабочую пару

Подписанная **0.3.105 (108), wire25** установлена поверх107 на Mac и физический
iPad. Выпуск включает `4735b40` (множественное редактирование), интеграцию
Mac107 и его адресный hotfix `27a6290` как `6b9393a`. Точный source:
`8929500671534be287decb43174fd3974e1b2239f7e8e15b3e7ff625af60cc98`.
Последующий GUI-234 (`ebdfab8`, рецепты/навык) не входит в эту опись выпуска.

Неизменный совместный gate `.build/graphics-selection108-hotfix-final/`:
**23 iPad + 10 Mac PASS**, ноль skips и runtime warnings; MCP79/79 и typecheck
PASS. SwiftPM выбранных контрактов: 10 Core + 6 ScriptHost PASS, включая
перестановки конкурентных пакетов и независимое присутствие устройств.
Подписи и полные bundle manifests совпали с `.build/graphics-selection108-release/`.
Установщик `.build/graphics-selection108-install/` завершил Mac штатно и заменил
только bundle, iPad обновил in-place. Контейнеры, идентичности, ключи, доверие и
исторические архивы не менялись. Перед/после обновления workspaceID, содержание,
ревизии и семь материалов совпали; затем создан отдельный временный fixture.

Живой сценарий **установленного preview**, а не native-test, использовал
`Graphics108Check` и три обычных нативных объекта. На iPad собран выбор двух
узлов и стрелки; публичный `nb.observe` вернул ровно три ID и тот же target.
Агент изменил подпись/стиль, iPad показал их. Палец перенёс всю конструкцию на
`(35,25)` одной командой; адресное чтение Mac подтвердило три сохранённых frame
и прежние внутренние привязки. Агент продолжил изменение тех же frame, затем
последовательно отменил своё движение, человеческий перенос и свою прежнюю
правку оформления. Восстановлены точные исходные координаты и подписи;
`preservedCount=0` во всех трёх отменах. После холодного запуска iPad показал
исходную схему. Снимок просмотрен. Для точной undo actionVersion `76e59e48…`
`nb.action` подтвердил **saved, receivedByIPad, shownOnIPad**.

Данные, программы запросов, xcresult и снимки: `.build/graphics-selection108-live/`,
сводка `acceptance.json`. Неуспешные попытки оставлены явно: ранние taps до
завершения меню не собрали набор — driver теперь ждёт исчезновения меню и
изменения видимого счётчика после каждого выбора. После пересборки только
тестового runner iOS отверг его установку; его проверенная подпись восстановлена
чистой установкой runner, без изменения доверия и без удаления preview.
Первое агентское геометрическое действие правильно отклонено `composition_scope`:
чтение выбора не даёт права перемещения. Исправлен запрос с явно разрешённым
владельцем собственного fixture, не production-проверка; преждевременный
cold-check до успешной команды не считается приёмкой. Успешный cold-check
исполнен отдельно после подтверждённых отмен.

Удалён **только** собственный временный notebook штатным `itemLifecycle` →
`deleteItem`; публичное чтение снова показывает семь исходных материалов,
физически подтверждено исчезновение fixture. Собственный UIrunner удалён,
Xcode/iPad освобождён в21:16 МСК. Симуляторы и параллельные runners не применялись.

Этот срез завершает временный множественный выбор, общий перенос, выравнивание,
копирование со связями, удаление и z-order, но **не весь GUI-205**. Постоянные
вложенные группы, расширенный rich text, оставшееся распознавание и полный
зафиксированный tldraw-профиль ещё открыты. Десять повторов, 30 минут смешанной
работы и системные кадры/ресурсы не заявлены. Новое замечание Амира о запаздывающей
догрузке Mac tiles ведётся отдельно в переоткрытом GUI-233; установка и native
PASS не заменяют его визуальную приёмку. GUI-199 автоматически не закрывается.

## 2026-09-18 — GUI-235: управляемые научно-образовательные анимации

Рецепт `animation` в установленном навыке сохраняет самодостаточные HTML/SVG,
CSS, JavaScript и начальное состояние через существующие `web`/`interactive`
поверхности. Добавлены локальный файловый предпросмотр и небольшой пример
бегущей волны: пуск/пауза, шаг фазы, перемотка, амплитуда и темп. Кадры остаются
локальными, выбранные состояния проходят обычный `notebook.commit`.

13 проверок `recipes.test.ts` + `recipes-ipc.test.ts` PASS: упаковка, SDK-схемы,
сохранение программы/состояния на доске и в документе через изолированный native
IPC, аналитические фазы, отсутствие записей на каждом кадре и остановка при
внешнем состоянии. TypeScript и валидатор навыка PASS. В браузерном предпросмотре
проверены начальная/четвертная фазы, пуск/пауза и изменение амплитуды до нуля;
сцена и управление читаются. Артефакты: `.build/animation-recipe-check/`.
Пользовательский LC-пример изучен отдельно, его файлы не изменены. Приложения,
пользовательское содержание и установленная пара не менялись; это проверка
рецепта, не новая физическая приёмка iPad.
## 18 сентября: GUI-233, очередь тайлов Mac после установки 108

После установки 108 Амир сообщил, что элементы временами отсутствуют и долго
появляются. Это оставляет пользовательскую приёмку открытой; исправление
intrinsic-размеров не является доказательством устранения всех задержек.

Найден оставшийся путь прежнего безоконного Mac: ресурсный профиль был
`headless`, выбор живых программ и исключение их фоновых исполнителей работали
только на iPad, Mac-когорта не публиковала `runtimeOwners`. Видимые программы
поэтому становились статическими снимками и занимали очередь фонового WebKit.
Удалены платформенные развилки этого поведения. Обе рабочие поверхности имеют
одного смонтированного исполнителя программы; фоновые источники и явный
headless-экспорт остаются у прежнего ограниченного владельца ресурсов.

Общий предел 256 MiB и лимиты WebKit не увеличены. Резерв половины пула для
нативного Pencil backing остаётся iPad-специфичным: Mac использует растровый
путь чернил и сохраняет прежнюю полную растровую квоту. Пробная смена профиля
без этой границы дала пять отказов тесных экспортных сценариев; они сохранены
в `.build/gui233-tile-regression-after` и не скрыты повышением бюджета.

До правки `.build/gui233-tile-regression-before-v3` подтверждает неверный
headless-профиль, отсутствие владельцев и запуск фоновых исполнителей для
видимых программ. Гипотеза об обрезании за пределами опорного viewport отдельно
проверена и не воспроизвелась: этот путь не изменён.
После исправления `.build/gui233-tile-regression-after-v3`: 20 Mac native PASS,
без runtime warnings. Настоящий `NotebookMacCanvas` в изолированном NSWindow
монтирует четыре WKWebView до первого щелчка; шесть смен zoom сохраняют их
идентичность, несохранённый ввод, физические bounds и готовый SVG. Проверены
также старый/новый растры, камера и ограниченная композиция/экспорт.
Это не физическая приёмка пользовательской доски. Выпуск 109 требует отдельной
квитанции финальных исходников, установки пары и живого повторения зума.

Финальный срез 109: `.build/gui233-tiles109-final`, 20 Mac + 3 физических iPad
native PASS, runtime warnings отсутствуют, SHA-256
`e3b815b0e8187d387bd65708046b5637b5a6ddc9f3a606a27ff1bc8e3c4215e7`.
Подписанная пара 0.3.106 (109) установлена 18:33 UTC;
`.build/gui233-release109/build.json` и `.build/gui233-install109` подтверждают
полные описи и обновление без изменения контейнеров/ключей. Живой IPC connected.
AX теперь показывает настоящие кнопки/поля программ A, C, D вместо картинок.
Блок B отсутствует в адресном чтении: сохранён human tombstone 29@fe3f4542,
а не ожидающий тайл; данные не восстанавливались.
Новый скриншот Амира после установки показывает обрезанную справа обложку
документа. GUI-233 остаётся открытой: это отдельная неустранённая граница
растровой композиции/показа. CUA пока выдаёт лишь 98×98 миниатюру либо ошибку
ScreenCaptureKit3812; она не подменяет полноценную проверку пикселей.


## 18 сентября: GUI-233, приоритет цельной бумаги при зуме, 110

Амир уточнил: отсутствующий участок обложки самостоятельно появляется через
несколько секунд после остановки зума. Изолированные проверки NSImageView,
опорного viewport и нативного camera layer не воспроизвели постоянное обрезание;
эти реализации не менялись. Смешанный сценарий с тремя программами, подписями,
SVG, документом с чернилами и тетрадью показал другое: строковый порядок ID
оставлял пассивные элементы живыми, а видимую бумагу переводил в растровые
диапазоны. Новое окно камеры требовало заново приготовить её покрытие.

В единственном владельце выбора физических носителей порядок теперь такой:
контакт/закрепление, видимые программы, видимая бумага текущей доски,
необязательные пассивные носители. Исправлена также классификация nativeText:
web-форма источника снимка не делает нативную подпись исполняемой программой.
Общие квоты, бюджет байтов, admission и путь переполнения не увеличены и не
заменены дополнительным кешем. Код камеры, NSImageView и растеризации не менялся.

Неизменный финальный срез `.build/gui233-nativepaper110-final-v2`:
**8 Mac + 5 физических iPad native PASS**, ноль skips и runtime warnings.
SHA-256: `60022f2bca44e314d802d537a7795c73c0b0eee7b9321285d1c5407d683541db`.
Mac-регрессия использует настоящий NotebookMacCanvas в изолированном NSWindow:
шесть последовательностей zoom/pan, 90 промежуточных положений, проверка
цельных пикселей материала и живого владельца каждой видимой бумаги. На четырёх
остановках, где документ виден, он остаётся live; две остальные уводят его
за viewport. Описи и просмотренные PNG: `.build/gui233-paper110-attachments`.
Рендер слоя в этих PNG не захватывает Metal-чернила и удалённые WebKit-слои;
это не доказательство их физического показа. Их владельцы и сохранность ввода
проверены отдельно существующими контрактами.

Предыдущий проход `.build/gui233-nativepaper110-final` не скрыт: проверка
видимой бумаги выявила ошибочную классификацию nativeText, исправленную выше.
Также один раз истёк native_ink_frame в неизменном сценарии из двух обложек;
финальный повтор прошёл без изменения его таймаута или бюджета. Промежуточные
гипотезы и снимки находятся в `.build/gui233-paperclip-before*`; раннее
неверное чтение перевёрнутых пикселей было ошибкой fixture, не продукта.

Это адресная проверка, не полная приёмка кадров/CPU/GPU и не повторение
физического жеста Амира. GUI-233 остаётся In Progress до пользовательского
подтверждения отсутствия задержанных участков на установленной версии.

Подписанная пара **0.3.107 (110)** установлена 19:15 UTC поверх109 на Mac и
физический iPad; `.build/gui233-release110/build.json` и
`.build/gui233-install110/` содержат точные описи, preflight и install receipts.
Контейнеры, содержание, доверие и ключи не менялись. До окончания установки
Амир сообщил, что на109 стало лучше, но догрузка тайлов ещё видна, камера иногда
дёргается и перенос предметов/элементов сильно дрожит. Это не приёмка110;
дрожание перетаскивания выделено в следующий адресный срез GUI-233.


## 18 сентября: GUI-233, координаты удерживаемого переноса Mac, 111

После110 Амир уточнил, что материал дрожит именно во время удержания и движения,
а не только после отпускания. В трёх Mac-путях DragGesture читал translation в
локальной системе самого перемещаемого элемента, обложки или resize-ручки.
Теперь жест читает неподвижную именованную плоскость своего носителя. На доске
её дельта делится на опорный масштаб камеры; внутри страницы/обложки она уже
выражена в физических единицах; ручки читают неподвижную экранную плоскость.
Старый локальный путь заменён, сглаживание, задержки и дополнительный владелец
позы не добавлены. iPad-ввод по-прежнему нативный, без нового SwiftUI drag.

Попытка воспроизвести указатель через синтетические NSEvent в изолированном
NSWindow не запустила SwiftUI drag-contact вообще. Каталоги
`.build/gui233-drag-before` и `-v2` не доказывают продуктовый дефект; этот
неработающий эксперимент удалён, а не превращён в зелёную проверку обходом
настоящего жеста. CUA получает изображение окна после Raise, но drag завершается
`noWindowsAvailable`. Для конечной визуальной границы нужен жест Амира.

Финальные неизменные исходники111 проверены адресным набором
`.build/gui233-drag111-final`: **13 Mac + 3 физических iPad native PASS**,
без skips и runtime warnings. Source SHA-256:
`ea6668f5c38d7eb033ec462abcdf74e6e88e5dca59f7341964135c28a8badd9e`.
Область: Mac-камера и hit testing, интерактивные владельцы сцены, сохранность
бумаги при зуме; на iPad — существующий live resize, отмена старого контакта
Pencil и приоритет бумаги. Эти проверки не выполняют физический Mac drag и
не объявляются его приёмкой. Полная нагрузка и системная плавность не заявлены.

Пара **0.3.108 (111)** подписана и установлена 19:25 UTC поверх110 на Mac и
физический iPad. Описи совпали с `.build/gui233-release111/build.json`,
preflight/штатное завершение Mac/обновление iPad — в `.build/gui233-install111/`.
Содержимое, контейнеры, ключи и доверие не менялись; installed IPC connected.
Амиру передана именно установленная111 для проверки перетаскивания обложки и
элемента. До его ответа дрожание, остаточная догрузка тайлов и рывки камеры
остаются неподтверждённой пользовательской границей GUI-233, а не PASS.

## 18 сентября: GUI-233, удаление автоматической навигации зумом, 112

Амир уточнил, что сам жест уменьшения выводит на доску. После удаления такого
поведения у бумаги в GUI-229 оставалось исключение для вложенных досок:
`SpatialWorkspaceView` выбирал портал под пальцами и менял `boardID` в обе
стороны прямо внутри pinch. Теперь у жеста один путь — камера исходной
поверхности. Удалены выбор кандидата, направление открытия, перебазирование
жеста при переходе, `NotebookSelectionField` и автоматические
`enteringCamera/exitingCamera/openingProgress`. У модели остались только явные
`enterBoard/leaveBoard`, у UI — двойное нажатие и «Назад». Пассивное изображение
портала, сохранение его камеры и готовые пиксели при явном возврате сохранены.

Регрессия `.build/gui233-zoomexit112-before` на физическом iPad действительно
падала до правки: зум менял владельца доски. Финальный неизменный срез
`.build/gui233-zoomexit112-final-v4`: **39 native + 4 UI на физическом iPad,
3 Mac native PASS**, ноль skips/runtime warnings. Дополнительно **38 Core PASS**
(`.build/gui233-zoomexit112/core-final-v4.log`). Source SHA-256:
`0ff91b42a2618bd6494de15a9835f20d1295f2ee493928ca6938fe5c9d3fc338`.
UI исполнил pinch ×3 и ×1/3 над порталом, явный вход, уменьшение ×0.55 и ×0.35
внутри дочерней доски и явный возврат. Измеренные XCTest rect менялись с
292 до полного окна у портала и с500 до278 у дочерней обложки: проверка не
подменяла исправление отключением самого зума. Отдельные сценарии проверили
тетрадь, перелистывание, документ и сохранение открытой бумаги после pinch.
Mac проверил чтение и прежние явные entry/exit/reentry pixel/camera контракты.

Промежуточные отказы не скрыты. Первый UI setup застрял в системном Create menu
(AX ожидал idle по60 секунд), до жеста не дошёл. Сценарий теперь начинает с
существующей двухуровневой доски в отдельном Debug-хранилище. Её первоначальный
неатомарный seed оставлял parent дочернего reference owner пустым; чтение
скопированной тестовой SQLite подтвердило причину `capture_source_pending`.
Seed исправлен единым `saveWorkspaceBundle`; временная диагностика удалена.
Попытка адаптировать прежний off-center auto-handoff grid test под явную границу
дала MAE0.00054 из-за включённого края портала. Этот тест удалён вместе с
автоматическим API, а не ослаблен; существующие explicit-render и camera-roundtrip
тесты оставлены без изменения критериев. Исходники рендерера и ресурсные квоты
в112 не менялись. Неудачные проходы и диагностика находятся в
`.build/gui233-zoomexit112-final*` и `.build/gui233-zoomexit112-portal-*`.

Подписанная **0.3.109 (112)** установлена 20:08 UTC поверх111 на Mac и физический
iPad. Проверены версии, полные bundle manifests и установленный IPC:
connected, cursor15341, прежнее пространство FAAAC405-8EF9-4FB9-9B93-CBD876FA97A4.
Сборка/установка: `.build/gui233-release112/build.json`, `.build/gui233-install112/`;
readback: `.build/gui233-live108/installed112-runtime.json`. Контейнеры, содержимое,
ключи и доверие сохранены. Это адресная физическая проверка навигации, не полная
performance-приёмка и не подтверждение исчезновения прежнего Mac drag jitter
или догрузки тайлов. Эти границы GUI-233 остаются открытыми.


## 18 сентября 2026 — iPad: видимая граница открытого листа (GUI-233)

Амир отверг результат 112: двухпальцевое уменьшение на iPad по-прежнему
визуально возвращало доску. Прежние проверки подтверждали сохранение `.page` /
`.document`, но допускали уменьшение самого листа до масштаба 0.0125.
Исправлен владелец камеры модели: полностью открытая бумага не уменьшается
ниже целого листа, перемещение ограничено его краями. Это применяется также
при восстановлении состояния; камера доски и явный «Назад» не ограничены.
Общая геометрическая формула чтения используется и прежним Mac clamp,
дублирующая математика удалена. Старый тест deep-board-overview заменён.

Промежуточно: 18 Core checks PASS (`.build/gui233-paper113/core.log`).
Нативная/физическая проверка и установка этого среза пока не завершены:
он включается в согласованный общий релиз 113 вместе с GUI-238.
Физические pinch-тесты теперь проверяют размеры и центр листа после двух
последовательных уменьшений 0.28, а не только режим, затем настоящее увеличение.


## 18 сентября 2026 — GUI-233: тень перемещаемой обложки на Mac, 114

Амир уточнил, что дефекта на iPad нет. Исправлен только Mac: внешний
`background` тени находился за пределами `MacWorkspaceMaterial.offset`, поэтому
обложка двигалась, а тень оставалась у сохранённой позиции. Тень перенесена
внутрь материала после clipping бумаги и до общего transient offset. Отдельного
пути перемещения тени больше нет; один владелец обслуживает тетрадь, документ
и доску. iPad production-код и поведение жестов не менялись. База — совместная
113 (`f62c35f`), включая ограничение открытого листа на iPad и GUI-238.

Неизменный срез `.build/gui233-shadow114-final`: **5 Mac native PASS**,
0 skips/runtime warnings. Проверены холодное открытие, камера чтения,
независимость присутствия, hit-test материала и жизненный цикл окна. Source
SHA-256: `1a8157384627fa76056d4ccce8afef55648677072cfaf009cb2aeaff333fb2b9`.
Это узкая регрессия окружения правки, не проверка движения тени мышью.

Предварительная диагностика `.build/gui233-shadow114-diagnostic-v3` на физическом
iPad показала движение тела и тени всех трёх видов вместе. Mac-часть этого
прохода **не прошла**: синтетический `NSEvent` не инициировал SwiftUI DragGesture.
Такую инъекцию нельзя считать воспроизведением дефекта или его исправления;
временные диагностические тесты удалены. Интерактивный CUA drag также вернул
`noWindowsAvailable`. Ручное подтверждение тени во время Mac drag остаётся
открытым; этот срез не закрывает прежние вопросы плавности и догрузки тайлов.

Подписанная пара **0.3.111 (114)** установлена поверх113 в20:54 UTC. Выпуск:
`.build/gui233-release114/build.json`; установка с read-only preflight, штатным
завершением Mac и сохранением контейнеров/ключей — `.build/gui233-install114/`.
Повторно сверены полная опись установленного Mac и версия114 физического iPad.
Установленный MCP connected, cursor15537, прежнее пространство
`FAAAC405-8EF9-4FB9-9B93-CBD876FA97A4`
(`.build/gui233-live108/installed114-runtime.json`). После переустановки CUA
не смог даже захватить окно: ScreenCaptureKit error−3811. Поэтому установку
и5 native PASS не выдаём за визуальное подтверждение drag.

## 19 сентября 2026 — GUI-258: настройки повторным нажатием на инструмент

Убраны отдельная кнопка настроек и её разделитель из `PenControlsView`.
Другой инструмент выбирается одним нажатием без раскрытия; повторное нажатие
на активную ручку или ластик открывает popover у его кнопки. Открытый popover
имеет одного локального владельца; закрытие не меняет выбранный инструмент
или его параметры. Добавлена подсказка доступности для повторного нажатия.
Новых инструментов (маркера, лассо, фигур) этот срез не добавляет.

Неизменный срез `.build/gui258-tool-settings117-check`: **2 UI PASS на физическом
iPad**, 0 failures/skips/runtime warnings, без Simulator. Source SHA-256:
`2966732c67fdb4b5185da1a91d65c01da84c512029a55b9bf414423370764fc9`.
Проверены выбор и повторное нажатие обеих кнопок всей площадью 44×44,
изменение/сохранение ширины ластика и цвета ручки, preview и opacity,
закрытие крестиком и вне popover, отсутствие отдельной кнопки настроек.
Второй сценарий подтвердил доступность панели при закрытом/открытом чате
в портретной и горизонтальной ориентациях. Снимки popover просмотрены;
экспорт вне неизменяемой квитанции: `.build/gui258-images117`.
Это адресная физическая проверка управления, не полная performance-приёмка.

Подписанная пара **0.3.114 (117)** установлена поверх116 на Mac и физический
iPad. Сборка: `.build/gui258-build117/build.json`; установка и readback:
`.build/gui258-install117/installation.json`. Перед заменой проверены текущие
bundle/подписи и iPad registry, Mac завершён штатно с drain. Байтовая опись
Mac-данных до запуска и hash iPad workspace registry не изменились; uninstall,
сброса контейнеров/ключей и восстановления архивов не было. Установленный MCP
вернул `ready` с прежними workspace/content/ink basis; источник presence после
запуска — физический iPad. Обе установленные версии117 сверены. UI-жесты выше
исполнены в изолированном физическом `.native-test`; отдельного ручного
подтверждения release117 от Амира пока нет.

## 19 сентября 2026 — GUI-259: полный набор инструментов iPad, 118

Добавлены маркер, лассо рукописи/объектов с перемещением, копированием,
масштабом и поворотом, пять фигур, нативный текст, привязанные связи, линейка
с углом/шагом и временная указка. Повторное нажатие активного инструмента
открывает его параметры через один popover; отдельной кнопки настроек нет.
На поверхности аннотаций к коду доступны только ручка, маркер и ластик.
Новые инструменты ввода относятся к iPad; Mac читает, рисует и редактирует
общее содержание, но его собственная панель ввода здесь не расширялась.

Каталог/локальные настройки не владеют документом. Общий controller фиксирует
адрес, геометрию и параметры контакта; iPad-адаптер отвечает только за ввод
и временный след. Сохранение идёт через существующие ink journal и причинную
очередь команд с undo/доставкой. Лассо не переписывает измеренный журнал:
оно сохраняет упорядоченные векторные pen/eraser mesh-слои и их исходный
адрес, а преобразования/стирание учитывают базис объекта. Сохранённая рукопись
и обычные чернила используют один Metal-рендерер. Старый отдельный редактор
текста доски удалён; страница, доска и обложка используют общий native text.
Указка и контур лассо не становятся содержанием. Wire29/manifest12 ограждают
новые поля от старого reader; уже принятые очереди manifest4–9 сохранены.

Неизменный срез `.build/gui259-tools-final`: **12/12 на физическом iPad**
(10 native + 2 UI) и **7/7 Mac native**, без skips/runtime warnings/Simulator.
Source SHA-256: `abdc86f8421ad4c60b322743a7f077824219ade2872b501806118c7730ae72f0`.
Проверены повторное открытие настроек всех девяти инструментов, сохранение
параметров, геометрия фигур/линейки, отмена и повторный контакт, временный
след над обложками, page/board/cover authoring и undo, лассо с давлением,
стиранием/копированием/поворотом и адресный жизненный цикл текста. Native
Pencil-сценарии используют тестовый `UITouch` на физическом устройстве —
это не ручные жесты аппаратным Apple Pencil.

Core: **15/15** в трёх наборах (`NotebookDrawingToolsContentTests`,
`NotebookGraphicSelectionTests`, `InkElementErasureTests`), включая шесть
версий старой очереди. MCP: **18/18** (graphic-schema, sdk-types, sdk-snapshot,
text-style-read), изолированный IPC test host; исходники TypeScript и проверка
сгенерированных SDK-ресурсов PASS. Полный `npm run check` остаётся красным
из-за прежних strict-ошибок в `test/science-examples.test.ts`; они не скрыты
и не менялись. Сохранённые логи и область проверок:
`.build/gui259-support118/{core.log,mcp.log,mcp-full-typecheck.log,scope.json}`.

Визуальная проверка экспорта обнаружила швы, которые прежний усреднённый
pixel-check пропускал. Отдельная CPU-отрисовка удалена, сохранённые mesh-слои
переданы существующему Metal-рендереру; compositor явно передаёт плотность
растра. Финальный Mac-тест сравнивает также максимум ошибки внутри штриха
с давлением, вырезом и последующим перекрывающим штрихом. Экспорт просмотрен:
`.build/gui259-paint-images5/`; mean RGB error 0.000004878, max interior
channel error 1/255 по 2374 точкам (`.build/gui259-paint-comparison.json`).
Также просмотрен экспорт native text. Финальный прогон включает этот тест.

Полная системная performance-приёмка, ручное рисование каждым инструментом
аппаратным Pencil, десять повторов и 30 минут совместной работы не выполнены.
Локальные и физические автоматизированные PASS не заменяют эти условия.

Подписанная пара **0.3.115 (118)** собрана из того же source SHA и установлена
поверх117 в10:29 UTC. Квитанции: `.build/gui259-build118/build.json` и
`.build/gui259-install118/installation.json`. Mac завершён штатно с drain,
app заменён атомарно; iPad обновлён in-place. Байтовая опись Mac-хранилищ до
повторного запуска и hash iPad workspace registry не изменились. Uninstall,
сброса контейнеров/ключей, восстановления архивов и дополнительных копий
содержания не было. Полный manifest установленного Mac совпал со сборкой;
обе установленные версии118 сверены, оба приложения запущены.

Readback допущенного установленного MCP — `ready`, cursor16093, прежние
workspace `FAAAC405-8EF9-4FB9-9B93-CBD876FA97A4`, content/ink basis, through1312
и объекты; presence уже от физического iPad. Доказательство:
`.build/gui259-install118/live-readback.json`. UI-тесты выше относятся к
изолированному физическому `.native-test`, не к ручной приёмке release118.

## 19 сентября 2026 — GUI-259: прямой ввод текста вместо модального окна, 119

Амир отозвал приёмку текстового инструмента118: текст не появляется на холсте,
modal composer неудобен. Этот путь удалён вместе с кнопкой «Добавить».
Палец или Pencil задаёт точку настоящего nativeText; ввод идёт в нативном
редакторе там же. Размер настройки точно переводится из экранных пунктов
через масштаб камеры. При наблюдавшемся zoom0.037874 прежние24 мировых пункта
давали менее одного экранного пункта. Начало текста больше не переносится
вверх/влево ради фиксированной рамки. Высота берётся из TextKit, а не из
количества символов; нет распознавания Markdown/HTML или подмены типа.

Создание и последующие правки идут через одну причинную очередь элементов
с undo. Отдельный spatial-text writer и его вариант coalescing-owner удалены.
Редактор удерживает собственную принятую цепочку до завершения ввода, в том
числе после ухода с поверхности; поле высоты не заменяет позицию/ширину.
Core-тесты удалённого writer переведены на действующую причинную команду.
Wire30/manifest13 ограждают расширенный диапазон шрифта; уже принятые пакеты12
и4–9 продолжают читаться.

Промежуточные физические проверки нашли ошибки удержания исходника после
ухода с поверхности — исправлены в общем владельце команды. Сам ввод,
сохранение и повторное редактирование на доске/странице прошли вcheck3;
первый UI-сценарий ошибочно нажимал край листа и перелистывал его, после
просмотра иерархии он заменён касанием свободного центра листа. Это не было
потерей текста. Экспорт inline-редактора доски и страницы просмотрен:
`.build/gui259-inline119-images3/`.

Дополнительный физический сценарий deep zoom нашёл настоящую гонку: SQL-read
покрытия до принятия вставки объявлял новый editing pin отсутствующим и снимал
редактор. Удаление pin теперь сверяет курсор той же причинной команды — нет
второго владельца или повторного создания. Локальный text contact использует
общий picking без ненужного захвата изображения для shared attention.
После исправления deep3 прошёл полный ввод/сохранение/повторное редактирование
с экранной рамкой320×64 в точке касания. Скриншот просмотрен:
`.build/gui259-inline119-deep3-images/85752C24-C655-402B-9328-F0E1B8957955.png`.
Окончательная квитанция приводится ниже.

В финальном UI-прогоне XCTest на странице многократно сообщил
`App animations complete notification not received` и ожидал quiescence
по60с; события и проверки содержимого при этом продолжались. Это наблюдение
маршрута автоматизации, не замер задержки ввода и не доказательство плавности.

Финальный неизменный срез `.build/gui259-inline119-final2`: **14/14 physical
 iPad** (11 native + 3 UI), **7/7 Mac**, без skips и xcresult runtime warnings.
Source SHA:
`5afd896a1e9957f3995cd7bb228fd917a09eaf5b7628bc168cc8c35b8a62c4b9`.
UI проверяет обычную доску, страницу и глубоко отдалённую доску: касание,
размер320×64 и точное положение редактора, две строки, выход, чтение сохранённого
исходника и повторную правку. Скриншоты — `.build/gui259-inline119-final2-images/`;
финальный page screenshot просмотрен. Нативный срез проверяет также адрес
обложки, позднее завершение после навигации, удаление пустого и undo.
Дополнительно **Core45/45**, **MCP19/19** с заново собранным изолированным
IPC-host, source TypeScript и generated SDK PASS; журналы и область находятся
в `.build/gui259-support119/`. Полный TypeScript test tree не объявляется зелёным:
ранее отмеченные strict-ошибки `science-examples.test.ts` в эту правку не входят.
Simulator в этом маршруте не использовался. Native Pencil samples не являются
аппаратным вводом Pencil; системные FPS/CPU/GPU и длительная совместная приёмка
не выполнялись. Повторная пользовательская приёмка119 остаётся открытой.

Подписанная пара **0.3.116(119)** установлена поверх118 на рабочий Mac и
физический iPad в11:29UTC. Квитанции: `.build/gui259-build119/build.json`,
`.build/gui259-install119/installation.json`. Штатное завершение Mac с drain,
атомарная замена bundle и in-place CoreDevice update; без uninstall/reset и
без обращения к историческим архивам. Байтовая опись хранилищ/registry/activation
Mac до повторного запуска и hash workspace registry iPad не изменились.
Версии обоих установленных приложений сверены, оба запущены.
Установленный MCP ready, cursor18159: workspace, content/ink basis и17 объектов
совпали со свежим чтением18153 до установки. Presence/selection пришли от
физического iPad5124BDCA-7613-4E48-B09B-928D81A03D4E; камера сохранена.
Live readback — `.build/gui259-install119/live-{before,after}.json`.
UI-сценарии выше относятся к отдельному `.native-test` того же source SHA;
рабочее содержание не заполнялось тестовыми строками.


## 19 сентября 2026 — GUI-259: исправление восьми инструментальных сценариев, 120

После отзыва приёмки добавлен прямой путь исправлений без второго canvas/writer:
лассо пересекает границы и выбирает также карточки/текст, не ожидая mesh
рукописи; лазер хранит мировые точки с индивидуальным временем и стирается
с хвоста (по умолчанию0.6с); метрическая линейка двигается пальцем и вращается
за конец, 1см равен двум клеткам. «Связь» переименована в «Стрелка»; линия и
стрелка удалены из каталога фигур. Иконка стрелки использует ту же геометрию
маршрута/наконечников, что содержание. Толщина пера/маркера/фигур/стрелок
расширена до128 с логарифмическим выбором и числовым значением; стиль готового
элемента — до1024. Диаметр ластика фиксируется на касании, давление не меняет
его по ходу контакта; поздняя подмена диаметра удалена.

Цвета заливки и обводки независимы. Нормальный режим и union/subtract/intersect/
exclude действуют при рисовании поверх фигур. Результат — валидируемый
замкнутый Bézier-контур с отверстиями, одна обычная причинная команда и undo,
без растра или рекурсивного CSG. Новая форма/смешанное выделение ограждены
wire31/manifest14; уже принятые форматы13,12,4–9 продолжают читаться.

Промежуточные физические попытки сохранены в `.build/gui259-tools120-native`,
`-final`, `-final2`, `-final3` и `.build/gui259-lasso120-focus`. Они не объявляются PASS.
Обнаруженная реальная потеря первых8пунктов движения линейки исправлена
захватом точки touchdown, а не точки начала распознанного pan. Остальные
сбои нового сценария: инструмент выбирался после mount без публикации;
текст вводился вне видимого workset без retained source редактора; тест
поворота предполагал нулевой угол, хотя настройки сохраняются между launches.
Fixtures исправлены на реальные предпосылки: выбор до mount, точный исходник
редактора, установка0° через UI. Перед обводкой fixture ожидает публикации
именно нового видимого текста, не прежнего installed cohort; отдельная
проверка `.build/gui259-lasso120-visible` PASS. Результат лассо проверяется синхронно после
lift, в том числе при начале обводки внутри закрытой карточки.

Core25/25 (5 suites), MCP20/20 с заново собранным изолированным IPC-host,
source TypeScript и generated SDK PASS: `.build/gui259-support120/`.
Полный TypeScript test tree не объявляется зелёным из-за прежних strict-ошибок
`science-examples.test.ts`. Пиксели линейки и настроек просмотрены в
`.build/gui259-tools120-visual/`; по проверке добавлены явные подписи «Начало»
и «Конец» в настройках стрелки. Полной ручной приёмки аппаратным Pencil,
системных FPS/CPU/GPU и длительной совместной сессии не было; они не следуют
из native samples/XCTest. Simulator в этом маршруте не использовался.

Окончательный неизменный срез `.build/gui259-tools120-final4`: **16/16 physical
 iPad** (14 native + 2 UI) и **7/7 Mac**, без skips и xcresult runtime warnings.
Source SHA:
`cc4f7aa1bee80cc0299c4b2d768f914aa9ce0a19fe32a7cde45902ed32dc3d54`.
Тот же SHA указан в supporting receipt `.build/gui259-support120/scope.json`.
UI-снимки `.build/gui259-tools120-final4-images/` экспортированы; итоговый
popover фигур просмотрен. Поворот линейки и подписи концов стрелки просмотрены
также в `-final3-images` на неизменном UI-коде. Эти сценарии исполнялись на
физическом iPad в отдельном `.native-test`, не на рабочем содержании.

Подписанная пара **0.3.117(120)** установлена поверх119 на рабочий Mac и
физический iPad в12:28UTC: `.build/gui259-build120/build.json`,
`.build/gui259-install120/installation.json`. Mac завершён штатно с drain,
app заменён атомарно; iPad обновлён in-place. Байтовая опись хранилищ,
registry и activation Mac до relaunch, hash workspace registry iPad не
изменились; uninstall/reset/восстановления архивов не было. Версии обоих
установленных приложений120 сверены, manifest установленного Mac совпал
со сборкой. Профиль iPad действителен до17.09.2027.

Readback установленного допущенного MCP ready: cursor18159→18165, workspace,
content/ink basis и все17 объектов побайтно как JSON-значения совпали.
Presence сохранил камеру zoom0.29638625545605013; known selection пришёл от
физического iPad5124BDCA-7613-4E48-B09B-928D81A03D4E. Доказательства:
`.build/gui259-install120/live-{before,after}.json`, `presence-after.json`,
`selection-after.json`. Это подтверждает обновление/сохранность/связь пары,
но не заменяет ручную оценку задержек лассо, исчезновения указки и ощущения
ластика настоящим Pencil. GUI-259 передана на повторную приёмку.

## 19 сентября 2026 — GUI-259: компактные параметры, круглый ластик и стабильные наложения, 121

Амир уточнил, что «две формы» ластика означают угловатый след, не второй
курсор. Для eraser удалено использование miter-соединений пера: одна круглая
swept-disk геометрия Core обслуживает живой ограниченный хвост, сохранённый
растр, маски и удержанные слои лассо. Ползунок диаметра логарифмический от2пт,
с числом и пресетами8/16/32/64. Общий wire32 ограждает разные геометрии пары;
manifest14 и прежние принятые очереди не меняются.

Основной цвет вынесен кругом на toolbar и проецирует настройки выбранного
инструмента, не копию цвета. В параметрах осталась независимая заливка фигуры.
«Круг / квадрат» заменено на «Фиксированные пропорции». Один anchored presenter
показывает палитру или параметры без заголовка/кнопки закрытия, с радиусом10пт,
без системного glass-popover и поиска приватных subviews. Закрытие снаружи
сохраняет выбранный инструмент. Неэффективные presentationCornerRadius и
промежуточный UIPopoverBackgroundView удалены, не оставлены запасным путём.

Лазер передаёт tick TimelineView прямо в Canvas; после lift и отмены контакта
хвост продолжает убывать без нового ввода. Boolean-контакт читает принятый
логический граф, включая ещё сохраняемую фигуру и drafts, а не старый raster
cohort. Content admission отделён от header-only refresh; удержанный до кадра
host вставки проецирует новую принятую геометрию, не воскрешает исходный
прямоугольник. Полный payload создания не применяется как update patch.
В пустом месте каждый режим начинает новую базовую фигуру. Запись/undo по-прежнему
идут через одну прежнюю причинную очередь.

Промежуточные `.build/gui259-tools121-check1`–`check4` не PASS: занятой общий
runner, две ошибки компиляции нового кода, затем ошибочное применение payload
создания как patch и наследование AX identifier контейнера детьми. Исправлены
причины; последний AX-контейнер содержит собственные идентификаторы controls.
`check5` и `final` прошли25/25 iPad и8/8 Mac, но снимки всё ещё показывали
непринятое системное скругление. Это не было выдано за визуальный успех.

Окончательный неизменный срез `.build/gui259-tools121-final2`: **25/25 на
физическом iPad** (23 native, 2 UI), **8/8 Mac**, без skips и xcresult runtime
warnings. Source SHA:
`eea74c0a6ae6e1eaf76fa23ac489f96499095614c8af447b6b71f2a36cc279ce`.
Core **26/26, 5 suites** на том же SHA: `.build/gui259-support121/`.
Проверены быстрые normal/union/subtract/intersect/exclude на странице, доске
и обложке до SQL admission, сохранение и удержанный старый cohort; круглая
геометрия live/settled и реальные пиксели выреза; лазер после отпускания
без дальнейших событий (полный след → короче с хвоста → пусто); повторные
нажатия, палитра, пресеты и сохранение настроек.

Снимки final2 параметров ластика и фигур просмотрены: малые углы и отсутствие
избыточного chrome подтверждены. Предыдущие снимки лазера и круглого выреза
просмотрены на неизменном коде этих владельцев. Simulator не использовался.
Native Pencil использует тестовые UITouch: аппаратное ощущение пера, системные
FPS/CPU/GPU, десять повторов и30минут общей работы этим не доказаны.

### Установленная121 выявила пропущенную границу экспорта; корректирующая122

Signed121 установлена in-place в13:33UTC; версии обоих bundle сверены,
байтовая опись Mac и workspace registry iPad сохранены. Однако live MCP
получал ipc_timeout: sample главного потока Mac выявил
`CurrentViewPreviewWriter → PageCompositionRenderer → ImageRenderer →
CGSoftMask → aa_render`. Экспорт нативной фигуры передавал сырую плотную сетку
ластика в CPU-маску. Локальные25+8 этого не доказывали. Доказательства и
неуспешное чтение сохранены в `.build/gui259-install121/`; Mac завершён
штатным NSRunningApplication.terminate с `Drained59005`, без forced kill.

В122 экспорт графики/текста заранее готовит общую NotebookElementAppearance
вне main actor и передаёт тот же нормализованный контур painter. Второй
алгоритм/кэш/писатель не добавлен. Резервирование памяти экспорта учитывает
CPU/GPU-вершины round sweep вместо прежней оценки только для пера.
Добавлена регрессия2048samples в одной маленькой области: итоговые пиксели,
время завершения и доступность main actor во время подготовки.
`.build/gui259-tools122-final`:25/25 physical iPad и9/9 Mac PASS на исправлении
экспорта, включая прежние UI-сценарии. После уточнения оценки памяти проведён
отдельный прицельный `final2`; его окончательная квитанция указана ниже.

`final2` прошёл6/6 physical iPad и9/9 Mac, но сборщик правильно отказал до
сборки: при изменённой UI-фикстуре в этой узкой квитанции не было названного
жестового сценария. Свидетельства не дописывались и требование не обходилось;
полный выбранный выше срез повторён как `final3` на неизменных исходниках.

Окончательный `final3` прошёл **25/25 physical iPad** (23 native + 2 UI) и
**9/9 Mac**, без skips и xcresult runtime warnings. Неизменный source SHA:
`a5c5fae4fba9af888c7385d8b4b65b8b2f4771b1b6c87d2b964abf0bbb200d5a`.
Supporting Core на том же SHA: **26/26, 5 suites**, `.build/gui259-support122/`.

Signed **0.3.119(122)** установлена in-place в13:51UTC; квитанции
`.build/gui259-build122/build.json`, `.build/gui259-install122/installation.json`.
Установленные версии122 на обеих платформах сверены; manifest Mac равен
`8b9f4613406c469e349516b242cf1e040fb9c02e8b7f5ec581e36c58b23eedbc`.
Байтовые описи Mac до relaunch и workspace registry iPad не изменились.
Контейнеры, допуск и ключи не сбрасывались; прежние архивы не открывались.

Installed MCP ready, cursor20073. Последний успешный baseline перед121 —
cursor20060; перед122 Mac уже был штатно закрыт, новый baseline не выдумывался.
Presence/камера и наблюдение страницы с basis совпали. Board basis также
совпал, но его видимая проекция имеет14 вместо15 объектов: прежний частично
стёртый `physical-acceptance-notes` новой круглой геометрией классифицирован
полностью стёртым. Адресное чтение подтверждает сохранённый source; остальные
14 объектов совпали. Это изменение derived appearance, не удаление записи.
Первая холодная page observation дала ipc_timeout; один повтор завершился
ready с неизменным содержанием. Это остаётся ограничением времени холодного
чтения и не выдано за performance PASS.

Текущий page preview сформирован, Mac UI отвечает, показывает содержание и
«Подключено»; selection получен от физического iPad
5124BDCA-7613-4E48-B09B-928D81A03D4E. Доказательства:
`.build/gui259-install122/live-after.json`, `page-retry.json`,
`live-readback-extra.json`, `live-readback.json`. Плотный export regression
в окончательном Mac xcresult занял0.383с. Снимок параметров ластика final3
просмотрен. Ручное ощущение аппаратного Pencil и полная длительная приёмка
остаются открыты; GUI-259 передана на повторную приёмку, не закрыта как Done.

## 19 сентября 2026 — GUI-259: переключение инструмента одним тапом, 123

Открытые параметры122 перехватывали первый toolbar touch модальным outside
shield. UIKit modal presentation удалён, не оставлен альтернативным путём.
Один anchored sibling-overlay пропускает область настоящего toolbar через
hit-testing; существующие SwiftUI-кнопки по-прежнему единственные владельцы
выбора/палитры/закрытия. Touch не воспроизводится синтетически, инструмент
по координатам повторно не вычисляется. Вне toolbar tap только закрывает
панель, не уходит в сцену. Anchor preference и SwiftUI Layout обслуживают
положение и измерение; состояние панели остаётся у toolbar. Отступы, радиус, цвета и размеры панели
не менялись: замечание про тесные отступы Амир отозвал как старый скриншот.

Выбраны3 physical iPad UI-сценария: новый literal-coordinate one-tap switch,
старые повторное нажатие/сохранение настроек и параметры всех инструментов.
Область намеренно не расширена до Core/Mac: их поведение не менялось;
номер пары123 синхронный, wire32/manifest14 прежние.

Первый `.build/gui259-tools123` выполнил3/3 жеста, но не принят: UIKit выдал
runtime warning об инъекции subview внутрь UIHostingController.view.
Промежуточный `-final` с UIKit sibling не принят:3 тестовых запуска упали
из-за несоответствия controller containment и view hierarchy. Оба кандидата
полностью удалены. Окончательный путь — обычный SwiftUI overlay в NotebookRootView
по anchor preference toolbar, без UIKit-инъекции, modal presenter и копии
состояния. `-final2` также проверяет открытие меню дополнительных инструментов
поверх параметров и выбор фигуры. Production во время этих попыток не менялся.

Окончательный `.build/gui259-tools123-final2`: **3/3 physical iPad UI PASS**,
без skips и xcresult runtime warnings. Source SHA:
`991ad37a25521605a91d6e49cf64d0fd20aa6c6cf67cee52f05a2d22161f89e0`.
Проверены первый tap eraser→marker, marker-settings→palette, palette→pen,
повторный tap для закрытия, меню дополнительных инструментов поверх параметров,
shape→eraser; прежние выбор/сохранение настроек и outside dismiss сохранены.
Снимки `-final2-images` экспортированы, параметры фигур просмотрены.
Это три конкретных жестовых сценария на физическом устройстве, не полный
регрессионный проход и не повторная аппаратная приёмка чернил.

Визуальный просмотр `final2` обнаружил, что SwiftUI shadow на всём содержимом
добавляет тени отдельным UIKit controls. Тень перенесена только на фон панели;
начатая сборка `.build/gui259-build123` остановлена через SIGINT собственного
xcodebuild и не устанавливалась. Неизменный после этой визуальной правки
срез повторяется как `final3`; отдельная сборка будет `build123-final`.

`final3` не принят: вариант отдельного background shadow нарушил открытие/
закрытие в3 UI-сценариях. Он удалён; фон, controls и обводка теперь явно
объединены compositingGroup перед одной общей тенью. После этого
`.build/gui259-tools123-final4` — **3/3 physical iPad UI PASS**,0 skips,
0 xcresult runtime warnings, с теми же неослабленными ожиданиями. Source SHA:
`3bb0d506e6948975f5d94f8d53f943a17e2c5d52436c156f6ad5b553cd19f844`.
Снимок фигур `final4-images` просмотрен до запуска выпуска: лишних теней у
переключателей нет, прежние размеры, отступы и малые углы сохранены.

Signed **0.3.120(123)** установлена поверх122 на Mac и физический iPad
в14:28UTC. `.build/gui259-build123-final/build.json` и
`.build/gui259-install123/installation.json` связывают тот же final4 source
с подписанными установленными bundle. Mac завершён штатно с `Drained63700`;
байты store/registry до relaunch и iPad workspace registry не изменились.
Uninstall/reset/forced kill не использовались; отдельная GUI183 private pair
не изменялась. Установленные версии123 обеих платформ сверены.

Installed MCP ready: cursor20245→20276, page header+basis и board revision+basis
совпали. Public presence после запуска отражает страницу/viewport физического
iPad вместо прежней доски/viewport Mac; неизменность камеры не заявляется.
Known selection получен от iPad5124BDCA-7613-4E48-B09B-928D81A03D4E.
Квитанции `live-before.json`, `live-after.json`, `ipad-apps.json` находятся в
`.build/gui259-install123/`. GUI-259 возвращена In Review; этот срез исправляет
один toolbar gesture и не переобъявляет закрытыми прежние условия полной приёмки.

## GUI-259: выбор наложения рядом с фигурой, 19 сентября — 124

В `NotebookDrawingToolSettingsView` два прежних Picker теперь находятся в
одной верхней строке: слева значок выбранной фигуры, справа название операции.
Отдельная нижняя строка удалена; ширина 264, отступы и оформление панели
сохранены. Binding остаются у прежних device-local preferences; Boolean-
геометрия, записи содержания и владелец открытия панели не менялись.

`.build/gui259-tools124-final2`: **1/1 physical iPad UI PASS**, 0 skips,
0 runtime warnings. Сценарий `testShapeAndOperationSelectorsShareTopRowAndKeepIndependentSelections`
переключает все 5 операций, проверяет расположение справа на одной высоте
выше толщины, отдельно выбирает треугольник и повторно открывает панель с
сохранёнными значениями. Снимок `shape-and-operation-top-row` экспортирован
в `-final2-images` и просмотрен: значок и полное название не пересекаются,
панель стала короче без расширения. Первые 2 попытки проверяли неверное AX-
представление native Picker; сценарий исправлен на реальный label
`Наложение, <операция>`, UI-код между попытками не менялся.

Неизменный source SHA:
`1786b64962f3145c0bb61c48140f7c1eb2fdf9aaea69b5dd029fa7bb3c58f89d`.
Проверка относится к компоновке и выбору настроек, не к повторной приёмке
Boolean-геометрии, аппаратного Pencil или общей производительности.

Signed **0.3.121(124)** установлена поверх123 на обе платформы в14:52UTC;
`.build/gui259-build124/build.json` связан с тем же source. Mac завершён
штатно (`Drained74053`), store/registry bytes до relaunch и iPad registry
совпали, версии124 сверены. Private GUI183/GUI240 apps, сеть, containers и
ключи не менялись; uninstall/reset/force quit не применялись.

Installed MCP сначала дал ready20591 (baseline20464): board revision+basis
совпали, page header отличается только contentStamp23→26 от прежнего iPad-
актора; inkStamp5 и остальные поля прежние. Неизменность всех content basis
и камеры не заявляется. После этого presence/selection дали `ipc_timeout`.
Mac PID81557 занял98–100% CPU; `mac-startup.sample.txt` (1s,14:54:32UTC)
показывает main в `SceneCompositionTiles.prepare` → `paintElement` →
`SceneRasterCompositor.drawView` → `ImageRenderer` → CoreGraphics soft-mask/
stroke `aa_render`. Это отдельное подтверждённое ограничение GUI-255;
renderer в этом изменении не менялся. Повторный startup readback и полная
приёмка пары не объявляются пройденными. Установка и scoped iPad UI прошли,
но не скрывают эту блокировку живой доски Mac.

В14:56:48UTC тот же Mac PID81557 восстановился без вмешательства: CPU1.9%,
все4 MCP read снова ready20743 (`live-recovered.json`). Board revision/basis
прежние; у page header только contentStamp вырос26→32 от того же iPad-актора,
inkStamp и остальные поля не изменились. Долгая блокировка startup осталась
подтверждённым ограничением GUI-255, но это не постоянный hang. Точная
длительность отдельной raster operation не измерена. Полная физическая
приёмка по-прежнему не заявляется; scoped layout UI и финальный MCP readback
зафиксированы отдельно.
