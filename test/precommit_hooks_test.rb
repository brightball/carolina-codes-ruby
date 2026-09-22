# frozen_string_literal: true

require_relative "test_helper"

class PrecommitHooksTest < Minitest::Test
  CONFIG = File.expand_path("../.pre-commit-config.yaml", __dir__)
  HOOK = File.expand_path("../.githooks/pre-commit", __dir__)

  def test_precommit_gitleaks_protects_staged_secrets_not_history_only
    config = File.read(CONFIG)
    hook = File.read(HOOK)

    assert_match(/gitleaks protect --staged --verbose/, config)
    refute_match(/^\s+entry:\s+gitleaks detect\b/, config)

    assert_match(/gitleaks protect --staged --verbose/, hook)
    refute_match(/gitleaks detect --source/, hook)
  end
end
