ENV["RAILS_ENV"] = "test" if (ENV["RAILS_ENV"] != "diagnostics")

unless ENV["NO_COVERAGE_TEST"]
  begin
    require 'simplecov'
    require 'simplecov-rcov'
    class SimpleCov::Formatter::MergedFormatter
      def format(result)
        SimpleCov::Formatter::HTMLFormatter.new.format(result)
        SimpleCov::Formatter::RcovFormatter.new.format(result)
      end
    end
    SimpleCov.formatter = SimpleCov::Formatter::MergedFormatter
    SimpleCov.start do
      add_filter '/test/'
      add_filter 'initializers/secret_token'
    end
  rescue Exception => e
    $stderr.puts "SimpleCov unavailable (#{e}). Proceeding without."
  end
end

require File.expand_path('../../config/environment', __FILE__)
require 'rails/test_help'
require 'mocha/mini_test'

class ActiveSupport::TestCase
  # Setup all fixtures in test/fixtures/*.(yml|csv) for all tests in
  # alphabetical order.
  #
  # Note: You'll currently still have to declare fixtures explicitly
  # in integration tests -- they do not yet inherit this setting
  fixtures :all
  def use_token token_name
    auth = api_fixture('api_client_authorizations')[token_name.to_s]
    Thread.current[:arvados_api_token] = auth['api_token']
  end

  teardown do
    Thread.current[:arvados_api_token] = nil
    Thread.current[:user] = nil
    Thread.current[:reader_tokens] = nil
    # Diagnostics suite doesn't run a server, so there's no cache to clear.
    Rails.cache.clear unless (Rails.env == "diagnostics")
    # Restore configuration settings changed during tests
    $application_config.each do |k,v|
      if k.match /^[^.]*$/
        Rails.configuration.send (k + '='), v
      end
    end
  end
end

module ApiFixtureLoader
  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    @@api_fixtures = {}
    def api_fixture(name, *keys)
      # Returns the data structure from the named API server test fixture.
      @@api_fixtures[name] ||= \
      begin
        path = File.join(ApiServerForTests::ARV_API_SERVER_DIR,
                         'test', 'fixtures', "#{name}.yml")
        file = IO.read(path)
        trim_index = file.index('# Test Helper trims the rest of the file')
        file = file[0, trim_index] if trim_index
        YAML.load(file)
      end
      keys.inject(@@api_fixtures[name]) { |hash, key| hash[key] }
    end
  end
  def api_fixture(name, *keys)
    self.class.api_fixture(name, *keys)
  end

  def find_fixture(object_class, name)
    object_class.find(api_fixture(object_class.to_s.pluralize.underscore,
                                  name, "uuid"))
  end
end

class ActiveSupport::TestCase
  include ApiFixtureLoader
  def session_for api_client_auth_name
    {
      arvados_api_token: api_fixture('api_client_authorizations')[api_client_auth_name.to_s]['api_token']
    }
  end
  def json_response
    Oj.load(@response.body)
  end
end

class ApiServerForTests
  ARV_API_SERVER_DIR = File.expand_path('../../../../services/api', __FILE__)
  SERVER_PID_PATH = File.expand_path('tmp/pids/wbtest-server.pid', ARV_API_SERVER_DIR)
  WEBSOCKET_PID_PATH = File.expand_path('tmp/pids/wstest-server.pid', ARV_API_SERVER_DIR)
  @main_process_pid = $$

  def _system(*cmd)
    $stderr.puts "_system #{cmd.inspect}"
    Bundler.with_clean_env do
      if not system({'RAILS_ENV' => 'test', "ARVADOS_WEBSOCKETS" => (if @websocket then "ws-only" end)}, *cmd)
        raise RuntimeError, "#{cmd[0]} returned exit code #{$?.exitstatus}"
      end
    end
  end

  def make_ssl_cert
    unless File.exists? './self-signed.key'
      _system('openssl', 'req', '-new', '-x509', '-nodes',
              '-out', './self-signed.pem',
              '-keyout', './self-signed.key',
              '-days', '3650',
              '-subj', '/CN=localhost')
    end
  end

  def kill_server
    if (pid = find_server_pid)
      $stderr.puts "Sending TERM to API server, pid #{pid}"
      Process.kill 'TERM', pid
    end
  end

  def find_server_pid
    pid = nil
    begin
      pid = IO.read(if @websocket then WEBSOCKET_PID_PATH else SERVER_PID_PATH end).to_i
      $stderr.puts "API server is running, pid #{pid.inspect}"
    rescue Errno::ENOENT
    end
    return pid
  end

  def run(args=[])
    ::MiniTest.after_run do
      self.kill_server
    end

    @websocket = args.include?("--websockets")

    # Kill server left over from previous test run
    self.kill_server

    Capybara.javascript_driver = :poltergeist
    Dir.chdir(ARV_API_SERVER_DIR) do |apidir|
      ENV["NO_COVERAGE_TEST"] = "1"
      if @websocket
        _system('bundle', 'exec', 'passenger', 'start', '-d', '-p3333',
                '--pid-file', WEBSOCKET_PID_PATH)
      else
        make_ssl_cert
        _system('bundle', 'exec', 'rake', 'db:test:load')
        _system('bundle', 'exec', 'rake', 'db:fixtures:load')
        _system('bundle', 'exec', 'passenger', 'start', '-d', '-p3000',
                '--pid-file', SERVER_PID_PATH,
                '--ssl',
                '--ssl-certificate', 'self-signed.pem',
                '--ssl-certificate-key', 'self-signed.key')
      end
      timeout = Time.now.tv_sec + 10
      good_pid = false
      while (not good_pid) and (Time.now.tv_sec < timeout)
        sleep 0.2
        server_pid = find_server_pid
        good_pid = (server_pid and
                    (server_pid > 0) and
                    (Process.kill(0, server_pid) rescue false))
      end
      if not good_pid
        raise RuntimeError, "could not find API server Rails pid"
      end
    end
  end
end

class ActionController::TestCase
  setup do
    @counter = 0
  end

  def check_counter action
    @counter += 1
    if @counter == 2
      assert_equal 1, 2, "Multiple actions in functional test"
    end
  end

  [:get, :post, :put, :patch, :delete].each do |method|
    define_method method do |action, *args|
      check_counter action
      super action, *args
    end
  end
end

if ENV["RAILS_ENV"].eql? 'test'
  ApiServerForTests.new.run
  ApiServerForTests.new.run ["--websockets"]
end
