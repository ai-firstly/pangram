# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe Pangram do
  it 'exposes a version' do
    expect(Pangram::VERSION).to eq('0.1.0')
  end

  it 'creates a client through the module convenience API' do
    expect(Pangram.new(api_key: 'test-key')).to be_a(Pangram::Client)
  end
end
