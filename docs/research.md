# Исследование системных контрактов

Проверено 29 августа 2026 года по текущей документации Apple и MCP SDK.

## Выбранные владельцы

| Потребность | Системный владелец | Использованный контракт | Следствие в коде |
|---|---|---|---|
| Письмо Apple Pencil | [PencilKit `PKCanvasView`](https://developer.apple.com/documentation/pencilkit/pkcanvasview) | Canvas принимает события Pencil и хранит их как drawing | `PencilCanvasView` фиксирует масштаб `1`, отключает прокрутку и передаёт `PKDrawing.dataRepresentation()` |
| Обычная ручка | [`PKInkingTool`](https://developer.apple.com/documentation/pencilkit/pkinkingtool-swift.struct) | Выбранная ширина задаёт основу штриха, а путь хранит измерения Pencil | Маленькая палитра меняет цвет и базовую толщину инструмента `.pen` |
| Нажим Pencil | [`PKStrokePoint.force`](https://developer.apple.com/documentation/pencilkit/pkstrokepointreference/force) и [`opacity`](https://developer.apple.com/documentation/pencilkit/pkstrokepointreference/opacity) | Средний нажим имеет силу `1`; непрозрачность точки служит множителем цвета | После получения последних значений силы приложение явно переводит каждую точку из диапазона `0...1` в выбранный минимум `...1` |
| Стирание | [`PKEraserTool`](https://developer.apple.com/documentation/pencilkit/pkerasertool) | Векторный ластик удаляет целый штрих PencilKit | Кнопка в палитре и жест Pencil меняют одно состояние инструмента, поэтому экран всегда показывает выбранный режим |
| Отмена двумя пальцами | [`UITapGestureRecognizer.numberOfTouchesRequired`](https://developer.apple.com/documentation/uikit/uitapgesturerecognizer/numberoftouchesrequired) и [`UILongPressGestureRecognizer`](https://developer.apple.com/documentation/uikit/uilongpressgesturerecognizer) | Распознаватели закреплены прямо за видимым холстом и принимают только два прямых касания | Касание возвращает один снимок, а удержание повторяет отмену каждые 95 миллисекунд |
| Чистое касание бумаги | [`UIEditingInteractionConfiguration.none`](https://developer.apple.com/documentation/uikit/uieditinginteractionconfiguration/none) | Холст может отключить системное редактирование UIResponder | Один палец остаётся пустым действием: меню `Select All` и `Insert Space` не строится |
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

`PKStrokePoint.force` содержит измеренную силу, но у обычного инструмента
`.pen` сохранённые точки имели непрозрачность `1` при слабом и сильном нажиме.
Поэтому владелец этого поведения находится в приложении. Для каждой новой
точки оно вычисляет:

```text
opacity = minimum + (1 - minimum) * clamp(force, 0, 1)
```

Так регулятор задаёт самый бледный возможный след, сила `0.5` оказывается
ровно посередине, а обычный сильный нажим `1` даёт полный выбранный цвет.
PencilKit может прислать последние значения силы уже после завершения касания;
Apple отдельно описывает эту задержку в
[`Handling input from Apple Pencil`](https://developer.apple.com/documentation/uikit/handling-input-from-apple-pencil),
а для PencilKit её фиксирует контракт
[`canvasViewDrawingDidChange`](https://developer.apple.com/documentation/pencilkit/pkcanvasviewdelegate/canvasviewdrawingdidchange(_:)).
Холст поэтому ждёт короткую тишину после штриха, перестраивает только новые
точки и повторяет расчёт, если позднее измерение всё же пришло. Старые штрихи
и штрихи ластика он не меняет.

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
