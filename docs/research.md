# Исследование системных контрактов

Проверено 29 августа 2026 года по текущей документации Apple и MCP SDK.

## Выбранные владельцы

| Потребность | Системный владелец | Использованный контракт | Следствие в коде |
|---|---|---|---|
| Письмо Apple Pencil | [UIKit: Handling input from Apple Pencil](https://developer.apple.com/documentation/uikit/handling-input-from-apple-pencil) | `UITouch` отдаёт координату, силу, наклон и поздние уточнения измерений | `PaperInputView` принимает только Pencil, превращает измерения в `PKStrokePoint`, а закрытый от касаний `PKCanvasView` рисует готовый `PKDrawing` |
| Плавная ручка | [`coalescedTouches`](https://developer.apple.com/documentation/uikit/getting-high-fidelity-input-with-coalesced-touches) и [`predictedTouches`](https://developer.apple.com/documentation/uikit/uievent/predictedtouches%28for%3A%29) | UIKit отдаёт пропущенные точки частого опроса и временный прогноз следующего положения | В штрих попадают все измеренные точки, а прогноз живёт только в предпросмотре и заменяется новым событием |
| Нажим Pencil | [`UITouch.force`](https://developer.apple.com/documentation/uikit/uitouch/force) и [`PKStrokePoint.opacity`](https://developer.apple.com/documentation/pencilkit/pkstrokepointreference/opacity) | Система калибрует средний нажим как `1`, а непрозрачность точки умножает непрозрачность чернил | Цвет штриха хранится полностью непрозрачным; каждая точка получает непрозрачность между выбранным минимумом и `1` по текущей силе |
| Стирание | [`PKDrawing.erasingPath`](https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct) | PencilKit применяет путь ластика прямо к существующему рисунку | Каждая точка пути получает ширину от текущего нажима; PencilKit вырезает пройденное место и сохраняет части штриха вокруг него |
| Отмена двумя пальцами | [`UITapGestureRecognizer.numberOfTouchesRequired`](https://developer.apple.com/documentation/uikit/uitapgesturerecognizer/numberoftouchesrequired) и [`UILongPressGestureRecognizer`](https://developer.apple.com/documentation/uikit/uilongpressgesturerecognizer) | Распознаватели закреплены прямо за видимым холстом и принимают только два прямых касания | Касание возвращает один снимок, а удержание повторяет отмену каждые 95 миллисекунд |
| Чистое касание бумаги | [UIKit: Handling touches in your view](https://developer.apple.com/documentation/uikit/handling-touches-in-your-view) | Обычный `UIView` различает прямое касание и Pencil | Верхний `PaperInputView` забирает касания; один палец заканчивается пустым действием, два идут жестам, Pencil идёт ручке; `PKCanvasView` не получает событий и служит только рендерером |
| Цвет бумаги | [`NSAppearance.performAsCurrentDrawingAppearance`](https://developer.apple.com/documentation/appkit/nsappearance/performascurrentdrawingappearance(_:)) | Рендер можно выполнить в явно выбранной светлой теме | `PaperInkRenderer` одинаково сохраняет тёмные чернила в окне Mac и в PNG для агента |
| Прямая связь iPad и Mac | [Network.framework](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api) | Network — основной API Apple для TCP, Bonjour и peer-to-peer Wi-Fi | Mac публикует `_tetrad._tcp`, iPad ищет сервис и открывает двусторонний канал |
| Типизированные сообщения | [WWDC25: structured concurrency with Network](https://developer.apple.com/videos/play/wwdc2025/250/) | `Coder` кадрирует `Codable`-сообщения для `NetworkConnection` | `WireMessage` передаётся без собственного парсера длины и сокетов |
| Только ближайший канал | [`localOnly(true)`](https://developer.apple.com/documentation/network/nwparametersprovider/localonly%28_%3A%29) | Listener рекламируется и принимает соединения только на local link | Тетрадь не создаёт доступный из интернета сервер |
| Интерактивный ответ агента | [`WKScriptMessageHandler`](https://developer.apple.com/documentation/webkit/wkscriptmessagehandler) | JavaScript посылает структурированное сообщение нативному обработчику | `window.tetrad.commit(value)` сохраняет состояние кнопок и схем |
| Инструменты для ИИ-агента | [MCP TypeScript SDK v2](https://ts.sdk.modelcontextprotocol.io/v2/) | Стабильная ветка v2 реализует спецификацию 2026-07-28 и stdio transport | `McpServer` публикует шесть инструментов, `serveStdio` владеет каналом |

Apple пометила Multipeer Connectivity устаревшим в 2026 году и прямо
рекомендует Network.framework для нового peer-to-peer кода. Поэтому
`Тетрадь` не строит новый слой поверх Multipeer Connectivity. Новый Swift API
`NetworkConnection`, `NetworkListener` и `NetworkBrowser` появился в 2025
году, работает со structured concurrency и является самым прямым системным
маршрутом для этого приложения.

## Как нажим становится прозрачностью

`UITouch.force` содержит измеренную силу; Apple калибрует средний нажим как
`1`. Обычный инструмент `.pen` сохранял непрозрачность точек равной `1`,
поэтому владелец нужной зависимости находится в приложении. Для каждой новой
точки оно вычисляет:

```text
pressure = clamp(force, 0, 1)
opacity  = minimum + (1 - minimum) * pressure
```

Так регулятор задаёт нижнюю границу, сила `0.5` даёт середину между этой
границей и полным цветом, а обычный нажим `1` даёт полный цвет. Верхняя граница
регулятора равна `0.6`: даже в самом тёмном положении у Pencil остаётся `0.4`
диапазона для видимого ответа на силу. Цвет
`PKInk` всегда имеет alpha `1`; видимая переменная прозрачность принадлежит
точкам. UIKit иногда уточняет силу уже после исходного события. Приложение
связывает уточнение с точкой через `estimationUpdateIndex`, обновляет живой
штрих и ждёт уточнение до 120 миллисекунд после подъёма Pencil. Поэтому
сохранённый штрих содержит измеренный нажим, а не одно значение настройки на
всю линию.

## Как нажим меняет ластик

Регулятор ластика задаёт его наибольшую ширину. Каждое измерение Pencil
вычисляет свою ширину тем же нормализованным нажимом:

```text
pressure     = clamp(force, 0, 1)
eraser_width = 3 + (selected_width - 3) * pressure
```

При самом лёгком касании получается кончик шириной `3` points. При нажиме `1`
он доходит до выбранной ширины. Регулятор позволяет выбрать максимум от `9`
до `48` points и сохраняет выбор между запусками.

`PaperInputView` помещает вычисленную ширину в каждую точку пути и применяет
`PKDrawing.erasingPath` к рисунку, который был до начала движения. Поэтому
движение ластика вырезает только пересечённую полосу. Проверочный маршрут
строит линию длиной `200` points, проводит ластиком по её середине и получает
две сохранённые части по краям. Затем он увеличивает ластик и проверяет, что
вырез стал шире. Так проверяются локальное стирание и выбранная толщина.

## Кто получает касание

```text
палец x1 ---------> PaperInputView ---------> пустое действие
палец x2 ---------> жест -------------------> undo / лист / тетрадь
Apple Pencil -----> точки + нажим ----------> PKStroke / путь ластика
PKCanvasView <----- готовый PKDrawing         (ввод выключен)
```

Это разделение устраняет прежнего второго владельца жестов. Системное меню
редактирования возникало внутри интерактивного `PKCanvasView`, поэтому запрета
на уровне внешнего responder было мало. Теперь холст PencilKit не участвует в
hit-testing, а простой `PaperInputView` сам принимает и завершает касание
одного пальца. У него нет текста, выделения и меню, которое можно открыть.

## Контракт страницы

```text
PageDocument
|-- drawingData  + drawingStamp   <- только Pencil
`-- elements[]   + agentStamp     <- MCP и WebKit
```

Два штампа — это не лишняя история. Они различают два одновременных факта:
человек дописал линию, а агент в тот же момент изменил схему. При сохранении
`TetradStore.saveMergedPage` берёт самый новый штамп каждого потока отдельно.
Общий directory-lock делает одно чтение, слияние и атомарную замену файла
неделимой операцией для Swift-приложения и Node MCP.

MCP меняет агентский поток только при совпадении `expected_revision`. Это
наблюдаемое правило: два агента, прочитавшие одну версию, не могут молча
перезаписать ответы друг друга. Первый записывает, второй получает конфликт и
перечитывает лист.

## Геометрия

Текущий физический iPad — iPad Pro 11-inch (3rd generation, `iPad13,4`). У
полноразмерных iPad с экраном 264 ppi один UIKit point равен двум пикселям,
поэтому один дюйм равен 132 points. Шаг клетки равен `132 / 2.54`, то есть
одному сантиметру; приложение делит его пополам и получает `25.9843` points.
Этот контракт проверен тестом. Для iPad mini с другой
плотностью нужна отдельная калибровка; текущая сборка предназначена для
подключённого 11-дюймового iPad.

Размер страницы хранится независимо от размера окна. `PageSurface` вычисляет
один равномерный масштаб, привязывает отрисовку к левому верхнему углу самого
листа, а готовый лист помещает в центр окна. Поэтому изменение размера окна на
Mac или iPad меняет только свободное поле вокруг бумаги: клетка, штрихи и слои
агента остаются совмещены.

## Исполнимая граница безопасности

`localOnly(true)` и запрет сети внутри WebKit ограничивают поверхность, но не
доказывают личность Mac или iPad. Текущий TCP-канал не шифруется. Это честный
контракт личного прототипа в доверенной сети. Производственный канал требует
пары ключей, явного подтверждения пары на обоих устройствах и TLS; случайный
секрет в исходном коде таким доказательством не является.
