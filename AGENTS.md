# Project Agent Instructions

## Core Principles

- Write clean, readable, idiomatic, and maintainable code.
- Prefer simple, focused solutions over unnecessary abstraction or complexity.
- Make the smallest change that correctly resolves the requested problem.
- Preserve existing project conventions and avoid unrelated refactors.
- Do not add incomplete, knowingly buggy, untrusted, or unreviewed code.
- Use stable, modern practices compatible with the project's declared toolchain and dependencies.

## Security and Reliability

- Never hardcode secrets, tokens, credentials, private keys, or sensitive personal data.
- Treat all external input as untrusted; validate it at appropriate trust boundaries.
- Prefer well-maintained, reputable dependencies. Do not introduce a dependency unless it is justified.
- Pin or honor lockfiles where applicable, and do not weaken security checks merely to make builds pass.
- Handle errors explicitly. Do not use `unwrap()` or `expect()` in production paths unless failure is demonstrably impossible and the invariant is documented.
- Avoid unsafe code unless it is necessary, narrowly scoped, documented with a `SAFETY:` justification, and covered by tests.

## Rust

- Follow idiomatic Rust ownership and borrowing patterns; avoid unnecessary allocation and cloning.
- Use `Result` and meaningful error types for fallible operations. Prefer `thiserror` for library error types; use `anyhow` at application boundaries when appropriate.
- Keep public APIs well documented, including relevant errors, panics, safety requirements, and executable examples when useful.
- Use `rustfmt` and Clippy. For a Cargo project, prefer validating with:

  ```sh
  cargo fmt --check
  cargo clippy --all-targets --all-features --locked -- -D warnings
  cargo test --all-features --locked
  ```

  Adjust flags only when they are incompatible with the project's workspace, feature model, or lockfile policy.
- Use the project-local `rust-best-practices` skill in `.agents/skills/rust-best-practices` for Rust implementation, review, refactoring, error handling, performance, testing, and documentation work. Apply its advice judiciously and prioritize compiler, Rust standard-library, and official Rust documentation when guidance conflicts.

## Tools, Skills, and External Services

- Use relevant installed agent skills before performing specialized work. Read their instructions and apply them only when they fit the task.
- Use configured MCP tools when they provide authoritative project, service, or environment context. Do not assume an MCP server exists or that it is authorized for a task.
- Verify externally sourced code, commands, packages, and documentation before relying on them. Prefer official documentation and first-party sources.
- Do not run destructive commands, access unrelated resources, or send project data to external services without a clear task requirement and appropriate authorization.

## Change Management

- Inspect the relevant code and configuration before editing; do not guess project conventions or APIs.
- Update tests, documentation, configuration, and call sites when the requested change requires it.
- Add regression tests for bugs when practical.
- Run the most targeted relevant validation after changes, then broader checks when warranted. Report commands that were run and any failures accurately.
- Do not delete, overwrite, revert, commit, or publish user work unless explicitly requested.
- Keep commits small and coherent when asked to create one; use clear imperative commit messages.

## Review Expectations

- Identify root causes rather than masking symptoms.
- Call out trade-offs, behavior changes, compatibility concerns, and unresolved risks clearly.
- Do not claim that code is correct, secure, tested, or production-ready without evidence from the relevant checks.
