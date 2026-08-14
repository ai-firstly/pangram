# Pangram Ruby SDK

Ruby client for the [Pangram Labs API](https://docs.pangram.com), with support
for AI detection, asynchronous bulk jobs, file uploads, and plagiarism checks.

## Requirements

- Ruby 3.1 or newer
- A Pangram API key

## Installation

Add the gem to your application:

```ruby
gem 'pangram'
```

Then run `bundle install`, or install it directly:

```bash
gem install pangram
```

## Client setup

Set your API key in the environment:

```bash
export PANGRAM_API_KEY='your-api-key'
```

```ruby
require 'pangram'

client = Pangram.new
```

You can also pass the key directly. A constructor argument takes precedence
over `PANGRAM_API_KEY`.

```ruby
client = Pangram.new(api_key: 'your-api-key')
# Equivalent: Pangram::Client.new(api_key: 'your-api-key')
```

All API responses are ordinary Ruby `Hash` and `Array` values. Response keys
remain strings and match Pangram's JSON schema.

## Discover models

Model access depends on the API key and current service availability. Discover
selectors instead of hard-coding a model catalog:

```ruby
models = client.list_models
# => ["default", "pangram-4"]
```

Pass `model: "default"` to track Pangram's default, or pass another selector
returned by `list_models`. Omitting `model` is temporarily supported but emits
a deprecation warning; Pangram plans to require it after September 30, 2026.

## AI detection

`predict` submits an asynchronous task, polls until it succeeds, and returns
the completed result:

```ruby
result = client.predict(
  'Text to analyze',
  model: 'pangram-4',
  timeout: 300,
  poll_interval: 0.5
)

puts result['prediction_short']
puts result['fraction_ai']

result['windows'].each do |window|
  puts "#{window['label']}: #{window['ai_assistance_score']}"
end
```

Request a public dashboard link either directly or with the convenience
method:

```ruby
result = client.predict(
  'Text to analyze',
  model: 'pangram-4',
  public_dashboard_link: true
)

result = client.predict_with_dashboard_link(
  'Text to analyze',
  model: 'pangram-4'
)
```

Polling intervals below 0.1 seconds are clamped to 0.1. `timeout` is a total
deadline covering task submission and polling.

## Bulk jobs

Submit either a plain `text` list or an `items` list with optional customer
IDs. Do not pass both.

```ruby
bulk = client.submit_bulk(
  items: [
    { id: 'row-001', text: 'First text' },
    { id: 'row-002', text: 'Second text' }
  ],
  model: 'pangram-4'
)

bulk_id = bulk['bulk_id']
status = client.wait_for_bulk(bulk_id, timeout: 3600, poll_interval: 1)
results = client.get_bulk_results(bulk_id)

results['items'].each do |item|
  prediction = item['result']
  puts "#{item['id']}: #{prediction['prediction_short']}" if prediction
end

results['failed_items'].each do |item|
  warn "#{item['id']}: #{item['error']}"
end
```

Use the lower-level methods to inspect a job without materializing all result
pages:

```ruby
client.get_bulk_status(bulk_id)
client.get_bulk_items(bulk_id, offset: 0, limit: 100)
client.get_bulk_results_page(bulk_id, offset: 0, limit: 100)
```

`get_bulk_results` requests all pages and stores them in memory. For very large
jobs, process `get_bulk_results_page` one page at a time. The API accepts at
most 1,000 submitted item slots per results page.

## File uploads

File prediction uses Pangram's default model and does not accept `model`.

```ruby
result = client.predict_file(
  'document.pdf',
  public_dashboard_link: true,
  timeout: 300
)

results = client.predict_files(
  ['first.docx', 'second.pdf'],
  public_dashboard_link: true
)
```

The SDK sends one multipart field named `files` for each path and closes every
opened file after the request, including when the request fails.

## Plagiarism detection

```ruby
result = client.check_plagiarism('Text to check')

puts result['plagiarism_detected']
puts result['percent_plagiarized']
```

## Errors

All SDK errors inherit from `Pangram::Error`:

| Error | Meaning |
| --- | --- |
| `Pangram::AuthenticationError` | No API key was configured |
| `Pangram::ValidationError` | A local argument is invalid |
| `Pangram::APIError` | Pangram rejected the request or a task failed |
| `Pangram::InvalidResponseError` | Pangram returned invalid JSON or an unexpected schema |
| `Pangram::NetworkError` | The HTTP connection failed or a request timed out |
| `Pangram::TimeoutError` | An async prediction or bulk job exceeded its total deadline |

```ruby
begin
  client.predict('Text', model: 'default')
rescue Pangram::TimeoutError => e
  warn e.message
rescue Pangram::Error => e
  warn "Pangram request failed: #{e.message}"
end
```

Transient network failures and responses with status 408, 429, 500, 502, 503,
or 504 are retried until the total deadline while polling a prediction or bulk
job and while paginating bulk results. Other API errors are raised immediately
with the HTTP `status` and response `body` attached.

## Deprecated compatibility methods

The current Python SDK still includes these methods, so Ruby provides matching
compatibility helpers:

- `predict_short(text, model:)` forwards to the current prediction flow.
- `batch_predict(texts, model:)` calls the prediction flow sequentially.

Prefer `predict` for one input and `submit_bulk` for many inputs.

## Development

Extended documentation is available in [`docs/`](docs/README.md), including
the [API reference](docs/API_REFERENCE.md), [development guide](docs/DEVELOPMENT.md),
and [release checklist](docs/RELEASING.md).

```bash
mise install
bundle install
make verify
```

The test suite uses WebMock and never needs a live Pangram API key.

## License

[MIT](LICENSE)
