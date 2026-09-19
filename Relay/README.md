# Notebook reverse relay

Небольшой Node-сервис без npm-зависимостей. Единственный payload — непрозрачный
сквозной TLS-поток доверенной пары. Это не HTTP/SSH/App Server proxy общего назначения.
Mac устанавливает исходящий uplink; роутер и Mac не открывают входящий интернет-порт.

## Развёртывание

Нужны Node 22 LTS+, HTTPS-домен, сертификат, входящий 443/tcp и закрытый root-only
канал выдачи capabilities. На `catocut.com` используется отдельный systemd-сервис.
Код не содержит паролей сервера или секретов маршрутов.

Для `https://catocut.com` A-запись корня (`@`) должна указывать на relay;
изменения только `www` недостаточно. Перед standalone-выпуском сертификата
проверить ответ авторитетных DNS и доступность 80/tcp для ACME. Certbot timer
продлевает сертификат, deploy hook устанавливает его и перезагружает TLS только
у уже работающего сервиса; после первого выпуска сервис запускается отдельно.

```sh
install -d -o notebook-relay -g notebook-relay -m 700 /var/lib/notebook-relay
install -d -o root -g notebook-relay -m 750 /etc/notebook-relay
install -d -o root -g root -m 755 /opt/notebook-relay
install -o root -g root -m 644 relay.mjs /opt/notebook-relay/relay.mjs
# Создать отдельного системного пользователя notebook-relay без shell заранее.
# Установить fullchain.pem и privkey.pem: root:notebook-relay, 0640.
install -m 644 notebook-relay.service /etc/systemd/system/notebook-relay.service
```

Создать **отдельный маршрут на каждый iPad**; команда никогда не перезаписывает
файл выдачи. При добавлении в уже работающую базу сначала остановить сервис,
чтобы его текущий владелец не потерял изменения. Provision не включает доступ.

```sh
systemctl stop notebook-relay
node /opt/notebook-relay/relay.mjs provision \
  /var/lib/notebook-relay/routes.json /root/notebook-ipad-route.json https://catocut.com
chown notebook-relay:notebook-relay /var/lib/notebook-relay/routes.json
chmod 600 /var/lib/notebook-relay/routes.json /root/notebook-ipad-route.json
systemctl daemon-reload
systemctl enable --now notebook-relay
curl --fail https://catocut.com/healthz
```

Защищённо передать файл на Mac; импортировать в Notebook → Устройства → iPad →
Интернет-доступ. Не публиковать JSON в Git, Linear, материалах Notebook или логах.
Выключение/повторное включение в UI отзывает/меняет client capability. Host capability
хранить как административный секрет; при его компрометации удалить маршрут при
остановленном сервисе и выдать новый. Это не ключ содержимого: даже обе capability
без ключа пары не дают расшифровку или право исполнить Notebook-команду.

## TLS, ресурсы и обслуживание

`renew-certificate.sh` — deploy hook certbot для данного домена. Он устанавливает
новый сертификат/ключ с прежними правами и вызывает SIGHUP; живые потоки не
перезапускаются. Проверять `certbot.timer`, дату сертификата и HTTPS healthz.
Обновлять сам код в сервисное окно: restart разрывает потоки, но не задачи Mac.

Пределы: 64 маршрута, 128 sockets, два активных тоннеля и один ожидающий host на
маршрут, 256 одноразовых tickets с TTL 120 s, ожидание peer 45 s, idle 120 s,
сессия 1 h/4 GiB; 120 запросов/мин/IP с ограниченной таблицей. Node streams
используют backpressure. systemd: 192 MiB memory, 32 tasks, 512 descriptors,
непривилегированный пользователь с единственной CAP_NET_BIND_SERVICE.

На диске — хеши capabilities и состояние отзыва, не сами capabilities и не payload.
В stdout — только запуск и счётчики. `/healthz` подтверждает жизнь relay, но не
доступность Mac, сопряжение, admission Codex или работу модели.

```sh
node --test Relay/relay.test.mjs
```

Нативная композиция Network.framework CONNECT + прежний Notebook TLS отдельно
проверяется `NotebookTransportSessionTests/testPublicRelayKeepsControlResponsiveDuringLargeMaterialAndRevokesTheTunnel`
с `NOTEBOOK_TEST_RELAY_HOST_FILE`, указывающим на **отдельный тестовый** host JSON.
Тест включает, затем отзывает маршрут; его нельзя запускать на активном маршруте
пользователя. Ошибка теста требует явной проверки/отзыва маршрута перед повтором.
