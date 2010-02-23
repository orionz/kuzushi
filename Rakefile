require 'jeweler'

Jeweler::Tasks.new do |s|
	s.name = "kuzushi"
	s.description = "A tool used by the sumo gem for performing instance setup and management in AWS"
	s.summary = s.description
	s.author = "Orion Henry"
	s.email = "orion@heroku.com"
	s.homepage = "http://github.com/orionhenry/kuzushi"
#	s.rubyforge_project = "sumo"
	s.files = FileList["[A-Z]*", "{bin,lib,spec}/**/*"]
	s.executables = %w(kuzushi)
	s.add_dependency "rest-client"
	s.add_dependency "json"
	s.add_dependency "ohai"
end

Jeweler::RubyforgeTasks.new

desc 'Run specs'
task :spec do
	sh 'bacon -s spec/*_spec.rb'
end

task :default => :spec

