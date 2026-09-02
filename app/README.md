# `app/` — the Flutter app

This is the UI and the fetch layer. It is not where the radar maths lives —
that is `rust/radar_core/`, one level up.

```
lib/main.dart      boot: init the bridge, install the theme, run
lib/ui/            widgets — the only layer that may hold a BuildContext
lib/state/         PaneController: one pane's state, no widgets
lib/data/          network fetchers and file IO, no widgets
lib/src/rust/      GENERATED bindings — never hand-edit
rust/              the bridge crate; codegen reads src/api/
rust_builder/      vendored cargokit build glue; not ours to edit
test/              Dart tests
```

```
flutter pub get
flutter run -d linux     # or -d windows, or a connected Android device
flutter analyze          # must be clean
flutter test
```

Setup and code generation: [../CONTRIBUTING.md](../CONTRIBUTING.md).
How it all fits together: [../docs/architecture.md](../docs/architecture.md).
Changing anything in `lib/ui/`: [../docs/ui-contract.md](../docs/ui-contract.md).
