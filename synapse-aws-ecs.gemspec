# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'synapse-aws-ecs/version'

Gem::Specification.new do |gem|
  gem.name          = "synapse-aws-ecs"
  gem.version       = SynapseAwsEcs::VERSION
  # Add the original authors if they care
  gem.authors       = ["Ben Walding"]
  gem.email         = ["bwalding@cloudbees.com"]
  gem.description   = "Creates a Synapse service watcher that monitor Amazon ECS"
  gem.summary       = "Amazon ECS service watcher plugin"
  gem.homepage      = "https://github.com/cloudbees-community/synapse-aws-ecs"

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})

  gem.add_runtime_dependency "synapse"

  gem.add_development_dependency "rake"
  gem.add_development_dependency "rspec", "~> 3.1.0"
  gem.add_development_dependency "pry"
  gem.add_development_dependency "pry-byebug"
  gem.add_development_dependency "webmock"
end
