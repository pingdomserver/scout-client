# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "scout/version"

Gem::Specification.new do |s|
  s.name        = "scout"
  s.version     = Scout::VERSION
  s.authors     = ["Andre Lewis", "Derek Haynes"]
  s.email = "support.server@pingdom.com"
  s.rubyforge_project = "scout"
  s.homepage = "http://server.pingdom.com"
  s.summary = "Scout is an easy-to-use hosted server monitoring service. The scout Ruby gem reports metrics to our service. The agent runs plugins, configured via the Scout web interface, to monitor a server."
  s.description = <<END_DESC
The scout gem reports metrics to server.pingdom.com, an easy-to-use hosted server monitoring service.
END_DESC

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  # specify any dependencies here; for example:
  # s.add_development_dependency "rspec"
  s.add_runtime_dependency "elif"
  s.add_runtime_dependency "server_metrics",">= 1.2.18"
end
