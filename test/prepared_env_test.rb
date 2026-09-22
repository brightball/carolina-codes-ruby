# frozen_string_literal: true

require_relative "test_helper"
require_relative "fake_artifact_server"
require_relative "../.gitea/ci/prepared_env"

require "fileutils"
require "tmpdir"

class PreparedEnvTest < Minitest::Test
  def setup
    @env_keys = %w[
      ACTIONS_RUNTIME_URL ACTIONS_RUNTIME_TOKEN GITHUB_RUN_ID
      GITHUB_ENV PREPARED_ENV_CHUNK_SIZE GITHUB_TOKEN
    ]
    @saved_env = @env_keys.to_h { |key| [key, ENV.fetch(key, nil)] }
  end

  def teardown
    @saved_env.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  def test_pack_and_unpack_round_trip_includes_hidden_ci_files
    Dir.mktmpdir do |src|
      FileUtils.mkdir_p(File.join(src, ".ci", "bin"))
      FileUtils.mkdir_p(File.join(src, "vendor", "bundle"))
      File.write(File.join(src, ".ci", "env.sh"), "export PATH=ok\n")
      File.write(File.join(src, "vendor", "bundle", "gem.rb"), "hi\n")
      File.write(File.join(src, "app.rb"), "app\n")

      Dir.mktmpdir do |dst|
        tarball = File.join(Dir.tmpdir, "prepared-env-test-#{Process.pid}.tar.gz")
        begin
          PreparedEnv.pack(src, tarball)
          PreparedEnv.unpack(tarball, dst)
          assert_equal "export PATH=ok\n", File.read(File.join(dst, ".ci", "env.sh"))
          assert_equal "hi\n", File.read(File.join(dst, "vendor", "bundle", "gem.rb"))
          assert_equal "app\n", File.read(File.join(dst, "app.rb"))
        ensure
          FileUtils.rm_f(tarball)
        end
      end
    end
  end

  def test_upload_and_restore_round_trip_against_artifact_api
    server = FakeArtifactServer.new(token: "secret-token")
    Dir.mktmpdir do |src|
      FileUtils.mkdir_p(File.join(src, ".ci", "bin"))
      File.write(File.join(src, ".ci", "env.sh"), "export PATH=#{src}/.ci/bin:${PATH}\n")
      File.write(File.join(src, "hello.txt"), "hello-prepared\n")
      File.write(File.join(src, "payload.bin"), "x" * 40)

      ENV["ACTIONS_RUNTIME_URL"] = server.runtime_url
      ENV["ACTIONS_RUNTIME_TOKEN"] = "secret-token"
      ENV["GITHUB_RUN_ID"] = "791"
      ENV["PREPARED_ENV_CHUNK_SIZE"] = "16"

      Dir.chdir(src) { PreparedEnv.upload! }

      Dir.mktmpdir do |dst|
        github_env = File.join(dst, "github.env")
        ENV["GITHUB_ENV"] = github_env
        Dir.chdir(dst) { PreparedEnv.restore! }

        assert_equal "hello-prepared\n", File.read(File.join(dst, "hello.txt"))
        assert_equal "x" * 40, File.read(File.join(dst, "payload.bin"))
        assert File.file?(File.join(dst, ".ci", "env.sh"))
        env_text = File.read(github_env)
        assert_match(%r{PATH=.*/\.ci/bin:}, env_text)
        assert_match(%r{PYTHONPATH=.*/\.ci/pypkgs}, env_text)
        assert_match(%r{BUNDLE_PATH=.*/vendor/bundle}, env_text)
      end
    end
  ensure
    server&.shutdown
  end

  def test_upload_rejects_wrong_runtime_token
    server = FakeArtifactServer.new(token: "secret-token")
    Dir.mktmpdir do |src|
      File.write(File.join(src, "hello.txt"), "hello\n")
      ENV["ACTIONS_RUNTIME_URL"] = server.runtime_url
      ENV["ACTIONS_RUNTIME_TOKEN"] = "wrong-token"
      ENV["GITHUB_RUN_ID"] = "791"
      error = assert_raises(PreparedEnv::Error) do
        Dir.chdir(src) { PreparedEnv.upload! }
      end
      assert_match(/401|failed/, error.message)
    end
  ensure
    server&.shutdown
  end
end
