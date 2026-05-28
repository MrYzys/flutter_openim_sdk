# Repository Guidelines

## Project Structure & Module Organization
- `lib/`: Dart API surface plus generated FFI bindings; edit hand-written files only and rerun `dart run ffigen --config ffigen.yaml` after header updates.
- `src/`: Native C sources and `CMakeLists.txt` producing the `openim_ffi` library shared across platforms.
- `example/`: Minimal Flutter client showing `sum` and `sumAsync`; mirror any API changes here.
- `analysis_options.yaml` + `ffigen.yaml`: Central lint and binding configs—treat them as single sources of truth when adjusting tooling.

## Build, Test, and Development Commands
- `flutter pub get` (root and `example/`): Install or refresh dependencies.
- `flutter analyze`: Enforce lint compliance; resolve every warning before committing.
- `dart format .`: Normalize formatting project-wide prior to review.
- `flutter test`: Execute the repository test suite; add `--coverage` when collecting reports.
- `cd example && flutter run -d <device>`: Smoke-test the example app on your target device.

## Coding Style & Naming Conventions
- Dart: 2-space indent, ~100-column limit, files in `lower_snake_case.dart`; classes use `PascalCase`, members/functions `lowerCamelCase` (e.g., `sumAsync`).
- C: 2-space indent with `snake_case` exported symbols declared in `src/openim_ffi.h`; keep signatures stable across Dart and native layers.
- Always regenerate formatting and run `flutter analyze` after modifying generated interfaces.

## Testing Guidelines
- Framework: `flutter_test` with suites under `test/` named `<feature>_test.dart`.
- Minimum coverage: ensure new APIs have direct unit coverage (e.g., `sum(1, 2)` returns `3`, `sumAsync` completes with the same result).
- Prefer deterministic tests; avoid touching FFI threads on the main isolate during assertions.

## Commit & Pull Request Guidelines
- Commits: short, imperative prefixes (`feat(lib): add async sum helper`); scope changes logically.
- PRs: include a descriptive summary, linked issues, analyzer/test evidence, and note whether native headers or generated bindings changed.
- Attach console snippets for key commands (`flutter analyze`, `flutter test`, example run) to speed up review.

## Security & Configuration Tips
- Keep the shared library name `openim_ffi` consistent across Dart loaders and CMake.
- Never hand-edit `lib/src/openim_ffi_bindings_generated.dart`; rely on `ffigen.yaml` regeneration.
- Offload long-running native calls to isolates (patterned after `sumAsync`) to maintain UI responsiveness.
