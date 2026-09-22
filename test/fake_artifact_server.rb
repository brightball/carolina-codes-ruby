# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "socket"
require "uri"

# Minimal Gitea Actions artifact HTTP API for PreparedEnv tests.
class FakeArtifactServer
  Artifact = Struct.new(:id, :name, :files, :confirmed, keyword_init: true)

  def initialize(token:)
    @token = token
    @mutex = Mutex.new
    @next_id = 1
    @artifacts = {}
    @chunks = Hash.new { |hash, key| hash[key] = [] }
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { accept_loop }
    @thread.abort_on_exception = true
  end

  def runtime_url
    "http://127.0.0.1:#{@port}/api/actions_pipeline/"
  end

  def shutdown
    @server.close
    @thread.kill
  rescue IOError
    nil
  end

  private

  def accept_loop
    loop do
      sock = @server.accept
      Thread.new { handle(sock) }
    end
  rescue IOError
    nil
  end

  def handle(sock)
    req = read_request(sock)
    return if req.nil?

    unless req[:headers]["authorization"] == "Bearer #{@token}"
      respond(sock, 401, "unauthorized")
      return
    end

    route(sock, req)
  ensure
    sock.close
  end

  def route(sock, req)
    path = req[:path]
    query = URI.decode_www_form(req[:query]).to_h
    case req[:method]
    when "POST"
      create_upload(sock, path, req[:body])
    when "PUT"
      upload_chunk(sock, path, query, req)
    when "PATCH"
      confirm(sock, path, query)
    when "GET"
      get_route(sock, path, query)
    else
      respond(sock, 405, "method not allowed")
    end
  end

  def create_upload(sock, path, body)
    return respond(sock, 404, "not found") unless collection?(path)

    payload = JSON.parse(body)
    name = payload.fetch("Name")
    @mutex.synchronize do
      @artifacts[name] ||= Artifact.new(id: @next_id, name: name, files: {}, confirmed: false)
      @next_id += 1
    end
    hash = md5_hex(name)
    url = "#{origin}/api/actions_pipeline/_apis/pipelines/workflows/791/artifacts/#{hash}/upload"
    respond(sock, 200, JSON.generate("fileContainerResourceUrl" => url))
  end

  def upload_chunk(sock, path, query, req)
    match = path.match(%r{/artifacts/([^/]+)/upload\z})
    return respond(sock, 404, "not found") unless match

    item_path = query.fetch("itemPath")
    name, filename = split_item_path(item_path)
    range = req[:headers]["content-range"].to_s
    start_at = 0
    if (m = range.match(%r{bytes\s+(\d+)-(\d+)/(\d+)}))
      start_at = Integer(m[1])
    end
    digest = md5_b64(req[:body])
    header_digest = req[:headers]["x-actions-results-md5"].to_s
    return respond(sock, 400, "md5 not match") unless digest == header_digest

    @mutex.synchronize do
      @chunks["#{name}/#{filename}"] << [start_at, req[:body]]
    end
    respond(sock, 200, JSON.generate("message" => "success"))
  end

  def confirm(sock, path, query)
    return respond(sock, 404, "not found") unless collection?(path)

    name = query.fetch("artifactName")
    @mutex.synchronize do
      artifact = @artifacts[name]
      return respond(sock, 404, "missing artifact") unless artifact

      @chunks.each do |key, pieces|
        next unless key.start_with?("#{name}/")

        filename = key.delete_prefix("#{name}/")
        artifact.files[filename] = pieces.sort_by(&:first).map(&:last).join
      end
      artifact.confirmed = true
    end
    respond(sock, 200, JSON.generate("message" => "success"))
  end

  def get_route(sock, path, query)
    if collection?(path)
      list_artifacts(sock)
    elsif (match = path.match(%r{/artifacts/([^/]+)/download_url\z}))
      download_url(sock, match[1], query)
    elsif (match = path.match(%r{/artifacts/([^/]+)/download\z}))
      download_file(sock, match[1], query)
    else
      respond(sock, 404, "not found")
    end
  end

  def list_artifacts(sock)
    items = @mutex.synchronize do
      @artifacts.values.select(&:confirmed).map do |artifact|
        hash = md5_hex(artifact.name)
        {
          "name" => artifact.name,
          "fileContainerResourceUrl" =>
            "#{origin}/api/actions_pipeline/_apis/pipelines/workflows/791/artifacts/#{hash}/download_url"
        }
      end
    end
    return respond(sock, 404, "no artifacts") if items.empty?

    respond(sock, 200, JSON.generate("count" => items.size, "value" => items))
  end

  def download_url(sock, hash, query)
    item_path = query.fetch("itemPath")
    artifact = @mutex.synchronize do
      @artifacts.values.find { |item| md5_hex(item.name) == hash && item.name == item_path }
    end
    return respond(sock, 404, "missing artifact") unless artifact&.confirmed

    files = artifact.files.map do |filename, _data|
      {
        "path" => "#{artifact.name}/#{filename}",
        "itemType" => "file",
        "contentLocation" =>
          "#{origin}/api/actions_pipeline/_apis/pipelines/workflows/791/artifacts/#{artifact.id}/download"
      }
    end
    respond(sock, 200, JSON.generate("value" => files))
  end

  def download_file(sock, id, query)
    item_path = query["itemPath"].to_s
    artifact = @mutex.synchronize { @artifacts.values.find { |item| item.id.to_s == id.to_s } }
    return respond(sock, 404, "missing artifact") unless artifact&.confirmed

    filename = item_path.split("/", 2)[1] || artifact.files.keys.first
    data = artifact.files[filename]
    return respond(sock, 404, "missing file") if data.nil?

    respond(sock, 200, data, content_type: "application/octet-stream")
  end

  def collection?(path)
    path.match?(%r{/artifacts\z})
  end

  def split_item_path(item_path)
    name, filename = item_path.split("/", 2)
    [name, filename || File.basename(item_path)]
  end

  def origin
    "http://127.0.0.1:#{@port}"
  end

  # The artifact API addresses blobs with MD5. These are not password hashes.
  def md5_hex(value)
    # nosemgrep: ruby.lang.security.weak-hashes-md5.weak-hashes-md5
    Digest::MD5.hexdigest(value)
  end

  def md5_b64(value)
    # nosemgrep: ruby.lang.security.weak-hashes-md5.weak-hashes-md5
    Base64.strict_encode64(Digest::MD5.digest(value))
  end

  def read_request(sock)
    request_line = sock.gets("\n")
    return nil if request_line.nil? || request_line.strip.empty?

    method, raw_path, = request_line.split(" ", 3)
    headers = {}
    loop do
      line = sock.gets("\n")
      break if line.nil? || line == "\r\n" || line == "\n"

      key, value = line.split(":", 2)
      headers[key.downcase] = value.to_s.strip
    end
    length = headers["content-length"].to_i
    body = +""
    body << sock.read(length - body.bytesize) while body.bytesize < length
    path, query = raw_path.split("?", 2)
    { method: method, path: path, query: query.to_s, headers: headers, body: body }
  end

  def respond(sock, code, body, content_type: "application/json")
    body = body.to_s
    reason = code == 200 ? "OK" : "ERR"
    sock.write("HTTP/1.1 #{code} #{reason}\r\n")
    sock.write("Content-Type: #{content_type}\r\n")
    sock.write("Content-Length: #{body.bytesize}\r\n")
    sock.write("Connection: close\r\n")
    sock.write("\r\n")
    sock.write(body)
  end
end
