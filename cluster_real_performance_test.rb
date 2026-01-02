#!/usr/bin/env ruby
#
# Real Cluster Performance Test
#
# Tests actual Redis and DRb infrastructure, comparing:
#   - Local Redis vs Remote VPS Redis servers
#   - Redis vs DRb implementations
#
# Usage:
#   ruby spec/cluster_real_performance_test.rb                    # Run all tests
#   ruby spec/cluster_real_performance_test.rb redis              # Redis only
#   ruby spec/cluster_real_performance_test.rb drb                # DRb only
#   ruby spec/cluster_real_performance_test.rb --quick            # Quick test (fewer iterations)
#   ruby spec/cluster_real_performance_test.rb --debug            # Verbose output
#
# Requirements:
#   - For Redis tests: redis gem, local Redis server
#   - For DRb tests: drbcluster_broker running on localhost:8787
#   - For remote tests: VPS Redis servers accessible

require 'json'
require 'ostruct'
require 'securerandom'
require 'benchmark'

begin
  require 'redis'
  require 'connection_pool'
  REDIS_AVAILABLE = true
rescue LoadError
  REDIS_AVAILABLE = false
  puts "Warning: redis gem not available, skipping Redis tests"
end

begin
  require 'drb/drb'
  DRB_AVAILABLE = true
rescue LoadError
  DRB_AVAILABLE = false
  puts "Warning: drb not available, skipping DRb tests"
end

# Helper to get WSL IP dynamically
def get_wsl_ip
  result = %x(wsl hostname -I 2>&1).strip rescue nil
  return nil if result.nil? || result.empty?
  ip = result.split.first
  ip =~ /^\d+\.\d+\.\d+\.\d+$/ ? ip : nil
end

WSL_IP = get_wsl_ip

# Server configurations
REDIS_SERVERS = {
  local_win: {
    name: "local (win)",
    host: "localhost",
    port: 6379,
    password: nil,
    ssl: false
  },
  local_wsl: {
    name: "local (wsl)",
    host: WSL_IP,
    port: 6379,
    password: nil,
    ssl: false,
    skip_if_nil_host: true
  },
  google: {
    name: "google",
    host: "backup.gs-game.uk",
    port: 42113,
    password: "a9eK4!x9b2l",
    ssl: true
  },
  contabo: {
    name: "contabo",
    host: "primary.gs-game.uk",
    port: 42113,
    password: "a9eK4!x9b2l",
    ssl: true
  },
  upstash: {
    name: "upstash",
    host: "sensible-vervet-9854.upstash.io",
    port: 6379,
    password: "ASZ-AAImcDJkZWNjMDAyODYzODE0NmZhOTU2ZDRjMjZiZDNlODY4M3AyOTg1NA",
    ssl: true
  }
}

DRB_SERVERS = {
  local: {
    name: "local",
    uri: "druby://localhost:8787"
  }
}

class RealPerformanceTest
  attr_reader :results

  def initialize(options = {})
    @options = options
    @debug = options[:debug]
    @quick = options[:quick]
    @results = {}
    @mutex = Mutex.new

    # Adjust iterations based on quick mode
    @ping_iterations = @quick ? 20 : 100
    @throughput_messages = @quick ? 100 : 1000
    @registry_iterations = @quick ? 50 : 200
    @warmup_pings = @quick ? 3 : 10
  end

  def log(msg)
    puts msg if @debug
  end

  def run_all
    puts "\n" + "=" * 70
    puts "REAL CLUSTER PERFORMANCE TEST"
    puts "=" * 70
    puts "Mode: #{@quick ? 'Quick' : 'Full'}"
    puts "Time: #{Time.now}"
    puts "=" * 70

    # Raw socket baseline test first
    run_socket_baseline_test

    run_redis_tests if REDIS_AVAILABLE && (!@options[:type] || @options[:type] == 'redis')
    run_drb_tests if DRB_AVAILABLE && (!@options[:type] || @options[:type] == 'drb')

    generate_comparison_report
    save_results
  end

  # Raw TCP socket test to establish baseline
  def run_socket_baseline_test
    puts "\n" + "-" * 50
    puts "SOCKET BASELINE TEST"
    puts "-" * 50

    require 'socket'

    # Test raw TCP to Redis port
    print "  Raw TCP to localhost:6379... "
    begin
      latencies = []
      10.times do
        start = Time.now
        sock = TCPSocket.new('localhost', 6379)
        sock.write("PING\r\n")
        sock.gets
        sock.close
        latencies << (Time.now - start) * 1000
      end
      mean = latencies.sum / latencies.size
      puts "mean=#{mean.round(2)}ms"
      @results[:socket_baseline] = { tcp_redis: mean }
    rescue => e
      puts "FAILED: #{e.message}"
    end

    # Test raw TCP to DRb port
    print "  Raw TCP to localhost:8787... "
    begin
      latencies = []
      10.times do
        start = Time.now
        sock = TCPSocket.new('localhost', 8787)
        sock.close
        latencies << (Time.now - start) * 1000
      end
      mean = latencies.sum / latencies.size
      puts "mean=#{mean.round(2)}ms (connect only)"
      @results[:socket_baseline][:tcp_drb] = mean
    rescue => e
      puts "FAILED: #{e.message}"
    end
  end

  # ============================================================
  # Redis Tests
  # ============================================================

  def run_redis_tests
    puts "\n" + "-" * 50
    puts "REDIS PERFORMANCE TESTS"
    puts "-" * 50

    available_servers = test_redis_connectivity
    return if available_servers.empty?

    available_servers.each do |server_key|
      run_redis_server_tests(server_key)
    end
  end

  def test_redis_connectivity
    available = []
    puts "\nTesting Redis server connectivity..."

    REDIS_SERVERS.each do |key, config|
      print "  #{config[:name]}: "

      # Skip if host is nil (e.g., WSL not available)
      if config[:skip_if_nil_host] && config[:host].nil?
        puts "SKIPPED (host not detected)"
        next
      end

      begin
        conn = create_redis_connection(config)
        start = Time.now
        conn.ping
        latency = ((Time.now - start) * 1000).round(2)
        conn.close
        puts "OK (#{latency}ms)"
        available << key
      rescue => e
        puts "FAILED (#{e.message})"
      end
    end

    available
  end

  def create_redis_connection(config)
    opts = {
      host: config[:host],
      port: config[:port],
      connect_timeout: 5,
      read_timeout: 5
    }
    opts[:password] = config[:password] if config[:password]
    opts[:ssl] = true if config[:ssl]
    Redis.new(**opts)
  end

  def create_redis_pool(config, size: 5)
    ConnectionPool.new(size: size, timeout: 5) do
      create_redis_connection(config)
    end
  end

  def run_redis_server_tests(server_key)
    config = REDIS_SERVERS[server_key]
    puts "\n  Testing #{config[:name].upcase}..."

    begin
      pool = create_redis_pool(config)
      sub = create_redis_connection(config)

      results_key = "redis_#{server_key}"
      @results[results_key] = {}

      # Warmup
      print "    Warming up... "
      @warmup_pings.times do
        pool.with { |c| c.ping }
      end
      puts "done"

      # Ping latency test
      @results[results_key][:ping] = test_redis_ping_latency(pool, config[:name])

      # Pub/Sub latency test
      @results[results_key][:pubsub] = test_redis_pubsub_latency(pool, sub, config[:name])

      # Registry (key-value) test
      @results[results_key][:registry] = test_redis_registry(pool, config[:name])

      # Throughput test
      @results[results_key][:throughput] = test_redis_throughput(pool, sub, config[:name])

      pool.shutdown { |c| c.close }
      sub.close
    rescue => e
      puts "    ERROR: #{e.message}"
      @results["redis_#{server_key}"] = { error: e.message }
    end
  end

  def test_redis_ping_latency(pool, server_name)
    print "    Ping latency (#{@ping_iterations}x)... "
    latencies = []

    @ping_iterations.times do
      start = Time.now
      pool.with { |c| c.ping }
      latencies << (Time.now - start) * 1000
    end

    stats = calculate_stats(latencies)
    puts "mean=#{stats[:mean].round(2)}ms, p95=#{stats[:p95].round(2)}ms"
    stats
  end

  def test_redis_pubsub_latency(pool, sub, server_name)
    print "    Pub/Sub round-trip (#{@ping_iterations}x)... "

    channel = "perf_test_#{SecureRandom.hex(4)}"
    latencies = []
    received = Queue.new

    # Start subscriber in background
    sub_thread = Thread.new do
      sub.subscribe(channel) do |on|
        on.message do |ch, msg|
          received << [Time.now, msg]
        end
      end
    end

    sleep 0.5  # Let subscriber connect

    @ping_iterations.times do |i|
      msg = { id: i, sent_at: Time.now.to_f }.to_json
      start = Time.now
      pool.with { |c| c.publish(channel, msg) }

      begin
        recv_time, recv_msg = received.pop(timeout: 5)
        latencies << (recv_time - start) * 1000
      rescue ThreadError
        # Timeout
      end
    end

    # Cleanup
    pool.with { |c| c.publish(channel, "STOP") }
    sleep 0.1
    sub_thread.kill rescue nil

    stats = calculate_stats(latencies)
    puts "mean=#{stats[:mean].round(2)}ms, p95=#{stats[:p95].round(2)}ms (#{latencies.size}/#{@ping_iterations} received)"
    stats.merge(received_count: latencies.size, sent_count: @ping_iterations)
  end

  def test_redis_registry(pool, server_name)
    print "    Registry ops (#{@registry_iterations}x)... "
    namespace = "perf_test_#{SecureRandom.hex(4)}"

    set_times = []
    get_times = []

    @registry_iterations.times do |i|
      key = "key_#{i}"
      value = { data: "x" * 100, num: i }

      start = Time.now
      pool.with { |c| c.set("#{namespace}.#{key}", value.to_json) }
      set_times << (Time.now - start) * 1000

      start = Time.now
      pool.with { |c| c.get("#{namespace}.#{key}") }
      get_times << (Time.now - start) * 1000
    end

    # Cleanup
    @registry_iterations.times do |i|
      pool.with { |c| c.del("#{namespace}.key_#{i}") }
    end

    set_stats = calculate_stats(set_times)
    get_stats = calculate_stats(get_times)

    puts "SET mean=#{set_stats[:mean].round(2)}ms, GET mean=#{get_stats[:mean].round(2)}ms"
    { set: set_stats, get: get_stats }
  end

  def test_redis_throughput(pool, sub, server_name)
    print "    Throughput (#{@throughput_messages} msgs)... "

    channel = "throughput_test_#{SecureRandom.hex(4)}"
    received_count = 0
    mutex = Mutex.new

    # Start subscriber
    sub_thread = Thread.new do
      sub.subscribe(channel) do |on|
        on.message do |ch, msg|
          if msg == "STOP"
            sub.unsubscribe
          else
            mutex.synchronize { received_count += 1 }
          end
        end
      end
    end

    sleep 0.5

    # Send messages as fast as possible
    payload = { data: "x" * 100 }.to_json
    start = Time.now

    @throughput_messages.times do |i|
      pool.with { |c| c.publish(channel, payload) }
    end

    send_time = Time.now - start

    # Wait for messages to be received
    sleep 1
    pool.with { |c| c.publish(channel, "STOP") }
    sleep 0.5
    sub_thread.kill rescue nil

    final_received = mutex.synchronize { received_count }
    throughput = final_received / send_time

    puts "#{throughput.round(0)} msg/sec (#{final_received}/#{@throughput_messages} received in #{send_time.round(3)}s)"

    {
      messages_sent: @throughput_messages,
      messages_received: final_received,
      send_duration: send_time,
      throughput: throughput.round(2)
    }
  end

  # ============================================================
  # DRb Tests
  # ============================================================

  def run_drb_tests
    puts "\n" + "-" * 50
    puts "DRB PERFORMANCE TESTS"
    puts "-" * 50

    available_servers = test_drb_connectivity
    return if available_servers.empty?

    available_servers.each do |server_key|
      run_drb_server_tests(server_key)
    end
  end

  def test_drb_connectivity
    available = []
    puts "\nTesting DRb server connectivity..."

    DRB_SERVERS.each do |key, config|
      print "  #{config[:name]}: "
      begin
        DRb.start_service unless DRb.current_server rescue nil
        broker = DRbObject.new_with_uri(config[:uri])
        start = Time.now
        clients = broker.connected_clients
        latency = ((Time.now - start) * 1000).round(2)
        puts "OK (#{latency}ms, #{clients.size} clients connected)"
        available << key
      rescue => e
        puts "FAILED (#{e.message})"
      end
    end

    available
  end

  # DRb callback receiver for message testing
  class DRbTestCallback
    include DRb::DRbUndumped

    def initialize
      @messages = Queue.new
      @mutex = Mutex.new
    end

    def receive_message(type, channel, from, payload)
      @messages << { type: type, channel: channel, from: from, payload: payload, received_at: Time.now }
    end

    def receive_request(channel, from, payload, uuid)
      # Echo back immediately for latency testing
      @messages << { type: :request, channel: channel, from: from, uuid: uuid, received_at: Time.now }
    end

    def receive_response(uuid, payload)
      @messages << { type: :response, uuid: uuid, payload: payload, received_at: Time.now }
    end

    def pop_message(timeout: 5)
      @messages.pop(timeout: timeout)
    rescue ThreadError
      nil
    end

    def clear
      @messages.clear
    end

    def message_count
      @messages.size
    end
  end

  def run_drb_server_tests(server_key)
    config = DRB_SERVERS[server_key]
    puts "\n  Testing #{config[:name].upcase}..."

    begin
      # Start DRb service first (allows callbacks to be remotely callable)
      DRb.start_service("druby://localhost:0") rescue nil
      local_port = DRb.uri.split(':').last.to_i

      broker = DRbObject.new_with_uri(config[:uri])

      # Create TWO clients: sender and receiver
      # This is needed because broadcasts skip the sender
      sender_callback = DRbTestCallback.new
      receiver_callback = DRbTestCallback.new

      sender_name = "PerfTest_Sender_#{SecureRandom.hex(4)}"
      receiver_name = "PerfTest_Receiver_#{SecureRandom.hex(4)}"

      # Both callbacks have DRbUndumped, so they're callable via the running DRb service
      broker.register_client(sender_name, sender_callback, local_port)
      broker.register_client(receiver_name, receiver_callback, local_port)

      results_key = "drb_#{server_key}"
      @results[results_key] = {}

      # Warmup
      print "    Warming up... "
      @warmup_pings.times { broker.connected_clients }
      puts "done"

      # Method call latency test (basic RPC)
      @results[results_key][:call] = test_drb_call_latency(broker, config[:name])

      # Message round-trip test - sender broadcasts, receiver gets it
      @results[results_key][:message] = test_drb_message_latency(broker, receiver_callback, sender_name, config[:name])

      # Registry test
      @results[results_key][:registry] = test_drb_registry(broker, config[:name])

      # Throughput test - sender broadcasts, receiver counts
      @results[results_key][:throughput] = test_drb_throughput(broker, receiver_callback, sender_name, config[:name])

      # Cleanup
      broker.unregister_client(sender_name) rescue nil
      broker.unregister_client(receiver_name) rescue nil

    rescue => e
      puts "    ERROR: #{e.message}"
      puts e.backtrace.first(3).join("\n") if @debug
      @results["drb_#{server_key}"] = { error: e.message }
    end
  end

  def test_drb_call_latency(broker, server_name)
    print "    Method call latency (#{@ping_iterations}x)... "
    latencies = []

    @ping_iterations.times do
      start = Time.now
      broker.connected_clients
      latencies << (Time.now - start) * 1000
    end

    stats = calculate_stats(latencies)
    puts "mean=#{stats[:mean].round(2)}ms, p95=#{stats[:p95].round(2)}ms"
    stats
  end

  def test_drb_message_latency(broker, callback, client_name, server_name)
    print "    Message round-trip (#{@ping_iterations}x)... "
    latencies = []
    callback.clear

    @ping_iterations.times do |i|
      start = Time.now
      # Broadcast a message that will come back to us
      broker.broadcast(client_name, :ping_test, { seq: i, sent_at: start.to_f })

      # Wait for it to arrive
      msg = callback.pop_message(timeout: 5)
      if msg
        latencies << (Time.now - start) * 1000
      end
    end

    stats = calculate_stats(latencies)
    success_rate = (latencies.size.to_f / @ping_iterations * 100).round(1)
    puts "mean=#{stats[:mean].round(2)}ms, p95=#{stats[:p95].round(2)}ms (#{success_rate}% received)"
    stats.merge(received_count: latencies.size, sent_count: @ping_iterations)
  end

  def test_drb_throughput(broker, callback, client_name, server_name)
    print "    Throughput (#{@throughput_messages} msgs)... "
    callback.clear

    payload = { data: "x" * 100 }
    start = Time.now

    @throughput_messages.times do |i|
      broker.broadcast(client_name, :throughput_test, payload)
    end

    send_time = Time.now - start

    # Wait for messages to arrive
    sleep 1

    received = 0
    while callback.pop_message(timeout: 0.01)
      received += 1
    end

    throughput = received / send_time

    puts "#{throughput.round(0)} msg/sec (#{received}/#{@throughput_messages} received in #{send_time.round(3)}s)"

    {
      messages_sent: @throughput_messages,
      messages_received: received,
      send_duration: send_time,
      throughput: throughput.round(2)
    }
  end

  def test_drb_registry(broker, server_name)
    print "    Registry ops (#{@registry_iterations}x)... "
    namespace = "perf_test_#{SecureRandom.hex(4)}"

    set_times = []
    get_times = []

    @registry_iterations.times do |i|
      key = "key_#{i}"
      value = { data: "x" * 100, num: i }

      start = Time.now
      broker.registry_put(namespace, key, value)
      set_times << (Time.now - start) * 1000

      start = Time.now
      broker.registry_get(namespace, key)
      get_times << (Time.now - start) * 1000
    end

    # Cleanup
    @registry_iterations.times do |i|
      broker.registry_delete(namespace, "key_#{i}")
    end

    set_stats = calculate_stats(set_times)
    get_stats = calculate_stats(get_times)

    puts "SET mean=#{set_stats[:mean].round(2)}ms, GET mean=#{get_stats[:mean].round(2)}ms"
    { set: set_stats, get: get_stats }
  end

  # ============================================================
  # Analysis & Reporting
  # ============================================================

  def calculate_stats(values)
    return { mean: 0, min: 0, max: 0, p50: 0, p95: 0, p99: 0 } if values.empty?

    sorted = values.sort
    len = sorted.length

    {
      mean: values.sum / len.to_f,
      min: sorted.first,
      max: sorted.last,
      p50: sorted[(len * 0.5).to_i],
      p95: sorted[(len * 0.95).to_i] || sorted.last,
      p99: sorted[(len * 0.99).to_i] || sorted.last,
      stddev: Math.sqrt(values.map { |v| (v - values.sum / len.to_f) ** 2 }.sum / len)
    }
  end

  def generate_comparison_report
    puts "\n" + "=" * 70
    puts "PERFORMANCE COMPARISON REPORT"
    puts "=" * 70

    # Redis server comparison
    redis_results = @results.select { |k, _| k.to_s.start_with?("redis_") }
    if redis_results.size > 1
      puts "\n[REDIS SERVER COMPARISON]"
      puts "-" * 50

      puts "\n  Ping Latency (ms):"
      puts "  %-15s %10s %10s %10s" % ["Server", "Mean", "P95", "P99"]
      redis_results.each do |key, data|
        next if data[:error] || !data[:ping]
        name = key.to_s.sub("redis_", "")
        puts "  %-15s %10.2f %10.2f %10.2f" % [name, data[:ping][:mean], data[:ping][:p95], data[:ping][:p99]]
      end

      puts "\n  Pub/Sub Latency (ms):"
      puts "  %-15s %10s %10s %10s %10s" % ["Server", "Mean", "P95", "Success%", ""]
      redis_results.each do |key, data|
        next if data[:error] || !data[:pubsub]
        name = key.to_s.sub("redis_", "")
        success = (data[:pubsub][:received_count].to_f / data[:pubsub][:sent_count] * 100).round(1)
        puts "  %-15s %10.2f %10.2f %10.1f%%" % [name, data[:pubsub][:mean], data[:pubsub][:p95], success]
      end

      puts "\n  Throughput (msg/sec):"
      puts "  %-15s %12s %12s" % ["Server", "Throughput", "Received%"]
      redis_results.each do |key, data|
        next if data[:error] || !data[:throughput]
        name = key.to_s.sub("redis_", "")
        recv_pct = (data[:throughput][:messages_received].to_f / data[:throughput][:messages_sent] * 100).round(1)
        puts "  %-15s %12.0f %11.1f%%" % [name, data[:throughput][:throughput], recv_pct]
      end

      puts "\n  Registry Operations (ms):"
      puts "  %-15s %10s %10s" % ["Server", "SET Mean", "GET Mean"]
      redis_results.each do |key, data|
        next if data[:error] || !data[:registry]
        name = key.to_s.sub("redis_", "")
        puts "  %-15s %10.2f %10.2f" % [name, data[:registry][:set][:mean], data[:registry][:get][:mean]]
      end
    end

    # Redis vs DRb comparison
    redis_local = @results[:redis_local]
    drb_local = @results[:drb_local]

    if redis_local && drb_local && !redis_local[:error] && !drb_local[:error]
      puts "\n[REDIS vs DRB COMPARISON (Local)]"
      puts "-" * 50

      puts "\n  Operation Latency (ms):"
      puts "  %-20s %12s %12s %12s" % ["Operation", "Redis", "DRb", "Difference"]

      if redis_local[:ping] && drb_local[:call]
        redis_val = redis_local[:ping][:mean]
        drb_val = drb_local[:call][:mean]
        diff = ((drb_val - redis_val) / redis_val * 100).round(1)
        puts "  %-20s %12.2f %12.2f %+11.1f%%" % ["Ping/Call", redis_val, drb_val, diff]
      end

      if redis_local[:registry] && drb_local[:registry]
        redis_set = redis_local[:registry][:set][:mean]
        drb_set = drb_local[:registry][:set][:mean]
        diff = ((drb_set - redis_set) / redis_set * 100).round(1)
        puts "  %-20s %12.2f %12.2f %+11.1f%%" % ["Registry SET", redis_set, drb_set, diff]

        redis_get = redis_local[:registry][:get][:mean]
        drb_get = drb_local[:registry][:get][:mean]
        diff = ((drb_get - redis_get) / redis_get * 100).round(1)
        puts "  %-20s %12.2f %12.2f %+11.1f%%" % ["Registry GET", redis_get, drb_get, diff]
      end
    end

    # Local vs Remote comparison
    if redis_local && !redis_local[:error]
      remote_results = redis_results.reject { |k, _| k == :redis_local }
      best_remote = remote_results.min_by { |_, v| v[:ping]&.dig(:mean) || Float::INFINITY }

      if best_remote && !best_remote[1][:error] && best_remote[1][:ping]
        puts "\n[LOCAL vs REMOTE COMPARISON]"
        puts "-" * 50
        puts "  Best remote server: #{best_remote[0].to_s.sub('redis_', '')}"

        local_ping = redis_local[:ping][:mean]
        remote_ping = best_remote[1][:ping][:mean]
        puts "\n  Latency overhead: #{(remote_ping - local_ping).round(2)}ms (+#{((remote_ping / local_ping - 1) * 100).round(0)}%)"

        if redis_local[:throughput] && best_remote[1][:throughput]
          local_tp = redis_local[:throughput][:throughput]
          remote_tp = best_remote[1][:throughput][:throughput]
          puts "  Throughput reduction: #{((1 - remote_tp / local_tp) * 100).round(0)}%"
        end
      end
    end
  end

  def save_results
    filename = "cluster_real_performance_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json"
    File.write(filename, JSON.pretty_generate(@results))
    puts "\n Results saved to #{filename}"
  end
end

# ============================================================
# Main
# ============================================================

if __FILE__ == $0
  options = {
    debug: ARGV.include?('--debug'),
    quick: ARGV.include?('--quick')
  }

  if ARGV.include?('redis')
    options[:type] = 'redis'
  elsif ARGV.include?('drb')
    options[:type] = 'drb'
  end

  test = RealPerformanceTest.new(options)
  test.run_all
end
