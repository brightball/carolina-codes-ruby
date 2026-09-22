# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "tmpdir"
require "uri"

# Packs the prepared CI workspace and moves it between Gitea Actions jobs
# through the Actions artifact HTTP API (no Node, no actions/checkout).
module PreparedEnv # rubocop:disable Metrics/ModuleLength
  ARTIFACT_NAME = "prepared-env"
  TARBALL_NAME = "prepared-env.tar.gz"
  DEFAULT_CHUNK_SIZE = 8 * 1024 * 1024

  class Error < StandardError; end

  module_function

  def chunk_size
    Integer(ENV.fetch("PREPARED_ENV_CHUNK_SIZE", DEFAULT_CHUNK_SIZE))
  end

  def pack(workspace, tarball)
    FileUtils.mkdir_p(File.dirname(tarball))
    run_tar(["-czf", tarball, "-C", workspace, "."])
  end

  def unpack(tarball, workspace)
    FileUtils.mkdir_p(workspace)
    run_tar(["-xzf", tarball, "-C", workspace, "--no-same-owner"])
  end

  def run_tar(args)
    # Argument vector to tar, not a shell. Callers pass a temp path and the workspace.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    _stdout, stderr, status = Open3.capture3("tar", *args)
    return if status.success?

    raise Error, "tar failed: #{stderr}"
  end

  # Gitea artifact uploads require the x-actions-results-md5 header.
  def artifact_chunk_md5(bytes)
    # nosemgrep: ruby.lang.security.weak-hashes-md5.weak-hashes-md5
    Base64.strict_encode64(Digest::MD5.digest(bytes))
  end

  def upload!(workspace: Dir.pwd)
    tarball = File.join(Dir.tmpdir, "prepared-env-#{Process.pid}.tar.gz")
    pack(workspace, tarball)
    upload_file(tarball)
  ensure
    FileUtils.rm_f(tarball)
  end

  def restore!(workspace: Dir.pwd)
    tarball = File.join(Dir.tmpdir, "prepared-env-#{Process.pid}.tar.gz")
    download_file(tarball)
    unpack(tarball, workspace)
    write_github_env(workspace)
  ensure
    FileUtils.rm_f(tarball)
  end

  def upload_file(path)
    raise Error, "missing tarball #{path}" unless File.file?(path)

    created = json_request(:post, artifacts_collection_url, body: {
                             "Type" => "actions_storage",
                             "Name" => ARTIFACT_NAME,
                             "RetentionDays" => 1
                           })
    upload_url = absolute_url(created.fetch("fileContainerResourceUrl"))
    put_chunks(upload_url, path)
    request(:patch, with_query(artifacts_collection_url, "artifactName" => ARTIFACT_NAME))
  end

  def download_file(path)
    listing = json_request(:get, artifacts_collection_url)
    artifact = Array(listing["value"]).find { |item| item["name"].to_s == ARTIFACT_NAME }
    raise Error, "prepared-env artifact not listed: #{listing.inspect}" unless artifact

    container = absolute_url(artifact.fetch("fileContainerResourceUrl"))
    files = json_request(:get, with_query(container, "itemPath" => ARTIFACT_NAME))
    entry = Array(files["value"]).first
    raise Error, "prepared-env artifact had no files: #{files.inspect}" unless entry

    location = absolute_url(entry.fetch("contentLocation"))
    item_path = entry["path"] || "#{ARTIFACT_NAME}/#{TARBALL_NAME}"
    response = request(:get, with_query(location, "itemPath" => item_path))
    File.binwrite(path, response.body)
  end

  def put_chunks(upload_url, path)
    total = File.size(path)
    raise Error, "refusing to upload empty tarball" if total.zero?

    File.open(path, "rb") do |file|
      offset = 0
      while offset < total
        chunk = file.read(chunk_size)
        raise Error, "short read while uploading #{path}" if chunk.nil? || chunk.empty?

        finish = offset + chunk.bytesize - 1
        url = with_query(upload_url, "itemPath" => "#{ARTIFACT_NAME}/#{TARBALL_NAME}")
        request(
          :put,
          url,
          body: chunk,
          headers: {
            "Content-Type" => "application/octet-stream",
            "x-tfs-filelength" => total.to_s,
            "x-actions-results-md5" => artifact_chunk_md5(chunk),
            "content-range" => "bytes #{offset}-#{finish}/#{total}"
          }
        )
        offset = finish + 1
      end
    end
  end

  def write_github_env(workspace)
    github_env = ENV.fetch("GITHUB_ENV", nil)
    return if github_env.nil? || github_env.empty?

    bin = File.join(File.expand_path(workspace), ".ci", "bin")
    pypkgs = File.join(File.expand_path(workspace), ".ci", "pypkgs")
    bundle_path = File.join(File.expand_path(workspace), "vendor", "bundle")
    path = "#{bin}:#{ENV.fetch('PATH', '')}"
    existing_python = ENV.fetch("PYTHONPATH", nil).to_s
    pythonpath = existing_python.empty? ? pypkgs : "#{pypkgs}:#{existing_python}"
    File.open(github_env, "a") do |io|
      io.puts "PATH=#{path}"
      io.puts "PYTHONPATH=#{pythonpath}"
      io.puts "BUNDLE_PATH=#{bundle_path}"
    end
  end

  def artifacts_collection_url
    runtime = ENV.fetch("ACTIONS_RUNTIME_URL")
    run_id = ENV.fetch("GITHUB_RUN_ID")
    base = runtime.end_with?("/") ? runtime : "#{runtime}/"
    "#{base}_apis/pipelines/workflows/#{run_id}/artifacts?api-version=6.0-preview"
  end

  def token
    value = ENV["ACTIONS_RUNTIME_TOKEN"].to_s
    value = ENV["GITHUB_TOKEN"].to_s if value.empty?
    raise Error, "missing ACTIONS_RUNTIME_TOKEN for artifact transfer" if value.empty?

    value
  end

  def absolute_url(url)
    url = url.to_s
    return url if url.match?(%r{\Ahttps?://}i)

    runtime = ENV.fetch("ACTIONS_RUNTIME_URL")
    origin = runtime.sub(%r{/api/actions_pipeline/?\z}i, "")
    return origin + url if url.start_with?("/")

    base = runtime.end_with?("/") ? runtime : "#{runtime}/"
    base + url
  end

  def with_query(url, extra)
    uri = URI(url)
    params = URI.decode_www_form(uri.query || "")
    extra.each { |key, value| params << [key.to_s, value.to_s] }
    uri.query = URI.encode_www_form(params)
    uri.to_s
  end

  def json_request(method, url, body: nil, headers: {})
    payload = body && JSON.generate(body)
    headers = headers.merge("Content-Type" => "application/json") if payload
    headers = headers.merge("Accept" => "application/json;api-version=6.0-preview")
    response = request(method, url, body: payload, headers: headers)
    JSON.parse(response.body)
  rescue JSON::ParserError => e
    raise Error, "invalid JSON from #{url}: #{e.message} body=#{response_preview(response)}"
  end

  def request(method, url, body: nil, headers: {})
    uri = URI(url)
    klass = http_class(method)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 30
    http.read_timeout = 300
    req = klass.new(uri.request_uri)
    req["Authorization"] = "Bearer #{token}"
    req["Connection"] = "close"
    headers.each { |key, value| req[key] = value }
    req.body = body if body
    response = http.request(req)
    unless response.is_a?(Net::HTTPSuccess)
      raise Error, "#{method.upcase} #{url} failed: #{response.code} #{response.body}"
    end

    response
  end

  def http_class(method)
    {
      get: Net::HTTP::Get,
      post: Net::HTTP::Post,
      put: Net::HTTP::Put,
      patch: Net::HTTP::Patch
    }.fetch(method)
  end

  def response_preview(response)
    return "" unless response

    response.body.to_s[0, 200]
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.fetch(0) { abort "usage: prepared_env.rb upload|restore" }
  case command
  when "upload" then PreparedEnv.upload!
  when "restore" then PreparedEnv.restore!
  else abort "usage: prepared_env.rb upload|restore"
  end
end
