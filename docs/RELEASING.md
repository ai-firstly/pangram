# Release Guide

Publishing a gem is a shared, irreversible action. Complete the checks below,
review the built package, and publish only with explicit maintainer approval.

## 1. Update release metadata

1. Change `Pangram::VERSION` in `lib/pangram/version.rb`.
2. Move the relevant entries in `CHANGELOG.md` from `Unreleased` into a dated
   version section.
3. Confirm README and API reference examples still match the implementation.

The version must follow semantic versioning and must not already exist on
RubyGems.

## 2. Verify the source

```bash
make verify
```

This runs the complete test suite, RuboCop, YARD generation, and gem build.
Do not publish if any command fails.

CI also tests the supported Ruby matrix from 3.1 through 4.0.

## 3. Inspect the package

```bash
gem specification pkg/pangram-VERSION.gem
gem unpack pkg/pangram-VERSION.gem --target /tmp/pangram-gem-review
```

Confirm that:

- the name is `pangram` and the version is correct
- `lib/`, README, license, changelog, and docs are present
- test artifacts, coverage output, and credentials are absent
- runtime dependencies and Ruby requirements are correct

## 4. Test an isolated install

```bash
tmp_dir="$(mktemp -d)"
GEM_HOME="$tmp_dir" GEM_PATH="$tmp_dir" \
  gem install pkg/pangram-VERSION.gem --no-document
GEM_HOME="$tmp_dir" GEM_PATH="$tmp_dir" \
  ruby -e 'require "pangram"; puts Pangram::VERSION'
rm -rf "$tmp_dir"
```

## 5. Commit and tag

After review, commit the version and changelog changes. Create an annotated tag
using the same version:

```bash
git tag -a vVERSION -m "Release vVERSION"
```

Pushing commits or tags requires explicit approval.

## 6. Publish manually

With maintainer approval and valid RubyGems credentials:

```bash
gem push pkg/pangram-VERSION.gem
```

After publishing, install `pangram` from RubyGems in a clean environment and
verify its version and `require "pangram"` entry point.
