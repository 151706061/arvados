if not File.exists?('/usr/bin/git') then
  STDERR.puts "\nGit binary not found, aborting. Please install git and run gem build from a checked out copy of the git repository.\n\n"
  exit
end

Gem::Specification.new do |s|
  s.name        = 'arvados-cli'
  s.version     = '0.1.' + `/usr/bin/git log --pretty=format:'%ci' -n 1`[0..18].gsub(/[ \-:]/,'')
  s.date        = `/usr/bin/git log --pretty=format:'%ci' -n 1`[0..9]
  s.summary     = "Arvados SDK CLI"
  s.description = "This is the Arvados SDK CLI gem, git revision " + `/usr/bin/git log --pretty=format:'%H' -n 1`
  s.authors     = ["Arvados Authors"]
  s.email       = 'gem-dev@curoverse.com'
  #s.bindir      = '.'
  s.licenses    = ['Apache License, Version 2.0']
  s.files       = ["bin/arv","bin/arv-run-pipeline-instance","bin/arv-crunch-job","bin/arv-tag","bin/crunch-job"]
  s.executables << "arv"
  s.executables << "arv-run-pipeline-instance"
  s.executables << "arv-crunch-job"
  s.executables << "arv-tag"
  s.add_runtime_dependency 'google-api-client', '~> 0.6', '>= 0.6.3'
  s.add_runtime_dependency 'activesupport', '~> 3.2', '>= 3.2.13'
  s.add_runtime_dependency 'json', '~> 1.7', '>= 1.7.7'
  s.add_runtime_dependency 'trollop', '~> 2.0'
  s.add_runtime_dependency 'andand', '~> 1.3', '>= 1.3.3'
  s.add_runtime_dependency 'oj', '~> 2.0', '>= 2.0.3'
  s.add_runtime_dependency 'curb', '~> 0.8'
  s.homepage    =
    'http://arvados.org'
end
