Gem::Specification.new do |s|
  s.name = 'logstash-input-zendesk'
  s.version         = '1.0.0'
  s.licenses = ['Apache License (2.0)']
  s.summary = "This input fetches various objects from Zendesk."
  s.description = "This gem is a logstash plugin required to be installed on top of the Logstash core pipeline using $LS_HOME/bin/plugin install logstash-input-zendesk-1.0.0.gem. This gem is not a stand-alone program"
  s.authors = ["Pius Fung"]
  s.email = 'pius@elastic.co'
  s.homepage = "http://www.elastic.co/guide/en/logstash/current/index.html"
  s.require_paths = ["lib"]

  # Files
  s.files = `git ls-files`.split($\)
   # Tests
  s.test_files = s.files.grep(%r{^(test|spec|features)/})

  # Special flag to let us know this is actually a logstash plugin
  s.metadata = { "logstash_plugin" => "true", "logstash_group" => "input" }

  # Gem dependencies
  s.add_runtime_dependency "logstash-core", '>= 1.4.0', '< 2.0.0'
  s.add_runtime_dependency 'logstash-codec-plain'
  s.add_runtime_dependency 'stud'
  s.add_development_dependency 'logstash-devutils'
  s.add_runtime_dependency 'zendesk_api', ["= 1.11.6"]
end
