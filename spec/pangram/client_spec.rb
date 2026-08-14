# frozen_string_literal: true

require 'tempfile'
require_relative '../spec_helper'

RSpec.describe Pangram::Client do
  subject(:client) { described_class.new(api_key: 'test-key') }

  let(:text_endpoint) { described_class::TEXT_API_ENDPOINT }
  let(:file_endpoint) { described_class::FILE_UPLOAD_API_ENDPOINT }
  let(:plagiarism_endpoint) { described_class::PLAGIARISM_API_ENDPOINT }
  let(:success_result) do
    {
      'stage' => 'STAGE_SUCCESS',
      'text' => 'Hello',
      'version' => '4.0',
      'prediction_short' => 'Human',
      'windows' => []
    }
  end

  def json_response(body, status: 200)
    { status: status, headers: { 'Content-Type' => 'application/json' }, body: JSON.generate(body) }
  end

  def stub_successful_prediction(task_id: 'task-1', result: success_result)
    stub_request(:post, "#{text_endpoint}/task")
      .to_return(json_response({ 'task_id' => task_id }))
    stub_request(:get, "#{text_endpoint}/task/#{task_id}")
      .to_return(json_response(result))
  end

  describe '#initialize' do
    it 'uses an explicit API key' do
      expect(client.api_key).to eq('test-key')
    end

    it 'uses PANGRAM_API_KEY when no argument is passed' do
      stub_const('ENV', ENV.to_h.merge('PANGRAM_API_KEY' => 'environment-key'))

      expect(described_class.new.api_key).to eq('environment-key')
    end

    it 'raises without an API key' do
      stub_const('ENV', ENV.to_h.tap { |env| env.delete('PANGRAM_API_KEY') })

      expect { described_class.new }.to raise_error(Pangram::AuthenticationError, /API key is required/)
    end

    it 'raises for blank API keys' do
      expect { described_class.new(api_key: '') }.to raise_error(Pangram::AuthenticationError, /API key is required/)
      expect { described_class.new(api_key: '   ') }.to raise_error(Pangram::AuthenticationError, /API key is required/)
    end

    it 'raises for a set-but-empty PANGRAM_API_KEY' do
      stub_const('ENV', ENV.to_h.merge('PANGRAM_API_KEY' => ''))

      expect { described_class.new }.to raise_error(Pangram::AuthenticationError, /API key is required/)
    end

    it 'coerces non-string keys and strips whitespace' do
      expect(described_class.new(api_key: :'symbol-key').api_key).to eq('symbol-key')
      expect(described_class.new(api_key: '  padded-key  ').api_key).to eq('padded-key')
    end
  end

  describe '#inspect' do
    it 'redacts the API key' do
      expect(client.inspect).to include('[FILTERED]')
      expect(client.inspect).not_to include('test-key')
    end
  end

  describe '#list_models' do
    it 'returns the server catalog in order with auth-only headers' do
      request = stub_request(:get, "#{text_endpoint}/models")
                .with(headers: { 'x-api-key' => 'test-key' })
                .to_return(json_response({ 'models' => %w[default pangram-4 future-model] }))

      expect(client.list_models).to eq(%w[default pangram-4 future-model])
      expect(request).to have_been_requested.once
    end

    it 'rejects malformed catalogs' do
      stub_request(:get, "#{text_endpoint}/models")
        .to_return(json_response({ 'models' => %w[pangram-4 pangram-4] }))

      expect { client.list_models }.to raise_error(Pangram::InvalidResponseError, /invalid model catalog/)
    end
  end

  describe '#predict' do
    it 'submits an explicit model and polls through an intermediate stage' do
      submission = stub_request(:post, "#{text_endpoint}/task")
                   .with do |request|
        JSON.parse(request.body) == {
          'text' => 'Hello',
          'model' => 'pangram-4',
          'public_dashboard_link' => false
        }
      end.to_return(json_response({ 'task_id' => 'task-1' }))
      poll = stub_request(:get, "#{text_endpoint}/task/task-1")
             .to_return(
               json_response({ 'task_id' => 'task-1', 'stage' => 'STAGE_PREPROCESSING' }),
               json_response(success_result)
             )
      allow(client).to receive(:sleep)

      expect(client.predict('Hello', model: '  pangram-4  ', poll_interval: 0)).to eq(success_result)
      expect(submission).to have_been_requested.once
      expect(poll).to have_been_requested.twice
      expect(client).to have_received(:sleep).with(0.1).once
    end

    it 'warns and preserves the legacy wire payload when model is omitted' do
      stub_successful_prediction
      request = stub_request(:post, "#{text_endpoint}/task").with do |submitted|
        !JSON.parse(submitted.body).key?('model')
      end.to_return(json_response({ 'task_id' => 'task-1' }))

      expect { client.predict('Hello') }.to output(/Omitting model is deprecated/).to_stderr
      expect(request).to have_been_requested.once
    end

    it 'rejects invalid model and polling options before an HTTP request' do
      expect { client.predict('Hello', model: ' ') }
        .to raise_error(Pangram::ValidationError, 'model must be a non-empty string')
      expect { client.predict('Hello', model: 'default', timeout: 0) }
        .to raise_error(Pangram::ValidationError, 'timeout must be greater than 0')
      expect { client.predict('Hello', model: 'default', poll_interval: -1) }
        .to raise_error(Pangram::ValidationError, 'poll_interval cannot be negative')
    end

    it 'raises when task submission has no task_id' do
      stub_request(:post, "#{text_endpoint}/task").to_return(json_response({}))

      expect { client.predict('Hello', model: 'default') }
        .to raise_error(Pangram::InvalidResponseError, /missing task_id/)
    end

    it 'raises an API error when the async task fails' do
      stub_request(:post, "#{text_endpoint}/task")
        .to_return(json_response({ 'task_id' => 'task-1' }))
      stub_request(:get, "#{text_endpoint}/task/task-1")
        .to_return(json_response({ 'stage' => 'STAGE_FAILED', 'headline' => 'invalid input' }))

      expect { client.predict('Hello', model: 'default') }
        .to raise_error(Pangram::APIError, /task task-1 failed: invalid input/)
    end

    it 'rejects task results without a stage' do
      stub_request(:post, "#{text_endpoint}/task")
        .to_return(json_response({ 'task_id' => 'task-1' }))
      stub_request(:get, "#{text_endpoint}/task/task-1")
        .to_return(json_response({ 'task_id' => 'task-1' }))

      expect { client.predict('Hello', model: 'default') }
        .to raise_error(Pangram::InvalidResponseError, /missing stage/)
    end

    it 'retries a transient network failure while polling' do
      stub_request(:post, "#{text_endpoint}/task")
        .to_return(json_response({ 'task_id' => 'task-1' }))
      stub_request(:get, "#{text_endpoint}/task/task-1")
        .to_timeout.then.to_return(json_response(success_result))
      allow(client).to receive(:sleep)

      expect(client.predict('Hello', model: 'default')).to eq(success_result)
      expect(client).to have_received(:sleep).once
    end

    it 'retries transient HTTP statuses while polling' do
      stub_request(:post, "#{text_endpoint}/task")
        .to_return(json_response({ 'task_id' => 'task-1' }))
      stub_request(:get, "#{text_endpoint}/task/task-1")
        .to_return({ status: 429, body: 'rate limited' }, { status: 503, body: 'unavailable' })
        .then.to_return(json_response(success_result))
      allow(client).to receive(:sleep)

      expect(client.predict('Hello', model: 'default')).to eq(success_result)
      expect(client).to have_received(:sleep).twice
    end

    it 'does not retry non-transient HTTP statuses while polling' do
      stub_request(:post, "#{text_endpoint}/task")
        .to_return(json_response({ 'task_id' => 'task-1' }))
      stub_request(:get, "#{text_endpoint}/task/task-1")
        .to_return(status: 400, body: 'bad request')

      expect { client.predict('Hello', model: 'default') }.to raise_error(Pangram::APIError) do |error|
        expect(error.status).to eq(400)
      end
    end

    it 'warns about the omitted model only once per client' do
      stub_successful_prediction
      allow(client).to receive(:warn)

      2.times { client.predict('Hello') }

      expect(client).to have_received(:warn).once
    end

    it 'wraps submission transport failures' do
      stub_request(:post, "#{text_endpoint}/task").to_timeout

      expect { client.predict('Hello', model: 'default') }
        .to raise_error(Pangram::NetworkError, /submitting prediction task/)
    end

    it 'raises Pangram::TimeoutError when the total deadline expires' do
      stub_request(:post, "#{text_endpoint}/task")
        .to_return(json_response({ 'task_id' => 'task-1' }))
      allow(client).to receive(:monotonic_time).and_return(0.0, 0.0, 1.0)

      expect { client.predict('Hello', model: 'default', timeout: 1) }
        .to raise_error(Pangram::TimeoutError, /task task-1 did not complete within 1s/)
    end
  end

  describe '#predict_with_dashboard_link' do
    it 'sets public_dashboard_link in the request' do
      request = stub_request(:post, "#{text_endpoint}/task").with do |submitted|
        JSON.parse(submitted.body)['public_dashboard_link'] == true
      end.to_return(json_response({ 'task_id' => 'task-1' }))
      stub_request(:get, "#{text_endpoint}/task/task-1").to_return(json_response(success_result))

      expect(client.predict_with_dashboard_link('Hello', model: 'default')).to eq(success_result)
      expect(request).to have_been_requested.once
    end
  end

  describe 'bulk jobs' do
    it 'submits text and items payloads with HTTP 202' do
      text_request = stub_request(:post, "#{text_endpoint}/bulk").with do |request|
        JSON.parse(request.body) == { 'text' => %w[one two], 'model' => 'pangram-4' }
      end.to_return(json_response({ 'bulk_id' => 'bulk-1', 'status' => 'queued' }, status: 202))

      expect(client.submit_bulk(text: %w[one two], model: 'pangram-4')['bulk_id']).to eq('bulk-1')
      expect(text_request).to have_been_requested.once

      item_request = stub_request(:post, "#{text_endpoint}/bulk").with do |request|
        JSON.parse(request.body) == { 'items' => [{ 'id' => '1', 'text' => 'one' }], 'model' => 'default' }
      end.to_return(json_response({ 'bulk_id' => 'bulk-2' }, status: 202))

      expect(client.submit_bulk(items: [{ id: '1', text: 'one' }], model: 'default')['bulk_id']).to eq('bulk-2')
      expect(item_request).to have_been_requested.once
    end

    it 'requires exactly one bulk payload shape' do
      expect { client.submit_bulk(model: 'default') }
        .to raise_error(Pangram::ValidationError, 'Provide exactly one of text or items')
      expect { client.submit_bulk(text: [], items: [], model: 'default') }
        .to raise_error(Pangram::ValidationError, 'Provide exactly one of text or items')
    end

    it 'rejects non-Array or empty bulk payloads' do
      expect { client.submit_bulk(text: 'hello', model: 'default') }
        .to raise_error(Pangram::ValidationError, 'text must be a non-empty Array')
      expect { client.submit_bulk(text: [], model: 'default') }
        .to raise_error(Pangram::ValidationError, 'text must be a non-empty Array')
      expect { client.submit_bulk(items: [], model: 'default') }
        .to raise_error(Pangram::ValidationError, 'items must be a non-empty Array')
    end

    it 'rejects blank bulk identifiers before building URLs' do
      expect { client.get_bulk_status(nil) }
        .to raise_error(Pangram::ValidationError, 'bulk_id must be a non-empty string')
      expect { client.get_bulk_status(' ') }
        .to raise_error(Pangram::ValidationError, 'bulk_id must be a non-empty string')
      expect { client.get_bulk_items(nil) }
        .to raise_error(Pangram::ValidationError, 'bulk_id must be a non-empty string')
      expect { client.get_bulk_results_page(nil) }
        .to raise_error(Pangram::ValidationError, 'bulk_id must be a non-empty string')
      expect { client.wait_for_bulk(nil) }
        .to raise_error(Pangram::ValidationError, 'bulk_id must be a non-empty string')
    end

    it 'fetches status, item metadata, and a result page' do
      status = { 'bulk_id' => 'bulk/1', 'status' => 'running' }
      items = { 'bulk_id' => 'bulk/1', 'items' => [] }
      page = { 'bulk_id' => 'bulk/1', 'total_items' => 0, 'items' => [], 'failed_items' => [] }
      stub_request(:get, "#{text_endpoint}/bulk/bulk%2F1").to_return(json_response(status))
      item_request = stub_request(:get, "#{text_endpoint}/bulk/bulk%2F1/items?limit=50&offset=10")
                     .to_return(json_response(items))
      page_request = stub_request(:get, "#{text_endpoint}/bulk/bulk%2F1/results?limit=25&offset=5")
                     .to_return(json_response(page))

      expect(client.get_bulk_status('bulk/1')).to eq(status)
      expect(client.get_bulk_items('bulk/1', offset: 10, limit: 50)).to eq(items)
      expect(client.get_bulk_results_page('bulk/1', offset: 5, limit: 25)).to eq(page)
      expect(item_request).to have_been_requested.once
      expect(page_request).to have_been_requested.once
    end

    it 'aggregates every result page' do
      first_page = {
        'bulk_id' => 'bulk-1', 'total_items' => 3,
        'items' => [{ 'index' => 0 }], 'failed_items' => [{ 'index' => 1 }]
      }
      second_page = {
        'bulk_id' => 'bulk-1', 'total_items' => 3,
        'items' => [{ 'index' => 2 }], 'failed_items' => []
      }
      stub_request(:get, "#{text_endpoint}/bulk/bulk-1/results?limit=2&offset=0")
        .to_return(json_response(first_page))
      stub_request(:get, "#{text_endpoint}/bulk/bulk-1/results?limit=2&offset=2")
        .to_return(json_response(second_page))

      expect(client.get_bulk_results('bulk-1', page_size: 2)).to eq(
        'bulk_id' => 'bulk-1',
        'total_items' => 3,
        'items' => [{ 'index' => 0 }, { 'index' => 2 }],
        'failed_items' => [{ 'index' => 1 }]
      )
    end

    it 'retries transient failures while aggregating and locks the first page totals' do
      first_page = {
        'bulk_id' => 'bulk-1', 'total_items' => 2,
        'items' => [{ 'index' => 0 }], 'failed_items' => []
      }
      second_page = {
        'bulk_id' => 'bulk-1', 'total_items' => 99,
        'items' => [{ 'index' => 1 }], 'failed_items' => []
      }
      stub_request(:get, "#{text_endpoint}/bulk/bulk-1/results?limit=1&offset=0")
        .to_timeout
        .then.to_return({ status: 429, body: 'rate limited' })
        .then.to_return(json_response(first_page))
      stub_request(:get, "#{text_endpoint}/bulk/bulk-1/results?limit=1&offset=1")
        .to_return(json_response(second_page))
      allow(client).to receive(:sleep)

      result = client.get_bulk_results('bulk-1', page_size: 1)

      expect(result['total_items']).to eq(2)
      expect(result['items']).to eq([{ 'index' => 0 }, { 'index' => 1 }])
      expect(client).to have_received(:sleep).twice
    end

    it 'does not retry non-transient statuses while aggregating results' do
      stub_request(:get, "#{text_endpoint}/bulk/bulk-1/results?limit=10&offset=0")
        .to_return(status: 400, body: 'bad request')

      expect { client.get_bulk_results('bulk-1', page_size: 10) }.to raise_error(Pangram::APIError) do |error|
        expect(error.status).to eq(400)
      end
    end

    it 'validates result aggregation arguments and page contracts' do
      expect { client.get_bulk_results('bulk-1', page_size: 0) }
        .to raise_error(Pangram::ValidationError, /page_size must be between/)
      expect { client.get_bulk_results('bulk-1', timeout: 0) }
        .to raise_error(Pangram::ValidationError, 'timeout must be greater than 0')

      stub_request(:get, "#{text_endpoint}/bulk/bulk-1/results?limit=10&offset=0")
        .to_return(json_response({ 'bulk_id' => 'bulk-1' }))

      expect { client.get_bulk_results('bulk-1', page_size: 10) }
        .to raise_error(Pangram::InvalidResponseError, /invalid bulk results page/)
    end

    it 'waits through non-terminal statuses and transient network failures' do
      stub_request(:get, "#{text_endpoint}/bulk/bulk-1")
        .to_timeout
        .then.to_return(json_response({ 'bulk_id' => 'bulk-1', 'status' => 'running' }))
        .then.to_return(json_response({ 'bulk_id' => 'bulk-1', 'status' => 'partial' }))
      allow(client).to receive(:sleep)

      result = client.wait_for_bulk('bulk-1', poll_interval: 0)

      expect(result['status']).to eq('partial')
      expect(client).to have_received(:sleep).twice
    end

    it 'retries transient HTTP statuses while waiting' do
      stub_request(:get, "#{text_endpoint}/bulk/bulk-1")
        .to_return(status: 429, body: 'rate limited')
        .then.to_return(json_response({ 'bulk_id' => 'bulk-1', 'status' => 'succeeded' }))
      allow(client).to receive(:sleep)

      result = client.wait_for_bulk('bulk-1', poll_interval: 0)

      expect(result['status']).to eq('succeeded')
      expect(client).to have_received(:sleep).once
    end

    it 'does not retry non-transient HTTP statuses while waiting' do
      stub_request(:get, "#{text_endpoint}/bulk/bulk-1")
        .to_return(status: 404, body: 'unknown job')

      expect { client.wait_for_bulk('bulk-1') }.to raise_error(Pangram::APIError) do |error|
        expect(error.status).to eq(404)
      end
    end

    it 'times out with the last known bulk status' do
      stub_request(:get, "#{text_endpoint}/bulk/bulk-1")
        .to_return(json_response({ 'status' => 'running' }))
      allow(client).to receive(:monotonic_time).and_return(0.0, 0.0, 0.0, 0.0, 1.0)
      allow(client).to receive(:sleep)

      expect { client.wait_for_bulk('bulk-1', timeout: 1) }
        .to raise_error(Pangram::TimeoutError, /last status=running/)
    end
  end

  describe 'file prediction' do
    it 'uploads repeated flat files fields and returns the first single-file result' do
      first = Tempfile.new(['first', '.txt'])
      second = Tempfile.new(['second', '.txt'])
      first.write('first body')
      second.write('second body')
      first.close
      second.close
      captured_request = nil
      request = stub_request(:post, "#{file_endpoint}/").with do |submitted|
        captured_request = submitted
        true
      end.to_return(
        json_response([{ 'filename' => File.basename(first.path) }, { 'filename' => File.basename(second.path) }])
      )

      results = client.predict_files([first.path, second.path], public_dashboard_link: true)

      expect(results.length).to eq(2)
      expect(captured_request.body.scan('name="files"').length).to eq(2)
      expect(captured_request.body).not_to include('name="files[]"')
      expect(captured_request.body).to include('name="public_dashboard_link"', 'true')
      expect(request).to have_been_requested.once

      stub_request(:post, "#{file_endpoint}/")
        .to_return(json_response([{ 'filename' => File.basename(first.path) }]))
      expect(client.predict_file(first.path)['filename']).to eq(File.basename(first.path))
    ensure
      first&.unlink
      second&.unlink
    end

    it 'validates file arguments and response shape' do
      expect { client.predict_files([]) }
        .to raise_error(Pangram::ValidationError, /at least one file/)
      expect { client.predict_files('a.pdf') }
        .to raise_error(Pangram::ValidationError, /at least one file/)
      expect { client.predict_files(['missing'], timeout: 0) }
        .to raise_error(Pangram::ValidationError, /timeout must be greater than 0/)

      file = Tempfile.new('invalid-response')
      file.close
      stub_request(:post, "#{file_endpoint}/").to_return(json_response({ 'not' => 'an array' }))

      expect { client.predict_files([file.path]) }
        .to raise_error(Pangram::InvalidResponseError, /invalid file upload response/)
    ensure
      file&.unlink
    end

    it 'closes files already opened when a later file cannot be opened' do
      opened_file = instance_double(File, close: nil)
      call_count = 0
      allow(client).to receive(:open_upload_file) do
        call_count += 1
        raise Errno::ENOENT if call_count == 2

        opened_file
      end

      expect { client.predict_files(%w[first second]) }.to raise_error(Errno::ENOENT)
      expect(opened_file).to have_received(:close).once
    end
  end

  describe '#check_plagiarism' do
    it 'includes a Ruby SDK source identifier' do
      result = { 'plagiarism_detected' => false, 'percent_plagiarized' => 0.0 }
      request = stub_request(:post, "#{plagiarism_endpoint}/").with do |submitted|
        JSON.parse(submitted.body) == { 'text' => 'Hello', 'source' => 'ruby_sdk_0.1.0' }
      end.to_return(json_response(result))

      expect(client.check_plagiarism('Hello')).to eq(result)
      expect(request).to have_been_requested.once
    end
  end

  describe 'HTTP error handling' do
    it 'raises APIError for unexpected status codes and API error payloads' do
      stub_request(:get, "#{text_endpoint}/models").to_return(status: 401, body: 'unauthorized')
      expect { client.list_models }.to raise_error(Pangram::APIError, /\[401\] unauthorized/)

      stub_request(:get, "#{text_endpoint}/models")
        .to_return(json_response({ 'error' => 'insufficient credits' }))
      expect { client.list_models }.to raise_error(Pangram::APIError, /insufficient credits/)
    end

    it 'exposes the status and body on APIError' do
      stub_request(:get, "#{text_endpoint}/models").to_return(status: 401, body: 'unauthorized')

      expect { client.list_models }.to raise_error(Pangram::APIError) do |error|
        expect(error.status).to eq(401)
        expect(error.body).to eq('unauthorized')
      end
    end

    it 'treats a null error field as a successful response' do
      stub_request(:get, "#{text_endpoint}/models")
        .to_return(json_response({ 'models' => %w[default], 'error' => nil }))

      expect(client.list_models).to eq(%w[default])
    end

    it 'raises InvalidResponseError for non-JSON responses' do
      stub_request(:get, "#{text_endpoint}/models").to_return(status: 200, body: '<html>bad gateway</html>')

      expect { client.list_models }.to raise_error(Pangram::InvalidResponseError, /non-JSON response/)
    end

    it 'makes InvalidResponseError a subclass of APIError' do
      expect(Pangram::InvalidResponseError.superclass).to eq(Pangram::APIError)
    end
  end

  describe 'deprecated compatibility methods' do
    it 'runs predict_short through the current prediction flow' do
      stub_successful_prediction

      expect { expect(client.predict_short('Hello', model: 'default')).to eq(success_result) }
        .to output(/predict_short is deprecated/).to_stderr
    end

    it 'runs batch_predict sequentially' do
      allow(client).to receive(:predict_with_resolved_model).and_return({ 'id' => 1 }, { 'id' => 2 })

      expect { expect(client.batch_predict(%w[one two], model: 'default')).to eq([{ 'id' => 1 }, { 'id' => 2 }]) }
        .to output(/batch_predict is deprecated/).to_stderr
      expect(client).to have_received(:predict_with_resolved_model).twice
    end
  end
end
