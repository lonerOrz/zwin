# AGENTS.md

## Project

This project uses **Zig 0.16.0**.

All code, build, test, and API decisions must target Zig 0.16.0. Do not assume compatibility with other Zig versions.

Before making changes, inspect the existing code and follow its established patterns.

---

## Core Rules

- Keep changes focused and minimal.
- Do not refactor unrelated code.
- Reuse existing code, abstractions, and dependencies when possible.
- Do not introduce new dependencies unless required.
- Do not change public APIs or behavior unless the task requires it.
- Do not overwrite or discard existing user changes.
- Never use destructive Git commands unless explicitly requested.
- Do not create commits unless explicitly requested.

---

## Zig Version

Verify the compiler when needed:

```sh
zig version
```

Expected version:

```text
0.16.0
```

Do not modify the project just to support a different local Zig version.

---

## Project Structure

Before editing, inspect the repository and pay particular attention to:

- `build.zig`
- `build.zig.zon`
- `src/`
- `test/` or `tests/`
- `README.md`
- `.zigversion`
- CI configuration

If a more specific `AGENTS.md` exists in a subdirectory, follow it for files under that directory.

---

## Build and Test

Use the project's existing build steps.

Default commands:

```sh
zig build
zig build test
```

If the project defines different or additional steps, inspect:

```sh
zig build --help
```

For direct file tests, use:

```sh
zig test path/to/file.zig
```

Run tests relevant to the change. For significant changes, run the full test suite.

If tests cannot be run, state why.

---

## Formatting

Use Zig's formatter:

```sh
zig fmt --check .
```

Format only files affected by the change when possible.

Do not manually fight `zig fmt`.

---

## Code Style

Follow existing project conventions first.

- Types: `PascalCase`
- Functions and variables: `snake_case`
- Prefer clear names over short names.
- Prefer Zig's native error handling and optional types.
- Use `try` for normal error propagation.
- Avoid unnecessary `catch unreachable`.
- Do not use magic values to represent missing data.
- Keep comptime logic as simple as practical.

Do not introduce a new style when an established project style exists.

---

## Memory and Resources

Every allocation must have clear ownership and lifetime.

For allocated resources:

- Know who owns them.
- Know who releases them.
- Handle error paths correctly.
- Use `defer` for normal cleanup.
- Use `errdefer` for cleanup during fallible initialization.
- Do not free resources after ownership has been transferred.

---

## Unsafe and Low-Level Code

Be especially careful with:

- pointers and pointer casts
- alignment
- `@ptrCast`
- `@alignCast`
- `@bitCast`
- `@memcpy`
- `@memmove`
- packed structs
- C ABI
- manual memory management
- SIMD
- volatile memory

Do not bypass safety checks merely to make code compile.

When changing low-level code, verify type safety, alignment, lifetime, ownership, and boundary conditions.

---

## Standard Library

Use the Zig 0.16.0 standard library.

Do not guess APIs from other Zig versions.

Prefer existing project wrappers and abstractions when they already provide the required functionality.

---

## Dependencies

Before adding or changing dependencies, inspect:

```sh
build.zig.zon
```

Prefer existing dependencies and the standard library.

Do not upgrade dependencies unless required by the task.

---

## API Changes

Before changing a public function, type, or interface, search its callers:

```sh
rg "Name" .
```

If the task does not require a breaking change, preserve compatibility.

Update affected tests and documentation when necessary.

---

## Tests

New functionality should include tests when practical.

Cover relevant:

- normal cases
- empty input
- boundary conditions
- error paths
- resource cleanup
- compatibility behavior

For bug fixes, prefer a regression test that reproduces the bug before the fix.

---

## Comments

Write comments only when they explain **why**, not obvious **what**.

Useful comments document:

- non-obvious design decisions
- ownership or lifetime requirements
- platform/compiler constraints
- complex algorithms
- Zig-specific workarounds

Avoid comments that merely restate the code.

---

## Git Safety

Before editing:

```sh
git status --short
```

After editing:

```sh
git diff --check
git diff
git status --short
```

Never use these unless explicitly requested:

```sh
git reset --hard
git clean -fd
git checkout -- .
git restore .
```

Do not remove or overwrite unrelated uncommitted changes.

---

## Completion Checklist

Before considering a task complete:

1. The change is minimal and focused.
2. The code targets Zig 0.16.0.
3. The project builds successfully.
4. Relevant tests pass.
5. Formatting passes.
6. No unrelated files or changes were introduced.
7. No debug code, temporary files, caches, or build artifacts were added.
8. Public behavior remains compatible unless a breaking change was explicitly requested.
