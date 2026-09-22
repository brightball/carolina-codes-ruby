# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

desc "Static analysis security scan (Semgrep Ruby rules)"
task :sast do
  sh "semgrep scan --config p/ruby --error --metrics off --no-git-ignore --exclude vendor --exclude .git"
end

desc "Scan gems for known CVEs"
task :audit do
  sh "bundle exec bundler-audit check --update"
end

desc "Scan the tree for secrets with gitleaks"
task :gitleaks do
  sh "gitleaks detect --source . --verbose"
end

desc "Ruby style (RuboCop)"
task :lint do
  sh "bundle exec rubocop"
end

desc "Install git pre-commit hooks"
task :hooks do
  sh "pre-commit install"
  sh "git config core.hooksPath .githooks"
end

task default: :test
