# Development Guide

## Repository layout

```text
lib/pangram.rb             Public entry point and Pangram.new
lib/pangram/client.rb      API client, polling, pagination, and uploads
lib/pangram/errors.rb      SDK exception hierarchy
lib/pangram/version.rb     Gem version
spec/                      Offline contract tests
docs/                      Extended project documentation
pangram.gemspec            Package metadata and dependencies
```

## Setup

Ruby is managed through [mise](https://mise.jdx.dev/):

```bash
mise trust
mise install
bundle install
```

The gem requires Ruby 3.1 or newer. The lockfile is constrained so all
development dependencies also remain compatible with Ruby 3.1.

## Make targets

Run `make help` to list available commands.

| Command | Purpose |
| --- | --- |
| `make install` | Install Bundler dependencies |
| `make test` or `make spec` | Run all RSpec tests |
| `make coverage` | Run tests and print the coverage report path |
| `make lint` | Run RuboCop |
| `make lint-fix` | Run RuboCop auto-correction |
| `make docs` | Generate YARD documentation under `doc/` |
| `make build` | Build `pkg/pangram-VERSION.gem` |
| `make verify` | Run tests, lint, docs, and build |
| `make console` | Start IRB with `pangram` loaded |
| `make clean` | Remove generated artifacts |

## Testing

```bash
make test
```

The test suite uses WebMock and must not contact Pangram's live services. It
verifies:

- request URLs, headers, JSON payloads, and status codes
- model catalog validation
- prediction and bulk polling, retry, failure, and timeout paths
- bulk result pagination and aggregation
- exact multipart field names and file-handle cleanup
- API, network, validation, and invalid-response errors

SimpleCov writes its report to `coverage/index.html` and enforces at least 90%
line coverage.

## Linting

```bash
make lint
```

RuboCop targets Ruby 3.1. Prefer correcting the implementation over disabling
a cop for a local exception.

## API documentation

Public methods use YARD-compatible comments. Generate HTML documentation with:

```bash
make docs
```

Generated files are written to `doc/` and are excluded from source control.

## Building and inspecting the gem

```bash
make build
gem specification pkg/pangram-0.1.0.gem
gem contents --show-install-dir pangram
```

For an isolated installation smoke test:

```bash
tmp_dir="$(mktemp -d)"
GEM_HOME="$tmp_dir" GEM_PATH="$tmp_dir" \
  gem install pkg/pangram-0.1.0.gem --no-document
GEM_HOME="$tmp_dir" GEM_PATH="$tmp_dir" \
  ruby -e 'require "pangram"; puts Pangram::VERSION'
rm -rf "$tmp_dir"
```

Use the current value from `lib/pangram/version.rb` instead of `0.1.0` when
building a later release.

## Adding or changing an API method

1. Confirm the current REST contract in the official Pangram documentation.
2. Keep HTTP ownership in `Pangram::Client` and reuse existing request helpers.
3. Preserve response field names and string keys.
4. Add WebMock coverage for the request and relevant failure paths.
5. Update `docs/API_REFERENCE.md`, the project README when user-facing, and
   `CHANGELOG.md`.
6. Run `make verify`.
