require_relative 'lib/dynamic-records-meritfront/version.rb'

Gem::Specification.new do |spec|
  spec.name          = "dynamic-records-meritfront"
  spec.version       = DynamicRecordsMeritfront::VERSION
  spec.authors       = ["Luke Clancy"]
  spec.email         = ["lukeclancy@hotmail.com"]

  spec.summary       = %q{Helpers for active record that allow for more abstract and fine-grained code.}
  spec.description   = %q{Adds better functionality for writing raw sql. Adds hashed global id reference string for database records. This can help with the flexibility and speed of handling records.}
  spec.homepage      = "https://github.com/LukeClancy/dynamic-records-meritfront"
  spec.license       = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.3.0")

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/LukeClancy/dynamic-records-meritfront"
  spec.metadata["changelog_uri"] = "https://github.com/LukeClancy/dynamic-records-meritfront/blob/main/README.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "hashid-rails"
end
