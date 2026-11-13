# Manifest-driven projects (bootstrap compiler)

This is project organization and CLI tooling, not a claim that every application
framework or runtime is implemented.

## Start and run

```sh
lir init demo
cd demo
lir check
lir run
lir test
lir build
./demo.out
```

The starter contains `project.manifest`, `src/main.lir`, `src/lib.lir`,
`src/tests.lir`, and `.gitignore`. Main and tests import the same library.
Creation refuses existing destinations rather than overwriting files.

`build`, `run`, `check`, `ir`, and `test` accept an explicit source file, an
explicit project directory, or no input (current directory's manifest). An
explicit file bypasses the manifest, preserving single-file use. Runtime
arguments still follow `--`; backend, target, and optimization flags remain CLI
options. Import paths resolve relative to the importing source file, including
nested project entries. Existing hello-world and web-server manifests remain
readable; that does not imply their application domains are fully supported.

## Schema

```json
{
  "name": "demo",
  "version": "0.1.0",
  "source_dir": "src",
  "entry": "main.lir",
  "test_entry": "tests.lir"
}
```

- `name` is required and uses the same safe-name validation as `lir init`.
- `source_dir` defaults to `src`, relative to the project directory.
- `entry` defaults to `main.lir`, relative to `source_dir`.
- `test_entry` is relative to `source_dir`. If omitted, `test` uses an existing
  `source_dir/tests.lir`. If neither exists, it fails with `MissingTestEntry`;
  it does **not** silently run the application's entry. Explicit source-file
  testing is unchanged.
- `version` is optional descriptive text; it does not select dependencies.
- Legacy `description` (string), `targets`, `domains`, `imports`, `permissions`
  (string arrays) are accepted metadata only. They do not configure targets,
  resolve packages, grant permissions, or sandbox execution.
- Unknown keys, duplicate fields, wrong JSON types, malformed JSON and manifests
  over 64 KiB fail. Source paths must be nonempty relative paths, without `..`
  components, backslashes, colons, NUL, or empty slash-separated components.
  `source_dir: "."` is allowed. These are lexical checks, **not a symlink or
  import security boundary**. Only build trusted projects.

Project builds default to `<project>/<name>.out` plus the target's `.exe` or
`.wasm` suffix; `--emit-c` defaults to `<project>/<name>.c`. Explicit `-o` wins
and remains relative to the caller's working directory. Explicit source-file
builds retain their previous `a.out`/`a.c` defaults. No build scripts or implicit
package downloads execute.

## Validation

`python3 tests/project_test.py` checks the generated project across native, VM,
C, and Wasm backends; current-directory and directory inputs; nested imports,
runtime arguments, output overrides and target suffixes; invalid manifests,
missing tests, and explicit-file compatibility. C needs a host compiler; Wasm
execution needs Node or Wasmtime, just as the backend suite does.

## Next foundations for broader application types

The initial [browser Wasm bridge](BROWSER.md) now demonstrates event-driven
execution with JavaScript-owned DOM and events; it is not a full frontend stack.

This increment supplies a common project entry point. It does not add HTTP,
GUI, mobile packaging, database drivers, shared-library linking, or .NET/CLR.
Further independent work is needed:

1. Versioned package/dependency resolution, lockfiles and offline/reproducible
   builds, with integrity validation.
2. Stable standard-library I/O, filesystem, networking and error contracts,
   with backend capability checks and tests.
3. Explicit library artifacts and safe FFI/linking contracts before native
   framework integrations.
4. Web/service, desktop and mobile integrations with platform-specific build,
   signing, deployment and CI validation.
5. Runtime/language facilities (memory ownership or GC strategy, structured
   errors, async/concurrency) as specified and tested features, not metadata.

See also [C# scope](CSHARP_SCOPE.md) for language/runtime boundaries.
