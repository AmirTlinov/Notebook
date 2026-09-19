# Notebook reverse relay

A small dependency-free Node service. Its only payload is the trusted pair's
opaque end-to-end TLS stream, not a general HTTP/SSH/App Server proxy.
Mac opens an outbound uplink; neither router nor Mac needs an inbound internet port.

## Deployment

Requirements: Node 22+, an HTTPS domain/certificate, inbound TCP/443 and a protected
root-only capability-provisioning channel. The configured deployment uses a separate
systemd service on `catocut.com`; source contains no server or route secrets.

For that deployment the root A record (`@`), not only `www`, must resolve to the
relay. Before standalone ACME issuance, check authoritative DNS and TCP/80 reachability.
The certbot timer renews certificates; its deploy hook updates TLS only for an
already-running service. Start the service separately after first issuance.

Run the installation commands from this directory, after creating a dedicated
system user `notebook-relay` without a login shell:

```sh
install -d -o notebook-relay -g notebook-relay -m 700 /var/lib/notebook-relay
install -d -o root -g notebook-relay -m 750 /etc/notebook-relay
install -d -o root -g root -m 755 /opt/notebook-relay
install -o root -g root -m 644 relay.mjs /opt/notebook-relay/relay.mjs
# Install fullchain.pem and privkey.pem as root:notebook-relay, mode 0640.
install -m 644 notebook-relay.service /etc/systemd/system/notebook-relay.service
```

Provision a **separate route per iPad**. Provisioning never overwrites an issuance
file and does not enable access. Stop an existing service before changing its
database so the running owner cannot overwrite the new route:

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

Transfer the JSON securely to Mac and import through Notebook → Devices → iPad →
Internet access. Never publish it to Git, Linear, Notebook content or logs.
Disabling/re-enabling UI access revokes/rotates the client capability. Treat the host
capability as an administrative secret; if compromised, remove the route while
stopped and issue another. Even both routing capabilities cannot decrypt content
or authorize Notebook commands without the pair key.

## TLS and maintenance

`renew-certificate.sh` is this deployment's certbot hook. It installs the renewed
certificate/key with existing permissions and sends SIGHUP without restarting live
streams. Monitor certbot.timer, expiry and HTTPS health. Update service code in a
maintenance window: restart drops streams, not Mac tasks.

Limits: 64 routes, 128 sockets, two active tunnels and one waiting host per route;
256 one-use tickets with 120-second TTL; 45-second peer wait; 120-second idle;
one-hour / 4 GiB session; 120 requests/min/IP with a bounded address table.
Node streams apply backpressure. systemd caps memory at 192 MiB, tasks at 32 and
descriptors at 512; the unprivileged service receives only CAP_NET_BIND_SERVICE.

Disk stores capability hashes/revocations, not capabilities or payloads.
Stdout reports startup/counters only. `/healthz` proves relay liveness, not Mac
reachability, pairing, Codex admission or a working model.

From the repository root:

```sh
node --test Relay/relay.test.mjs
```

The native CONNECT + Notebook TLS test
`NotebookTransportSessionTests/testPublicRelayKeepsControlResponsiveDuringLargeMaterialAndRevokesTheTunnel`
requires `NOTEBOOK_TEST_RELAY_HOST_FILE` naming a **dedicated test route**.
It enables then revokes that route. Never use an active user route; after failure,
inspect/revoke explicitly before retrying.
