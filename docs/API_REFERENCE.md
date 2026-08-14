# API Reference

The public API is exposed through `Pangram::Client`. `Pangram.new` is a
convenience constructor for the same client.

```ruby
require 'pangram'

client = Pangram.new(api_key: ENV.fetch('PANGRAM_API_KEY'))
# Equivalent to Pangram::Client.new(...)
```

All successful API responses remain ordinary Ruby `Hash` and `Array` values.
Hash keys are strings and match Pangram's JSON response fields.

## Authentication

```ruby
Pangram.new(api_key: 'your-api-key')
```

When `api_key:` is omitted, the client reads `PANGRAM_API_KEY`. An explicit
argument takes precedence over the environment. If neither is available,
construction raises `Pangram::AuthenticationError`.

Every request sends the key through the `x-api-key` header.

## Model discovery

### `list_models`

```ruby
models = client.list_models
# => ["default", "pangram-4"]
```

Returns the server-ordered selectors available to the current API key. The
catalog is entitlement- and availability-aware, so callers should not
hard-code it.

The client validates that the response contains unique, non-blank model names
and the `default` selector.

## Text prediction

### `predict`

```ruby
result = client.predict(
  text,
  model: 'pangram-4',
  public_dashboard_link: false,
  timeout: 300,
  poll_interval: 0.5
)
```

Submits `POST /task`, polls `GET /task/{task_id}`, and returns when the task
reaches `STAGE_SUCCESS`.

| Keyword | Default | Description |
| --- | --- | --- |
| `model` | `nil` | Selector returned by `list_models` |
| `public_dashboard_link` | `false` | Request a public result link |
| `timeout` | `300` | Total deadline for submission and polling, in seconds |
| `poll_interval` | `0.5` | Delay between polls, clamped to at least 0.1 seconds |

Omitting `model` currently preserves Pangram's legacy wire payload and emits a
deprecation warning. New integrations should pass `model: "default"` or
another selector returned by `list_models`.

A successful result can include:

- `stage`, `text`, `version`, `headline`, `prediction`, and `prediction_short`
- `fraction_ai`, `fraction_ai_assisted`, and `fraction_human`
- segment counters and `dashboard_link` when requested
- `windows`, including labels, scores, confidence, character offsets, word and
  token counts, and Pangram 4 humanizer fields

The SDK returns the server payload without renaming or symbolizing fields.

### `predict_with_dashboard_link`

```ruby
result = client.predict_with_dashboard_link(
  text,
  model: 'pangram-4',
  timeout: 300,
  poll_interval: 0.5
)
```

Equivalent to `predict(..., public_dashboard_link: true)`.

## Bulk jobs

### `submit_bulk`

Submit exactly one payload shape:

```ruby
client.submit_bulk(text: ['first', 'second'], model: 'pangram-4')

client.submit_bulk(
  items: [
    { id: 'row-1', text: 'first' },
    { id: 'row-2', text: 'second' }
  ],
  model: 'pangram-4'
)
```

Returns the accepted `202` response, including `bulk_id`, initial status,
accepted items, and immediate validation failures.

One model applies to the whole bulk job. Per-item model selectors are not
supported.

### `get_bulk_status`

```ruby
status = client.get_bulk_status(bulk_id)
```

Returns job status, counters, and creation/completion timestamps. Terminal
statuses are `succeeded`, `failed`, and `partial`.

### `wait_for_bulk`

```ruby
status = client.wait_for_bulk(
  bulk_id,
  timeout: 3600,
  poll_interval: 0.5
)
```

Polls until the job reaches a terminal status. Transient network failures are
retried within the total deadline.

### `get_bulk_items`

```ruby
page = client.get_bulk_items(bulk_id, offset: 0, limit: 100)
```

Returns one page of item metadata.

### `get_bulk_results_page`

```ruby
page = client.get_bulk_results_page(bulk_id, offset: 0, limit: 100)
```

Returns one submitted-item page with successful or in-progress items in
`items` and failures in `failed_items`.

### `get_bulk_results`

```ruby
results = client.get_bulk_results(bulk_id, page_size: 1000, timeout: 3600)
```

Fetches every results page and returns a single aggregate containing
`bulk_id`, `total_items`, `items`, and `failed_items`. `page_size` must be from
1 through 1,000. `timeout` is the total deadline in seconds for fetching all
pages; transient failures are retried until that deadline. The aggregate's
`total_items` is locked to the first page so in-progress jobs cannot truncate
the result mid-pagination.

This method materializes all pages in memory. Process
`get_bulk_results_page` incrementally for very large jobs.

## File prediction

File prediction uses Pangram's default model and does not accept `model:`.

### `predict_file`

```ruby
result = client.predict_file(
  'document.pdf',
  public_dashboard_link: true,
  timeout: 300
)
```

Uploads one file and returns its result.

### `predict_files`

```ruby
results = client.predict_files(
  ['first.docx', 'second.pdf'],
  public_dashboard_link: true,
  timeout: 300
)
```

Uploads multiple files in one multipart request. Each path is sent as a
repeated form field named `files`, not `files[]`. Every file handle is closed
after success or failure, including partial file-open failures.

## Plagiarism detection

### `check_plagiarism`

```ruby
result = client.check_plagiarism('Text to check')
```

Returns Pangram's plagiarism response, including detection status, matched
content, sentence counts, and plagiarism percentage.

## Deprecated compatibility methods

The following methods mirror compatibility behavior still present in the
Python SDK:

- `predict_short(text, model:)` uses the current prediction flow.
- `batch_predict(texts, model:)` predicts each input sequentially.

Use `predict` for one input and `submit_bulk` for many inputs.

## Errors

All SDK-defined exceptions inherit from `Pangram::Error`.

| Exception | Raised when |
| --- | --- |
| `Pangram::AuthenticationError` | No API key is configured |
| `Pangram::ValidationError` | A local argument is invalid |
| `Pangram::APIError` | Pangram rejects a request or an async task fails |
| `Pangram::InvalidResponseError` | A response is not valid JSON or has an invalid top-level contract |
| `Pangram::NetworkError` | An HTTP request fails at the transport layer |
| `Pangram::TimeoutError` | Prediction or bulk polling exceeds its total deadline |

```ruby
begin
  client.predict(text, model: 'default')
rescue Pangram::TimeoutError => e
  warn e.message
rescue Pangram::Error => e
  warn "Pangram failed: #{e.message}"
end
```

API errors carry the HTTP `status` and raw response `body` when they come from
a rejected response. `Pangram::InvalidResponseError` is a subclass of
`Pangram::APIError`, so rescuing `APIError` also catches schema violations.

Transport errors and responses with status 408, 429, 500, 502, 503, or 504 are
retried until the total deadline during prediction polling, bulk polling, and
bulk results pagination. Other API errors are not retried.
