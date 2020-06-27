begin
	require 'git-version-bump'
rescue LoadError
	nil
end

Gem::Specification.new do |s|
	s.name = "evinrude"

	s.version = GVB.version rescue "0.0.0.1.NOGVB"
	s.date    = GVB.date    rescue Time.now.strftime("%Y-%m-%d")

	s.platform = Gem::Platform::RUBY

	s.summary	= "The Raft engine"

	s.authors  = ["Matt Palmer"]
	s.email    = ["theshed+evinrude@hezmatt.org"]
	s.homepage = "https://github.com/mpalmer/evinrude"

	s.files = `git ls-files -z`.split("\0").reject { |f| f =~ /^(G|spec|Rakefile)/ }

	s.required_ruby_version = ">= 2.5.0"

	s.add_runtime_dependency "async"
	s.add_runtime_dependency "async-dns"
	s.add_runtime_dependency "async-io"
  s.add_runtime_dependency "frankenstein", "~> 2.1"
	s.add_runtime_dependency "prometheus-client", "~> 2.0"
	s.add_runtime_dependency "rbnacl"

	s.add_development_dependency 'bundler'
	s.add_development_dependency 'github-release'
	s.add_development_dependency 'guard-rspec'
	s.add_development_dependency 'rake', '~> 10.4', '>= 10.4.2'
	# Needed for guard
	s.add_development_dependency 'rb-inotify', '~> 0.9'
	s.add_development_dependency 'redcarpet'
	s.add_development_dependency 'rspec'
	s.add_development_dependency 'simplecov'
	s.add_development_dependency 'yard'
end
