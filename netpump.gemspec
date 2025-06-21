# frozen_string_literal: true

require "pathname"

Gem::Specification.new do |s|
  s.name = "netpump"
  s.version = Pathname(__dir__).join("VERSION").read.chomp
  s.summary = "tiny websocket proxy tunnel"
  s.homepage = "https://netpump.org"
  s.author = "soylent"
  s.license = "MIT"
  s.files = Dir["bin/*", "lib/**/*", "public/*", "VERSION", "CHANGELOG"]
  s.executables = "netpump"
  s.required_ruby_version = ">= 2.5.0"
  s.add_dependency "base64", "~> 0.0"
  s.add_dependency "em-websocket", "~> 0.5"
  s.add_dependency "eventmachine-proxy", "~> 1.0"
end
