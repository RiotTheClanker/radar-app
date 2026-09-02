# Docs

Start with **[architecture.md](architecture.md)** — it is the hub, and it is
short.

| Doc | Read it when |
|---|---|
| [architecture.md](architecture.md) | You are new, or you need to know where something lives and why |
| [ui-contract.md](ui-contract.md) | You are changing anything under `app/lib/ui/`. The rules that bind |
| [ui-development.md](ui-development.md) | You are writing a new UI, in Flutter or otherwise |
| [engine-api.md](engine-api.md) | You are calling the Rust engine, or changing what it offers |
| [data-sources.md](data-sources.md) | You need to know where a byte came from, or are reimplementing the fetch layer |

Setup, commands, codegen and the release process are in
[CONTRIBUTING.md](../CONTRIBUTING.md).

## The five-minute version

No server. Bytes come from public NOAA/NWS buckets, a Rust engine on the
device decodes and renders them, and Flutter draws the result.

```
ui/  ->  state/  ->  data/  ->  bridge  ->  rust/radar_core
```

Imports only ever point right. `state/` and `data/` never import a widget,
which is what lets the UI be replaced without touching anything below it.
