# frozen_string_literal: true

require_relative 'lib/pangram/version'

Gem::Specification.new do |spec|
  spec.name = 'pangram'
  spec.version = Pangram::VERSION
  spec.authors = ['Richard Sun']
  spec.email = ['richard.sun@ai-firstly.com']

  spec.summary = 'Ruby SDK for the Pangram AI detection API'
  spec.description = 'A Ruby client for Pangram AI detection, bulk jobs, file uploads, and plagiarism detection.'
  spec.homepage = 'https://docs.pangram.com'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1.0'

  spec.metadata['allowed_push_host'] = 'https://rubygems.org'
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/ai-firstly/pangram'
  spec.metadata['changelog_uri'] = 'https://github.com/ai-firstly/pangram/blob/master/CHANGELOG.md'
  spec.metadata['documentation_uri'] = 'https://rubydoc.info/gems/pangram'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/ai-firstly/pangram/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.chdir(__dir__) do
    if File.directory?('.git')
      `git ls-files -z`.split("\x0").reject { |file| file.match?(%r{\A(?:spec|test|features)/}) }
    else
      Dir.glob('**/*', File::FNM_DOTMATCH).reject do |file|
        File.directory?(file) || file == '.rspec_status' ||
          file.match?(%r{\A(?:\.git|spec|test|features|pkg|coverage|tmp|vendor)/}) || file.end_with?('.gem')
      end
    end
  end
  spec.require_paths = ['lib']

  spec.add_dependency 'faraday', '>= 1.8', '< 3.0'
  spec.add_dependency 'faraday-multipart', '~> 1.0'
  spec.add_dependency 'faraday-net_http', '>= 1.0', '< 4.0'
  spec.add_dependency 'json', '~> 2.0'

  spec.add_development_dependency 'bundler', '>= 2.0', '< 3.0'
  spec.add_development_dependency 'parallel', '~> 1.0' # parallel 2 requires Ruby 3.3+
  spec.add_development_dependency 'public_suffix', '< 7.0' # public_suffix 7 requires Ruby 3.2+
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'rubocop', '~> 1.0'
  spec.add_development_dependency 'simplecov', '~> 0.22'
  spec.add_development_dependency 'webmock', '~> 3.0'
  spec.add_development_dependency 'yard', '~> 0.9'
end
