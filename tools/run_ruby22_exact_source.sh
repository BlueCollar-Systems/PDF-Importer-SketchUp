#!/usr/bin/env bash

# Build the exact SketchUp 2017 Ruby parser from the official Ruby 2.2.4
# source archive, then run the repository's fail-closed parse gate. This avoids
# the retired Docker Hub schema-1 ruby:2.2.4 image while preserving the exact
# 2.2.4-p230 parser. Run this script on Linux (directly in CI or inside any
# current Linux build container with curl, tar, gcc, and make).

set -euo pipefail

readonly RUBY_VERSION_SOURCE="2.2.4"
readonly RUBY_RUNTIME_EXPECTED="2.2.4-p230"
readonly RUBY_SOURCE_URL="https://cache.ruby-lang.org/pub/ruby/2.2/ruby-2.2.4.tar.gz"
readonly RUBY_SOURCE_BYTES="16638151"
readonly RUBY_SOURCE_SHA256="b6eff568b48e0fda76e5a36333175df049b204e91217aa32a65153cc0cdcb761"

usage() {
  printf '%s\n' \
    'Usage: bash tools/run_ruby22_exact_source.sh --parse|--smoke' \
    '' \
    '  --parse  Build miniruby and parse every shipped extension Ruby file.' \
    '  --smoke  Build an installed Ruby, run the exact parse gate, parse all' \
    '           extension/test Ruby files, and run the Ruby 2.2 smoke set.'
}

if [[ $# -ne 1 ]] || [[ "$1" != "--parse" && "$1" != "--smoke" ]]; then
  usage >&2
  exit 2
fi
readonly MODE="$1"

for command_name in awk curl dirname env find gcc make mkdir mktemp mv rm \
  sha256sum tar tr wc; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'ERROR: exact Ruby source gate requires %s\n' "$command_name" >&2
    exit 1
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
readonly REPO_ROOT
readonly CACHE_DIR="${BCS_RUBY22_SOURCE_CACHE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bcs-ruby22-source}"
readonly ARCHIVE_PATH="${CACHE_DIR}/ruby-${RUBY_VERSION_SOURCE}.tar.gz"

mkdir -p "$CACHE_DIR"

verify_archive() {
  local archive="$1"
  local actual_bytes actual_sha
  actual_bytes="$(wc -c < "$archive" | tr -d '[:space:]')"
  if [[ "$actual_bytes" != "$RUBY_SOURCE_BYTES" ]]; then
    printf 'ERROR: Ruby source size mismatch: expected %s, got %s\n' \
      "$RUBY_SOURCE_BYTES" "$actual_bytes" >&2
    return 1
  fi
  actual_sha="$(sha256sum "$archive" | awk '{print $1}')"
  if [[ "$actual_sha" != "$RUBY_SOURCE_SHA256" ]]; then
    printf 'ERROR: Ruby source SHA-256 mismatch: expected %s, got %s\n' \
      "$RUBY_SOURCE_SHA256" "$actual_sha" >&2
    return 1
  fi
}

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  readonly DOWNLOAD_PATH="${ARCHIVE_PATH}.download.$$"
  trap 'rm -f "${DOWNLOAD_PATH:-}"' EXIT
  curl --fail --location --silent --show-error \
    --proto '=https' --tlsv1.2 \
    --output "$DOWNLOAD_PATH" "$RUBY_SOURCE_URL"
  verify_archive "$DOWNLOAD_PATH"
  mv "$DOWNLOAD_PATH" "$ARCHIVE_PATH"
  trap - EXIT
fi
verify_archive "$ARCHIVE_PATH"

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bcs-ruby22-build.XXXXXX")"
readonly BUILD_ROOT
cleanup() {
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

tar -xzf "$ARCHIVE_PATH" -C "$BUILD_ROOT" --no-same-owner
readonly SOURCE_DIR="${BUILD_ROOT}/ruby-${RUBY_VERSION_SOURCE}"
readonly INSTALL_DIR="${BUILD_ROOT}/install"
if [[ ! -x "${SOURCE_DIR}/configure" ]]; then
  printf 'ERROR: verified Ruby archive did not extract the expected configure script\n' >&2
  exit 1
fi

cd "$SOURCE_DIR"
# -fcommon is required by modern GCC defaults; it changes linkage only, not
# Ruby parser source. OpenSSL is not needed by the gate and Ruby 2.2 predates
# current OpenSSL APIs.
env CFLAGS='-O2 -fcommon' ./configure \
  --prefix="$INSTALL_DIR" \
  --disable-install-doc \
  --disable-shared \
  --without-gmp \
  --without-openssl

JOBS="${BCS_RUBY22_BUILD_JOBS:-2}"
if [[ "$MODE" == "--parse" ]]; then
  make -j"$JOBS" miniruby
  make .rbconfig.time
  RUBY_EXE="${SOURCE_DIR}/miniruby"
  # miniruby does not install its generated rbconfig.rb; include both the
  # build root and source lib directory while executing the gate driver.
  RUBY_LIBRARY_PATH="${SOURCE_DIR}:${SOURCE_DIR}/lib"
else
  make -j"$JOBS"
  make install-nodoc
  RUBY_EXE="${INSTALL_DIR}/bin/ruby"
  # The official source archive carries Ruby 2.2's matching Minitest library
  # under test/lib; install-nodoc does not install that bundled gem.
  RUBY_LIBRARY_PATH="${SOURCE_DIR}/test/lib"
fi
readonly RUBY_EXE RUBY_LIBRARY_PATH

if [[ ! -x "$RUBY_EXE" ]]; then
  printf 'ERROR: exact Ruby build did not produce %s\n' "$RUBY_EXE" >&2
  exit 1
fi

actual_runtime="$(RUBYLIB="$RUBY_LIBRARY_PATH" "$RUBY_EXE" --disable-gems -e 'STDOUT.write("#{RUBY_VERSION}-p#{RUBY_PATCHLEVEL}")')"
if [[ "$actual_runtime" != "$RUBY_RUNTIME_EXPECTED" ]]; then
  printf 'ERROR: source-built Ruby reported %s; expected %s\n' \
    "$actual_runtime" "$RUBY_RUNTIME_EXPECTED" >&2
  exit 1
fi

cd "$REPO_ROOT"
export RUBYLIB="$RUBY_LIBRARY_PATH"
RUBYLIB="$RUBY_LIBRARY_PATH" "$RUBY_EXE" --disable-gems \
  tools/ruby22_real_parse_gate.rb --ruby "$RUBY_EXE"

if [[ "$MODE" == "--parse" ]]; then
  exit 0
fi

while IFS= read -r -d '' ruby_file; do
  "$RUBY_EXE" --disable-gems -c "$ruby_file"
done < <(find extracted test -type f -name '*.rb' -print0)

# Ensure smoke_test.rb subprocesses also use the exact source-built runtime.
export PATH="${INSTALL_DIR}/bin:${PATH}"
readonly SMOKE_TESTS=(
  test/smoke_test.rb
  test/ruby22_compat_test.rb
  test/import_health_test.rb
  test/compatibility_report_test.rb
  test/corpus_harness_test.rb
  test/arc_fitter_test.rb
  test/unit_parser_test.rb
  test/mesh_text_scaling_test.rb
  test/mesh_text_width_fidelity_test.rb
  test/condensed_text_width_regression_test.rb
  test/all_modes_placement_contract_test.rb
  test/textmode1_invariant_test.rb
  test/geometry_builder_text_fallback_test.rb
  test/cairo_glyph_source_test.rb
)
for test_file in "${SMOKE_TESTS[@]}"; do
  "$RUBY_EXE" --disable-gems "$test_file"
done

printf 'PASS: official-source Ruby %s exact parse and smoke gates completed\n' \
  "$RUBY_RUNTIME_EXPECTED"
