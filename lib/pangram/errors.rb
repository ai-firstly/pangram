# frozen_string_literal: true

# Ruby SDK for Pangram AI detection and plagiarism APIs.
module Pangram
  # Base class for all errors raised by this SDK.
  class Error < StandardError; end

  # Raised when no Pangram API key is configured.
  class AuthenticationError < Error; end

  # Raised when a client method receives an invalid argument.
  class ValidationError < Error; end

  # Raised when Pangram rejects a request or an asynchronous task fails.
  class APIError < Error
    # HTTP status code of the failed response, when available.
    attr_reader :status

    # Raw response body of the failed response, when available.
    attr_reader :body

    def initialize(message, status: nil, body: nil)
      super(message)
      @status = status
      @body = body
    end
  end

  # Raised when Pangram returns invalid JSON or an unexpected response shape.
  class InvalidResponseError < APIError; end

  # Raised when an HTTP request fails at the transport layer.
  class NetworkError < Error; end

  # Raised when asynchronous polling exceeds its total deadline.
  class TimeoutError < Error; end
end
