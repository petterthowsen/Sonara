## Rust Code Style

- Follow standard Rust conventions (`cargo fmt`)
- Encapsulate behavior with structs, impl blocks, and traits; prefer OO-style interfaces over free functions when modeling long-lived engine systems
- Add `///` doc comments to every function, method, and type (private or public) describing intent and important side effects
- Never use allocations, blocking calls, or fallible locks in the audio callback thread
- Use `info!`, `warn!`, `error!` macros for logging (not `println!`)
