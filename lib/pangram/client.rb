# frozen_string_literal: true

require 'faraday'
require 'faraday/multipart'
require 'faraday/net_http'
require 'json'
require 'uri'

# Ruby SDK for Pangram AI detection and plagiarism APIs.
module Pangram
  # Client for Pangram text detection, bulk, file upload, and plagiarism APIs.
  class Client
    # Base URL for model discovery, text prediction, and bulk jobs.
    TEXT_API_ENDPOINT = 'https://text.external-api.pangram.com'

    # Base URL for multipart document prediction.
    FILE_UPLOAD_API_ENDPOINT = 'https://file-external.api.pangram.com'

    # Base URL for plagiarism detection.
    PLAGIARISM_API_ENDPOINT = 'https://plagiarism.api.pangram.com'

    # Terminal success stage for asynchronous text prediction.
    ASYNC_SUCCESS_STAGE = 'STAGE_SUCCESS'

    # Terminal failure stage for asynchronous text prediction.
    ASYNC_FAILED_STAGE = 'STAGE_FAILED'

    # Terminal statuses for asynchronous bulk jobs.
    BULK_TERMINAL_STATUSES = %w[succeeded failed partial].freeze

    # Default total prediction deadline in seconds.
    DEFAULT_PREDICT_TIMEOUT = 300

    # Default total bulk polling deadline in seconds.
    DEFAULT_BULK_TIMEOUT = 3600

    # Default delay between asynchronous status requests in seconds.
    DEFAULT_POLL_INTERVAL = 0.5

    # Smallest allowed polling delay and request timeout in seconds.
    MIN_POLL_INTERVAL = 0.1

    # Maximum timeout for ordinary API requests in seconds.
    HTTP_REQUEST_TIMEOUT = 10

    # Timeout for plagiarism requests in seconds.
    PLAGIARISM_TIMEOUT = 90

    # Largest results page accepted by the Bulk API.
    MAX_BULK_PAGE_LIMIT = 1000

    # Transient HTTP statuses worth retrying while polling or paginating.
    RETRYABLE_STATUSES = [408, 429, 500, 502, 503, 504].freeze

    # Warning emitted while omitted model selectors remain backward-compatible.
    MODEL_SELECTION_DEPRECATION_MESSAGE = 'Omitting model is deprecated. Pass model: "default" or another ' \
                                          'identifier returned by list_models. Model will be required after ' \
                                          'September 30, 2026.'

    attr_reader :api_key

    def initialize(api_key: nil)
      @api_key = (api_key.nil? ? ENV.fetch('PANGRAM_API_KEY', nil) : api_key).to_s.strip
      if @api_key.empty?
        raise AuthenticationError, 'API key is required. Set PANGRAM_API_KEY or pass api_key: to Pangram.new.'
      end

      @text_connection = build_connection(TEXT_API_ENDPOINT)
      @file_connection = build_connection(FILE_UPLOAD_API_ENDPOINT, multipart: true)
      @plagiarism_connection = build_connection(PLAGIARISM_API_ENDPOINT)
    end

    # Redacted inspection so the API key never leaks into logs or error reports.
    def inspect
      "#<#{self.class.name} api_key=[FILTERED]>"
    end

    # Return the ordered model selectors available to this API key.
    def list_models
      response = json_request(
        @text_connection,
        :get,
        '/models',
        headers: auth_headers,
        timeout: HTTP_REQUEST_TIMEOUT,
        operation: 'listing models'
      )
      models = response['models'] if response.is_a?(Hash)

      invalid_response!('model catalog', response) unless valid_model_catalog?(models)

      models.dup
    end

    # Submit a text task, poll it to completion, and return the successful API payload.
    def predict(text, model: nil, public_dashboard_link: false, timeout: DEFAULT_PREDICT_TIMEOUT,
                poll_interval: DEFAULT_POLL_INTERVAL)
      predict_with_resolved_model(
        text,
        model: resolve_model(model),
        public_dashboard_link: public_dashboard_link,
        timeout: timeout,
        poll_interval: poll_interval
      )
    end

    # Predict text and request a public Pangram dashboard link.
    def predict_with_dashboard_link(text, model: nil, timeout: DEFAULT_PREDICT_TIMEOUT,
                                    poll_interval: DEFAULT_POLL_INTERVAL)
      predict_with_resolved_model(
        text,
        model: resolve_model(model),
        public_dashboard_link: true,
        timeout: timeout,
        poll_interval: poll_interval
      )
    end

    # Submit a Bulk API job. Provide exactly one of text or items.
    def submit_bulk(text: nil, items: nil, model: nil)
      payload = bulk_payload(text, items)
      normalized_model = resolve_model(model)
      payload[:model] = normalized_model unless normalized_model.nil?

      response = json_request(
        @text_connection,
        :post,
        '/bulk',
        body: payload,
        expected_statuses: [202],
        timeout: HTTP_REQUEST_TIMEOUT,
        operation: 'submitting bulk job'
      )
      ensure_hash_response!(response, 'bulk response')
    end

    # Fetch the status and counters for a Bulk API job.
    def get_bulk_status(bulk_id)
      fetch_bulk_status(bulk_id, HTTP_REQUEST_TIMEOUT)
    end

    # Fetch one page of Bulk API item metadata.
    def get_bulk_items(bulk_id, offset: 0, limit: 100)
      response = json_request(
        @text_connection,
        :get,
        "/bulk/#{escape_path_segment(bulk_id, 'bulk_id')}/items",
        params: { offset: offset, limit: limit },
        timeout: HTTP_REQUEST_TIMEOUT,
        operation: 'fetching bulk items'
      )
      ensure_hash_response!(response, 'bulk items response')
    end

    # Fetch one page of Bulk API results.
    def get_bulk_results_page(bulk_id, offset: 0, limit: 100, timeout: HTTP_REQUEST_TIMEOUT)
      response = json_request(
        @text_connection,
        :get,
        "/bulk/#{escape_path_segment(bulk_id, 'bulk_id')}/results",
        params: { offset: offset, limit: limit },
        timeout: timeout,
        operation: 'fetching bulk results'
      )
      ensure_hash_response!(response, 'bulk results response')
    end

    # Materialize every Bulk API results page in one Hash.
    def get_bulk_results(bulk_id, page_size: MAX_BULK_PAGE_LIMIT, timeout: DEFAULT_BULK_TIMEOUT)
      validate_bulk_results_options!(page_size, timeout)
      deadline = monotonic_time + timeout
      offset = 0
      total_items = nil
      response_bulk_id = bulk_id
      items = []
      failed_items = []

      while total_items.nil? || offset < total_items
        page = fetch_bulk_results_page(bulk_id, offset, page_size, deadline, timeout)
        validate_bulk_results_page!(page)
        # Lock in the first page's counters; later pages only contribute items.
        if total_items.nil?
          total_items = page['total_items']
          response_bulk_id = page['bulk_id']
        end
        items.concat(page['items'])
        failed_items.concat(page['failed_items'])
        offset += page_size
      end

      {
        'bulk_id' => response_bulk_id,
        'total_items' => total_items || 0,
        'items' => items,
        'failed_items' => failed_items
      }
    end

    # Poll a Bulk API job until its status is succeeded, failed, or partial.
    def wait_for_bulk(bulk_id, timeout: DEFAULT_BULK_TIMEOUT, poll_interval: DEFAULT_POLL_INTERVAL)
      validate_polling_options!(timeout, poll_interval)
      deadline = monotonic_time + timeout
      interval = [MIN_POLL_INTERVAL, poll_interval].max
      last_status = nil

      loop do
        raise bulk_timeout_error(bulk_id, timeout, last_status) if monotonic_time >= deadline

        begin
          response = fetch_bulk_status(bulk_id, request_timeout(deadline))
        rescue NetworkError, APIError => e
          raise if e.is_a?(APIError) && !RETRYABLE_STATUSES.include?(e.status)
          raise bulk_timeout_error(bulk_id, timeout, last_status) if monotonic_time >= deadline

          sleep_before_retry(deadline, interval)
          next
        end

        last_status = response['status']
        return response if BULK_TERMINAL_STATUSES.include?(last_status)

        sleep_before_retry(deadline, interval)
      end
    end

    # Upload one file for AI detection and return its result.
    def predict_file(file_path, public_dashboard_link: false, timeout: DEFAULT_PREDICT_TIMEOUT)
      results = predict_files([file_path], public_dashboard_link: public_dashboard_link, timeout: timeout)
      invalid_response!('file upload response', results) if results.empty?

      results.first
    end

    # Upload one or more files for AI detection.
    def predict_files(file_paths, public_dashboard_link: false, timeout: DEFAULT_PREDICT_TIMEOUT)
      validate_file_options!(file_paths, timeout)

      opened_files = open_upload_files(file_paths)
      response = upload_files(opened_files, public_dashboard_link, timeout)
      invalid_response!('file upload response', response) unless valid_file_upload_response?(response)

      response
    ensure
      opened_files&.each(&:close)
    end

    # Check text for potential plagiarism against online sources.
    def check_plagiarism(text)
      response = json_request(
        @plagiarism_connection,
        :post,
        '/',
        body: { text: text, source: "ruby_sdk_#{VERSION}" },
        timeout: PLAGIARISM_TIMEOUT,
        operation: 'checking plagiarism'
      )
      ensure_hash_response!(response, 'plagiarism response')
    end

    # Deprecated compatibility alias for predict.
    def predict_short(text, model: nil)
      deprecate(:predict_short,
                'predict_short is deprecated; use predict instead. This method may be removed after August 1, 2026.')
      predict_with_resolved_model(
        text,
        model: resolve_model(model),
        public_dashboard_link: false,
        timeout: DEFAULT_PREDICT_TIMEOUT,
        poll_interval: DEFAULT_POLL_INTERVAL
      )
    end

    # Deprecated sequential compatibility helper. Prefer submit_bulk.
    def batch_predict(text_batch, model: nil)
      deprecate(:batch_predict,
                'batch_predict is deprecated; use submit_bulk instead. ' \
                'This method may be removed after August 1, 2026.')
      normalized_model = resolve_model(model)
      text_batch.map do |text|
        predict_with_resolved_model(
          text,
          model: normalized_model,
          public_dashboard_link: false,
          timeout: DEFAULT_PREDICT_TIMEOUT,
          poll_interval: DEFAULT_POLL_INTERVAL
        )
      end
    end

    private

    def predict_with_resolved_model(text, model:, public_dashboard_link:, timeout:, poll_interval:)
      validate_polling_options!(timeout, poll_interval)
      deadline = monotonic_time + timeout
      task_id = submit_prediction_task(text, model, public_dashboard_link, deadline)
      poll_prediction_task(task_id, deadline, timeout, [MIN_POLL_INTERVAL, poll_interval].max)
    end

    def submit_prediction_task(text, model, public_dashboard_link, deadline)
      payload = { text: text, public_dashboard_link: public_dashboard_link }
      payload[:model] = model unless model.nil?
      response = json_request(
        @text_connection,
        :post,
        '/task',
        body: payload,
        timeout: request_timeout(deadline),
        operation: 'submitting prediction task'
      )
      invalid_response!('task response', response) unless response.is_a?(Hash)

      task_id = response['task_id']
      invalid_response!('task response (missing task_id)', response) unless task_id.is_a?(String) && !task_id.empty?

      task_id
    end

    def poll_prediction_task(task_id, deadline, timeout, poll_interval)
      loop do
        raise prediction_timeout_error(task_id, timeout) if monotonic_time >= deadline

        response = fetch_prediction_task_with_retry(task_id, deadline, timeout, poll_interval)
        stage = response['stage']
        return response if stage == ASYNC_SUCCESS_STAGE

        raise_failed_task!(task_id, response) if stage == ASYNC_FAILED_STAGE
        invalid_response!("task result (missing stage for task #{task_id})", response) if stage.nil?

        sleep_before_retry(deadline, poll_interval)
      end
    end

    def fetch_prediction_task_with_retry(task_id, deadline, timeout, poll_interval)
      fetch_prediction_task(task_id, deadline)
    rescue NetworkError, APIError => e
      raise if e.is_a?(APIError) && !RETRYABLE_STATUSES.include?(e.status)
      raise prediction_timeout_error(task_id, timeout) if monotonic_time >= deadline

      sleep_before_retry(deadline, poll_interval)
      retry
    end

    def fetch_prediction_task(task_id, deadline)
      response = json_request(
        @text_connection,
        :get,
        "/task/#{escape_path_segment(task_id, 'task_id')}",
        timeout: request_timeout(deadline),
        operation: 'polling prediction task'
      )
      ensure_hash_response!(response, 'task result')
    end

    def fetch_bulk_status(bulk_id, timeout)
      response = json_request(
        @text_connection,
        :get,
        "/bulk/#{escape_path_segment(bulk_id, 'bulk_id')}",
        timeout: timeout,
        operation: 'fetching bulk status'
      )
      ensure_hash_response!(response, 'bulk status response')
    end

    def bulk_payload(text, items)
      raise ValidationError, 'Provide exactly one of text or items' if text.nil? == items.nil?

      key, value = text.nil? ? [:items, items] : [:text, text]
      raise ValidationError, "#{key} must be a non-empty Array" unless value.is_a?(Array) && !value.empty?

      { key => value }
    end

    def validate_bulk_results_options!(page_size, timeout)
      unless page_size.is_a?(Integer) && page_size.between?(1, MAX_BULK_PAGE_LIMIT)
        raise ValidationError, "page_size must be between 1 and #{MAX_BULK_PAGE_LIMIT}"
      end
      return if timeout.respond_to?(:positive?) && timeout.positive?

      raise ValidationError, 'timeout must be greater than 0'
    end

    def fetch_bulk_results_page(bulk_id, offset, page_size, deadline, timeout)
      loop do
        raise bulk_results_timeout_error(bulk_id, timeout) if monotonic_time >= deadline

        begin
          return get_bulk_results_page(bulk_id, offset: offset, limit: page_size, timeout: request_timeout(deadline))
        rescue NetworkError, APIError => e
          raise if e.is_a?(APIError) && !RETRYABLE_STATUSES.include?(e.status)
          raise bulk_results_timeout_error(bulk_id, timeout) if monotonic_time >= deadline

          sleep_before_retry(deadline, DEFAULT_POLL_INTERVAL)
        end
      end
    end

    def upload_files(opened_files, public_dashboard_link, timeout)
      parts = opened_files.map do |file|
        Faraday::Multipart::FilePart.new(file, 'application/octet-stream', File.basename(file.path))
      end
      response = @file_connection.post('/') do |request|
        request.headers.update(auth_headers)
        request.options.timeout = timeout
        request.options.open_timeout = timeout
        request.body = {
          files: parts,
          public_dashboard_link: public_dashboard_link ? 'true' : 'false'
        }
      end
      parse_response_json(response, [200])
    rescue Faraday::Error => e
      raise NetworkError, "Pangram API request failed while uploading files: #{e.message}"
    end

    def open_upload_file(file_path)
      path = file_path.respond_to?(:to_path) ? file_path.to_path : file_path.to_s
      File.open(path, 'rb')
    end

    def open_upload_files(file_paths)
      opened_files = []
      file_paths.reduce(opened_files) do |files, file_path|
        files << open_upload_file(file_path)
      end
    rescue StandardError
      opened_files.each(&:close)
      raise
    end

    def json_request(connection, method, path, timeout:, operation:, body: nil, params: nil, headers: json_headers,
                     expected_statuses: [200])
      response = connection.public_send(method, path) do |request|
        request.headers.update(headers)
        request.params.update(params) unless params.nil?
        request.body = JSON.generate(body) unless body.nil?
        request.options.timeout = timeout
        request.options.open_timeout = timeout
      end
      parse_response_json(response, expected_statuses)
    rescue Faraday::Error => e
      raise NetworkError, "Pangram API request failed while #{operation}: #{e.message}"
    end

    def parse_response_json(response, expected_statuses)
      unless expected_statuses.include?(response.status)
        raise APIError.new("Error returned by API: [#{response.status}] #{response.body}",
                           status: response.status, body: response.body)
      end

      begin
        parsed = JSON.parse(response.body)
      rescue JSON::ParserError
        raise InvalidResponseError, "Error returned by API: non-JSON response: #{response.body}"
      end

      error = parsed['error'] if parsed.is_a?(Hash)
      raise APIError.new("Error returned by API: #{error}", status: response.status, body: response.body) if error

      parsed
    end

    def build_connection(endpoint, multipart: false)
      Faraday.new(url: endpoint) do |connection|
        connection.request :multipart, flat_encode: true if multipart
        connection.request :url_encoded if multipart
        connection.adapter :net_http
      end
    end

    def auth_headers
      { 'x-api-key' => @api_key }
    end

    def json_headers
      auth_headers.merge('Content-Type' => 'application/json')
    end

    def resolve_model(model)
      if model.nil?
        deprecate(:model_selection, MODEL_SELECTION_DEPRECATION_MESSAGE)
        return nil
      end
      raise ValidationError, 'model must be a non-empty string' unless model.is_a?(String) && !model.strip.empty?

      model.strip
    end

    # Emit each deprecation warning at most once per client instance.
    def deprecate(key, message)
      @deprecation_warnings ||= {}
      return if @deprecation_warnings[key]

      warn(message)
      @deprecation_warnings[key] = true
    end

    def valid_model_catalog?(models)
      models.is_a?(Array) && models.all? do |model|
        model.is_a?(String) && !model.empty? && model == model.strip
      end && models.include?('default') && models.uniq.length == models.length
    end

    def validate_polling_options!(timeout, poll_interval)
      unless timeout.respond_to?(:positive?) && timeout.positive?
        raise ValidationError, 'timeout must be greater than 0'
      end
      return if poll_interval.respond_to?(:negative?) && !poll_interval.negative?

      raise ValidationError, 'poll_interval cannot be negative'
    end

    def validate_file_options!(file_paths, timeout)
      unless file_paths.is_a?(Array) && !file_paths.empty?
        raise ValidationError, 'file_paths must contain at least one file'
      end
      return if timeout.respond_to?(:positive?) && timeout.positive?

      raise ValidationError, 'timeout must be greater than 0'
    end

    def valid_file_upload_response?(response)
      response.is_a?(Array) && response.all?(Hash)
    end

    def validate_bulk_results_page!(page)
      valid = page['bulk_id'].is_a?(String) && page['total_items'].is_a?(Integer) &&
              page['total_items'] >= 0 && page['items'].is_a?(Array) && page['failed_items'].is_a?(Array)
      invalid_response!('bulk results page', page) unless valid
    end

    def ensure_hash_response!(response, name)
      invalid_response!(name, response) unless response.is_a?(Hash)

      response
    end

    def invalid_response!(name, response)
      raise InvalidResponseError, "Error returned by API: invalid #{name}: #{response.inspect}"
    end

    def raise_failed_task!(task_id, response)
      message = response['headline'] || response['detail'] || 'task failed'
      raise APIError, "Error returned by API: task #{task_id} failed: #{message}"
    end

    def request_timeout(deadline)
      (deadline - monotonic_time).clamp(MIN_POLL_INTERVAL, HTTP_REQUEST_TIMEOUT)
    end

    def sleep_before_retry(deadline, interval)
      duration = (deadline - monotonic_time).clamp(0, interval)
      sleep(duration) if duration.positive?
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def prediction_timeout_error(task_id, timeout)
      TimeoutError.new("Pangram prediction task #{task_id} did not complete within #{format_timeout(timeout)}s")
    end

    def bulk_timeout_error(bulk_id, timeout, last_status)
      TimeoutError.new(
        "Pangram bulk job #{bulk_id} did not complete within #{format_timeout(timeout)}s; " \
        "last status=#{last_status || 'nil'}"
      )
    end

    def bulk_results_timeout_error(bulk_id, timeout)
      TimeoutError.new(
        "Pangram bulk results for job #{bulk_id} did not finish within #{format_timeout(timeout)}s"
      )
    end

    def format_timeout(timeout)
      format('%.0f', timeout)
    end

    def escape_path_segment(value, name)
      raise ValidationError, "#{name} must be a non-empty string" unless value.is_a?(String) && !value.strip.empty?

      URI.encode_www_form_component(value).gsub('+', '%20')
    end
  end
end
