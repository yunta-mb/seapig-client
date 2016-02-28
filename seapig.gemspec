$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "seapig/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "seapig-client"
  s.version     = Seapig::VERSION
  s.authors     = ["yunta"]
  s.email       = ["maciej.blomberg@mikoton.com"]
  s.homepage    = "https://github.com/yunta-mb/seapig-client"
  s.summary     = "Transient object synchronization lib - client"
  s.description = "meh"
  s.license     = "MIT"

  s.files = Dir["{lib}/**/*", "MIT-LICENSE", "Rakefile", "README.rdoc", "bin/seapig-*"]
  s.test_files = Dir["test/**/*"]
  s.executables = ["seapig-observer","seapig-worker"]
  s.require_paths = ["lib"]

  s.add_dependency "websocket-eventmachine-client"
  s.add_dependency "jsondiff"
  s.add_dependency "hana"



end
