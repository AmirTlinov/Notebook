# Тетрадь: карта проекта

```text
Tetrad/
|-- README.md                 # Назначение, запуск и проверенный пользовательский путь.
|-- Package.swift             # Один общий домен данных без UI и сети.
|-- Sources/TetradCore/       # Тетради, страницы, версии, диск и wire-сообщения.
|-- Tests/TetradCoreTests/    # Проверки навигации, слияния и атомарной записи.
|-- Applications/
|   |-- project.yml           # Два нативных target: iPad и Mac.
|   |-- Shared/               # Лист, сетка, WebKit-слои, модель и Network.framework.
|   |-- iPad/                 # UIKit-ввод, единый Metal-холст и PencilKit-хранилище.
|   `-- Mac/                  # Тихое зеркало, file watch и PNG для агента.
|-- MCP/                      # Локальный stdio-сервер над файлами Mac-приложения.
|-- docs/research.md          # Проверенные внешние API и выбранные следствия.
`-- verify.sh                 # Один локальный проверочный маршрут.
```

Путь изменения всегда короткий: намерение человека -> `PageDocument` -> атомарный файл -> Network.framework -> такой же лист на втором устройстве. Pencil меняет только `drawing`; MCP и интерактивные элементы меняют только `elements`.
