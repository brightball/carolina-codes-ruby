# frozen_string_literal: true

require "open3"
require "socket"

require_relative "test_helper"

class ColdStartTest < Minitest::Test
  PROBE = File.expand_path("boot_probe.rb", __dir__)

  # Accepts the registration TCP connection and never writes a response.
  class Blackhole
    attr_reader :port, :requests

    def initialize
      @requests = []
      @clients = []
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { accept_loop }
    end

    def stop
      @server.close
      @clients.each do |client|
        client.close
      rescue IOError
        nil
      end
      @thread.join(1)
    end

    private

    def accept_loop
      loop do
        client = @server.accept
        @requests << read_request(client)
        @clients << client
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def read_request(client)
      buffer = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        ready = client.wait_readable(0.1)
        next unless ready

        begin
          chunk = client.read_nonblock(8192)
        rescue IO::WaitReadable
          next
        rescue EOFError
          break
        end
        buffer << chunk
        break if request_complete?(buffer)
      end
      buffer
    end

    def request_complete?(buffer)
      head, body = buffer.split("\r\n\r\n", 2)
      return false if body.nil?

      length = head[/Content-Length:\s*(\d+)/i, 1]
      return true if length.nil?

      body.bytesize >= Integer(length)
    end
  end

  def test_hung_registration_peer_serves_health_within_3s_without_sql_or_extra_connection
    server = Blackhole.new
    env = ENV.to_h.merge(
      "CAROLINA_URL" => "http://127.0.0.1:#{server.port}",
      "POLYGLOT_REGISTER_TOKEN" => "probe-token",
      "RACK_ENV" => "test",
      "APP_ENV" => "test"
    )
    stdout = +""
    stderr = +""
    elapsed = nil
    status = nil
    Open3.popen3(env, Gem.ruby, PROBE) do |stdin, out, err, wait_thr|
      stdin.close
      err_thread = Thread.new { stderr = err.read.to_s }
      stdout, elapsed = read_probe(out, wait_thr)
      unless wait_thr.join(2)
        Process.kill("TERM", wait_thr.pid)
        wait_thr.join(2)
      end
      status = wait_thr.value
      err_thread.join(1)
    end

    posts = server.requests.count { |request| request.start_with?("POST ") }
    sleep 0.4
    posts_after = server.requests.count { |request| request.start_with?("POST ") }
    counts = stdout.match(/^COUNTS sql=(\d+) connect=(\d+)$/)
    health = stdout[/^HEALTH (.+)$/, 1]
    sql = counts ? Integer(counts[1]) : nil
    connect = counts ? Integer(counts[2]) : nil
    puts "health_ok_within_3s=#{elapsed&.round(3)} registration_posts=#{posts} " \
         "registration_sql=#{sql} registration_connect=#{connect} " \
         "child_exit=#{status&.exitstatus} posts_after_wait=#{posts_after}"

    assert_match(/"ok"\s*:\s*true/, health.to_s, "stdout=#{stdout.inspect} stderr=#{stderr.inspect}")
    refute_nil elapsed, "health was not served; stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    assert_operator elapsed, :<, 3
    assert_equal 1, posts, "requests=#{server.requests.inspect} stderr=#{stderr.inspect}"
    assert_equal 1, posts_after
    assert_equal 0, sql
    assert_equal 1, connect
    assert_equal 0, status.exitstatus, "stderr=#{stderr.inspect} stdout=#{stdout.inspect}"
  ensure
    server&.stop
  end

  private

  def read_probe(stdout, wait_thr)
    buffer = +""
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    health_at = nil
    loop do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if now - start > 8
      break if health_at.nil? && (now - start) > 3 && !buffer.include?("HEALTH ")

      ready = stdout.wait_readable(0.1)
      if ready
        begin
          chunk = stdout.read_nonblock(8192)
          buffer << chunk
        rescue IO::WaitReadable
          next
        rescue EOFError
          break
        end
        health_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) if buffer.include?("HEALTH ")
      end
      break if buffer.include?("COUNTS ") && !wait_thr.alive?
      break if !wait_thr.alive? && ready.nil?
    end
    begin
      extra = stdout.read_nonblock(65_536)
      buffer << extra if extra
    rescue IO::WaitReadable, EOFError
      nil
    end
    elapsed = health_at ? health_at - start : nil
    [buffer, elapsed]
  end
end
