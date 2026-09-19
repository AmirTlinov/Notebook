# Notebook

A shared space for handwriting, documents, and interactive models on iPad and Mac.
Notebooks and documents live on an infinite board; portals connect nested boards.

- **Notebooks** — Apple Pencil writing, drawings, and diagrams.
- **Documents** — Markdown, LaTeX, formulas, and interactive programs.
- **Collaboration** — shared materials across Mac and iPad, with Codex discussions and edits.
  Each device keeps its own page, camera, and selection.

Read the [Notebook philosophy](PHILOSOPHY.md) for the product principles.

## Development

Requires Xcode 27, XcodeGen 2.46+, and Node.js 20+. Application targets are
macOS 27 and iPadOS 27.

Start with the [project map](AGENTS.md) for code ownership and task-specific checks.
From the repository root, inspect the proposed verification scope:

```sh
./verify.sh --plan
```

Resource preparation, builds, signing, and application updates follow the
[release contract](docs/release-build-contract.md). Updates preserve current
data, identities, and keys. Historical archives are not restored automatically.

## Documentation

| Topic | Start here |
|---|---|
| Mac and iPad connection | [Devices and workspaces](docs/installation-pairing.md) |
| Documents and interactive blocks | [Document layout](docs/document-page-fragments.md), [programs](docs/document-program-fragments.md) |
| Working with an agent | [Collaboration](docs/collaboration.md), [Codex](docs/codex-remote-work.md) |
| Authoring through MCP | [Notebook skill](MCP/skills/notebook/SKILL.md), [JavaScript API](docs/notebook-javascript-api.md) |
| Verification results and limitations | [Verification record](docs/verification.md) |

Tasks and their actual status are tracked in the **Notebook** project in Linear.
A successful build establishes only its stated verification scope.
