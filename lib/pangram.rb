# frozen_string_literal: true

require_relative 'pangram/version'
require_relative 'pangram/errors'
require_relative 'pangram/client'

# Ruby SDK for Pangram AI detection and plagiarism APIs.
module Pangram
  class << self
    # Create an isolated Pangram API client.
    def new(**kwargs)
      Client.new(**kwargs)
    end
  end
end
