# Mirrors .github/workflows/ci.yml
ci:
    bash tests/artifact-name.test.sh
    cargo fmt --check
    cargo clippy --all-targets --all-features -- -D warnings
    cargo test --all-features
    cargo doc --no-deps
    cargo package
