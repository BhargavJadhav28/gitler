#!/usr/bin/env bash
# ==============================================================================
# Gitler - Complete Validation & Build Workflow
# ==============================================================================
# Ensure cargo and rustup are in PATH for non-interactive shells:
 export PATH="$HOME/.cargo/bin:$PATH"

# Exit immediately if any command fails:
set -euo pipefail

echo "=================================================="
echo " [1/5] Checking Code Formatting (cargo fmt)"
echo "=================================================="
cargo fmt --check
echo "✓ Formatting check passed."
echo ""

echo "=================================================="
echo " [2/5] Running Clippy Lints (cargo clippy)"
echo "=================================================="
cargo clippy --all-targets --all-features --locked -- -D warnings
echo "✓ Clippy lints passed."
echo ""

echo "=================================================="
echo " [3/5] Running Test Suite (cargo test)"
echo "=================================================="
cargo test --all-features --locked
echo "✓ All tests passed."
echo ""

echo "=================================================="
echo " [4/5] Building Executable (cargo build)"
echo "=================================================="
cargo build --all-features --locked
echo "✓ Build successful."
echo ""

echo "=================================================="
echo " [5/5] Testing Executable Binary (--help)"
echo "=================================================="
if [ -f "./target/debug/gitler.exe" ]; then
    ./target/debug/gitler.exe --help
elif [ -f "./target/debug/gitler" ]; then
    ./target/debug/gitler --help
fi
echo ""
echo "=================================================="
echo " 🎉 Full build + test + run flow completed successfully!"
echo "=================================================="
