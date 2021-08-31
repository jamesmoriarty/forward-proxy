# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rake/testtask'
require 'yard'
require 'rubocop/rake_task'

RuboCop::RakeTask.new

YARD::Rake::YardocTask.new do |t|
  t.files = ['lib/**/*.rb', 'README', 'CHANGELOG', 'CODE_OF_CONDUCT']
  t.options = []
  t.stats_options = ['--list-undoc']
end

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  t.test_files = FileList['test/**/*_test.rb']
end

namespace :gh do
  desc 'Deploy yard docs to github pages'
  task pages: :yard do
    `git add -f doc`
    `git commit -am "update: $(date)"`
    `git subtree split --prefix doc -b gh-pages`
    `git push -f origin gh-pages:gh-pages`
    `git branch -D gh-pages`
    `git reset head~1`
  end
end

task default: :"rubocop:auto_correct"
task default: :test
