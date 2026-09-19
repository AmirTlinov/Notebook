# Audit evidence — September 13, 2026

Source: `fceadf0a7cc553813423f356908bf09574f79a15`.
Findings and limitations: [audit summary](../../audit-2026-09-13.md).

- `native-observed.json`: Xcode commands/results, classification of seven fixture
  failures and cold document-preparation timing.
- `mcp-observed.json`: observed diagnostic output.
- `mcp-reproduce.mjs`: a dated reproducer of four defects, using the **then-current**
  MCP interface. It is not a regression runner for today's SDK.

## Historical reproduction

Use a checkout of the audited revision with its own MCP dependencies:

```sh
swift build --product notebook-ipc-test-host
node --import ./MCP/node_modules/tsx/dist/loader.mjs docs/audit-evidence/2026-09-13/mcp-reproduce.mjs
```

`NOTEBOOK_IPC_TEST_HOST` can select an already-built isolated host.
The script creates temporary stores/sockets, cleans them and prints a separate
results.json path. It neither connects to the installed helper nor reads user data.

The former attention tool used real MCP client/server SDK with synthetic valid IPC
responses, with and without an SHA-matching image. This tested response contracts,
not image decoding or physical iPad delivery. Other scenarios used actual Core through
the test host.

Successful execution of this diagnostic meant **reproducing known defects**, not
application PASS. Its deliberately negative expectations should fail after repair.
It is excluded from the permanent verification route.

Small observed records remain tracked. Full local xcresults/logs/images were in
`.build/audit-20260913-selected/` and `.build/audit-20260913-ui-density/`.
The first run had seven failures and no overall PASS receipt.
