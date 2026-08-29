# Исследование системных контрактов

Проверено 29 августа 2026 года по текущей документации Apple и MCP SDK.

## Выбранные владельцы

| Потребность | Системный владелец | Использованный контракт | Следствие в коде |
|---|---|---|---|
| Письмо Apple Pencil | [PencilKit `PKCanvasView`](https://developer.apple.com/documentation/pencilkit/pkcanvasview) | Canvas принимает события Pencil и хранит их как drawing | `PencilCanvasView` фиксирует масштаб `1`, отключает прокрутку и передаёт `PKDrawing.dataRepresentation()` |
| Обычная ручка | [`PKInkingTool`](https://developer.apple.com/documentation/pencilkit/pkinkingtool-swift.struct) | Выбранная ширина задаёт основу штриха, а PencilKit учитывает силу, азимут и угол Pencil | Маленькая палитра меняет цвет и базовую толщину инструмента `.pen` |
| Нажим Pencil | [`PKInkingTool.color`](https://developer.apple.com/documentation/pencilkit/pkinkingtool-swift.struct/color-5xmlo) | Слабый нажим добавляет прозрачность, сильный повышает непрозрачность | Приложение передаёт непрозрачный базовый цвет, а итоговую прозрачность каждого штриха определяет PencilKit |
| Отмена двумя пальцами | [`UITapGestureRecognizer.numberOfTouchesRequired`](https://developer.apple.com/documentation/uikit/uitapgesturerecognizer/numberoftouchesrequired) | Распознаватель отличает касание заданным числом пальцев | Одно касание двумя пальцами возвращает снимок перед последним движением Pencil на этом листе |
| Цвет бумаги | [`NSAppearance.performAsCurrentDrawingAppearance`](https://developer.apple.com/documentation/appkit/nsappearance/performascurrentdrawingappearance(_:)) | Рендер можно выполнить в явно выбранной светлой теме | Светлый лист сохраняет тёмные чернила на iPad, в окне Mac и в PNG для агента |
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

## Исполнимая граница безопасности

`localOnly(true)` и запрет сети внутри WebKit ограничивают поверхность, но не
доказывают личность Mac или iPad. Текущий TCP-канал не шифруется. Это честный
контракт личного прототипа в доверенной сети. Производственный канал требует
пары ключей, явного подтверждения пары на обоих устройствах и TLS; случайный
секрет в исходном коде таким доказательством не является.
