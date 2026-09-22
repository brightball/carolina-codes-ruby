# frozen_string_literal: true

require_relative "test_helper"

class GiteaWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.gitea/workflows/quality.yml", __dir__)
  HELPER = File.expand_path("../.gitea/ci/prepared_env.rb", __dir__)
  PREPARE = "prepare"
  CHECKS = {
    "tests" => /rake test/,
    "sast" => /\bsemgrep\b/,
    "audit" => /bundler-audit/,
    "gitleaks" => /\bgitleaks\b/,
    "lint" => /\brubocop\b/
  }.freeze
  INSTALL_LEAKS = [
    /\bapt-get\b/,
    /bundle install/,
    /pip3 install[^\n]*semgrep/,
    /gitleaks_8\.30\.1_linux_x64\.tar\.gz/
  ].freeze

  def setup
    @yaml_text = File.read(WORKFLOW)
    @workflow = YAML.safe_load(@yaml_text, permitted_classes: [], aliases: true)
  end

  def test_workflow_file_exists
    assert File.file?(WORKFLOW), "expected #{WORKFLOW}"
    assert File.file?(HELPER), "expected #{HELPER}"
  end

  def test_on_includes_push_and_or_pull_request
    on = @workflow.fetch("on")
    events =
      case on
      when Array then on.map(&:to_s)
      when Hash then on.keys.map(&:to_s)
      else [on.to_s]
      end
    assert(events.include?("push") || events.include?("pull_request"),
           "workflow on: must include push and/or pull_request, got #{on.inspect}")
  end

  def test_prepare_job_clones_sha_and_installs_shared_tools
    jobs = @workflow.fetch("jobs")
    refute_includes CHECKS.keys, PREPARE
    assert jobs.key?(PREPARE), "missing Gitea job #{PREPARE.inspect}; jobs=#{jobs.keys.inspect}"

    body = job_runs(jobs.fetch(PREPARE))
    assert_match(/GITHUB_SHA/, body)
    assert_match(/x-access-token/, body)
    assert_match(/\bapt-get\b/, body)
    assert_match(/bundle install/, body)
    assert_match(/pip3 install[^\n]*semgrep/, body)
    assert_match(/gitleaks_8\.30\.1_linux_x64\.tar\.gz/, body)
    assert_match(/prepared_env\.rb upload/, body)

    refute_match(/rake test/, body)
    refute_match(/semgrep scan/, body)
    refute_match(/bundler-audit/, body)
    refute_match(/gitleaks detect/, body)
    refute_match(/\brubocop\b/, body)
    refute_match(/\brake (check|precommit|ci|all)\b/, body)
  end

  def test_one_job_per_check_not_a_combined_job
    jobs = @workflow.fetch("jobs")
    CHECKS.each_key do |name|
      assert jobs.key?(name), "missing Gitea job #{name.inspect}; jobs=#{jobs.keys.inspect}"
    end

    CHECKS.each do |name, pattern|
      body = job_runs(jobs.fetch(name))
      assert_match pattern, body, "#{name} job must run #{pattern.inspect}"
      other = CHECKS.except(name)
      other.each do |other_name, other_pattern|
        refute_match other_pattern, body,
                     "#{name} job must not also run the #{other_name} check"
      end
    end

    jobs.each do |name, job|
      body = job_runs(job)
      refute_match(/\brake (check|precommit|ci|all)\b/, body,
                   "#{name} must not be a combined run-everything job")
    end
  end

  def test_check_jobs_need_prepare_and_not_each_other
    jobs = @workflow.fetch("jobs")
    CHECKS.each_key do |name|
      needs = Array(jobs.fetch(name)["needs"]).map(&:to_s)
      assert_includes needs, PREPARE, "#{name} must needs: #{PREPARE} (got #{needs.inspect})"
      overlap = needs & CHECKS.keys
      assert_empty overlap,
                   "#{name} must not needs: another check job (got #{needs.inspect})"
    end
  end

  def test_check_jobs_restore_prepared_tree_without_repeating_installs
    jobs = @workflow.fetch("jobs")
    CHECKS.each_key do |name|
      body = job_runs(jobs.fetch(name))
      assert_match(/prepared_env\.rb/, body, "#{name} must fetch the pack/restore helper")
      assert_match(/\brestore\b/, body, "#{name} must restore the prepared tree")
      INSTALL_LEAKS.each do |pattern|
        refute_match pattern, body,
                     "#{name} must not repeat #{pattern.inspect} after prepare"
      end
    end
  end

  def test_jobs_use_gitea_safe_checkout_not_actions_checkout_or_git_init
    refute_match(%r{uses:\s*actions/checkout}, @yaml_text)
    refute_match(/^\s*git init\b/m, @yaml_text)
    assert_match(/GITHUB_SHA/, @yaml_text)
    assert_match(/x-access-token/, @yaml_text)
  end

  def test_gitleaks_scans_branch_history_not_a_depth_1_snapshot
    jobs = @workflow.fetch("jobs")
    prepare = job_runs(jobs.fetch("prepare"))
    leaks = job_runs(jobs.fetch("gitleaks"))

    assert_match(/git clone\b/, prepare)
    assert_match(/git fetch origin/, prepare)
    refute_match(/--depth\b/, prepare)
    refute_match(/--depth\b/, leaks)
    refute_match(/--shallow\b/, prepare)
    refute_match(/--shallow\b/, leaks)
    assert_match(/gitleaks detect --source \./, leaks)
    assert_operator prepare.index("git clone"), :<, prepare.index("git checkout")
  end

  def test_sast_and_gitleaks_jobs_run_their_gates_in_ruby_containers
    jobs = @workflow.fetch("jobs")

    sast = jobs.fetch("sast")
    assert_match(/ruby:3\.3/, sast.dig("container", "image").to_s)
    sast_runs = job_runs(sast)
    assert_match(/semgrep scan/, sast_runs)
    refute_match(/gitleaks detect/, sast_runs)
    refute_match(/gitleaks protect/, sast_runs)
    refute_match(/pip3 install[^\n]*semgrep/, sast_runs)

    leaks = jobs.fetch("gitleaks")
    assert_match(/ruby:3\.3/, leaks.dig("container", "image").to_s)
    leaks_runs = job_runs(leaks)
    assert_match(/gitleaks detect --source \./, leaks_runs)
    refute_match(/gitleaks protect/, leaks_runs)
    refute_match(/gitleaks_8\.30\.1_linux_x64\.tar\.gz/, leaks_runs)
  end

  private

  def job_runs(job)
    steps = Array(job["steps"])
    steps.map { |step| step.is_a?(Hash) ? step["run"].to_s : "" }.join("\n")
  end
end
