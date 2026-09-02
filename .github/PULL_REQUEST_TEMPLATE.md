## What this changes

<!-- What is different after this merges, in a sentence or two. -->

## Why

<!-- The reasoning, especially for anything non-obvious. If this fixes a bug,
     say what the bug actually was — that is the comment the next person
     needs. Link the issue if there is one. -->

## How it was checked

<!-- Delete what does not apply. -->

- [ ] `flutter analyze` clean
- [ ] `flutter test`
- [ ] `cargo test` (if the engine changed)
- [ ] Ran the app and looked at it
- [ ] Checked on: <!-- Linux / Windows / Android -->

## Housekeeping

- [ ] Generated files regenerated, not hand-edited
      (`lib/src/rust/**`, `nexrad_sites.g.dart`, `branding/` outputs)
- [ ] `RELEASE_NOTES.md` updated, if this is user-visible
- [ ] Layering held: `state/` and `data/` still import no widgets
