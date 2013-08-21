# These are integration tests -- they require a local instance of the Scout server to run.
# If you only have the Scout Agent gem, these tests will not run successfully.
#
# Scout internal note: See documentation in scout_sinatra for running tests.
#
$VERBOSE=nil
require 'rubygems'

gem "activerecord", "=2.2.2" # quick fix for now for the agent tests to continue to run when the rails 2.3 gem is present
require "active_record"
require "json"          # the data format
require "erb"           # only for loading rails DB config for now
require "logger"
require 'newrelic_rpm'
require "pty"
require "expect"
require 'test/unit'
begin
  require 'pry'
rescue LoadError
  # not using pry
end
# must be loaded after 
$LOAD_PATH << File.expand_path( File.dirname(__FILE__) + '/../lib' )
$LOAD_PATH << File.expand_path( File.dirname(__FILE__) + '/..' )
require 'lib/scout'
require 'mocha'


SCOUT_PATH = '../scout'
SINATRA_PATH = '../scout_sinatra'
AGENT_DIR = File.expand_path( File.dirname(__FILE__) ) + '/working_dir/'
PATH_TO_DATA_FILE = File.join AGENT_DIR, 'history.yml'
AGENT_LOG = File.join AGENT_DIR, 'latest_run.log'
PLUGINS_PROPERTIES = File.join AGENT_DIR, 'plugins.properties'
PATH_TO_TEST_PLUGIN = File.expand_path( File.dirname(__FILE__) ) + '/plugins/temp_plugin.rb'


# This is a super simple shim to provide the two methods we use in delayed_job's API:
# some_ar_instance.delay.some_method, and some_ar_class.delay.some_class_method
class ActiveRecord::Base
  def delay; self; end
  def self.delay; self; end
end


class ScoutTest < Test::Unit::TestCase
  def setup
    load_fixtures :accounts, :notification_groups, :environments, :clients, :plugins, :subscriptions, :plugin_metas, :roles, :plugin_templates
    clear_tables :plugin_activities, :ar_descriptors, :summaries, :clients_roles
    clear_working_dir
    

    Client.update_all "last_checkin='#{5.days.ago.strftime('%Y-%m-%d %H:%M')}'"
    # ensures that fields are created
    # Plugin.update_all "converted_at = '#{5.days.ago.strftime('%Y-%m-%d %H:%M')}'"
    # clear out RRD files
    Dir.glob(SCOUT_PATH+'/test/rrdbs/*.rrd').each { |f| File.unlink(f) }
    @client=Client.find_by_key 'key', :include=>:plugins
    @plugin=@client.plugins.first
    # avoid client limit issues
    assert @client.account.subscription.update_attribute(:clients,100)

    # roles-related
    @roles_account = Account.find_by_name "beta"
    @db_role=@roles_account.roles.find_by_name("db")
    @app_role=@roles_account.roles.find_by_name("app")
    @hostname = `hostname`.chomp
  end

  def test_should_checkin_during_interactive_install
    Client.update_all "last_checkin=null"
    Scout::Command::Install.new({:server => 'http://localhost:4567', :history => PATH_TO_DATA_FILE},[@client.key]).run

    assert_in_delta Time.now.utc.to_i, @client.reload.last_ping.to_i, 100
    assert_in_delta Time.now.utc.to_i, @client.reload.last_checkin.to_i, 100
  end

  def test_prompts_the_user_for_a_key_if_none_is_provided
    PTY.spawn("bin/scout -s http://localhost:4567 -d #{PATH_TO_DATA_FILE} install ") do | stdin, stdout, pid |
      begin
        stdin.expect("Enter the Key:", 3) do |response|
          assert_not_nil response, "Agent didn't print prompt for server key"
          stdout.puts @client.key # feed the agent the key
          res=stdin.read.lstrip
        end
      rescue Errno::EIO
        # don't care
      end
    end
  end
  
  def test_should_run_first_time
    assert_nil @client.last_ping

    scout(@client.key)
    assert_in_delta Time.now.utc.to_i, @client.reload.last_ping.to_i, 100
    assert_in_delta Time.now.utc.to_i, @client.reload.last_checkin.to_i, 100

    assert_equal 'ping_key', history['directives']['ping_key']
  end

  def test_should_not_run_if_not_time_to_checkin
    # do an initial checkin...should work
    test_should_run_first_time
    
    prev_checkin = @client.reload.last_checkin
    sleep 2
    scout(@client.key)
    # assert_equal prev_checkin, @client.reload.last_checkin
  end

  def test_should_run_when_forced
    # do an initial checkin...should work
    test_should_run_first_time
    
    prev_checkin = @client.reload.last_checkin
    sleep 2
    clear_working_dir
    scout(@client.key,'-F')
    
    assert @client.reload.last_checkin > prev_checkin
  end


  # indirect way of assessing reuse: examining log
  def test_reuse_existing_plan
    test_should_run_first_time

    res=scout(@client.key)
    assert_match "Plan not modified",res
  end

  def test_should_write_log_on_checkin
    assert !File.exist?(AGENT_LOG)
    test_should_run_first_time
    assert File.exist?(AGENT_LOG)
  end

  def test_should_append_to_log_on_ping
    test_should_run_first_time
    assert File.exist?(AGENT_LOG)
    log_file_size=File.read(AGENT_LOG).size
    sleep 1
    scout(@client.key)
    assert File.read(AGENT_LOG).size > log_file_size, "log should be longer after ping"
  end
  
  def test_should_reset_history_on_key_change
    test_should_run_first_time
    data=YAML::load(File.read(PATH_TO_DATA_FILE))
    assert_equal @client.ping_key, data['directives']['ping_key']
    assert_equal @client.key, data['last_client_key']
    sleep 1
    exec_scout('INVALIDKEY')
    data=YAML::load(File.read(PATH_TO_DATA_FILE))
    assert_equal 'INVALIDKEY', data['last_client_key']
    assert_nil data['directives']
  end

  def test_should_use_name_option
    scout(@client.key,'--name=My New Server')
    assert_equal "My New Server", @client.reload.name
  end

  def test_should_not_change_name_when_not_provided
    name=@client.name
    scout(@client.key)
    assert_equal name, @client.reload.name
  end

  def test_should_get_plan_with_blank_history_file
   # Create a blank history file
   File.open(PATH_TO_DATA_FILE, 'w+') {|f| f.write('') }

   scout(@client.key)
   assert_in_delta Time.now.utc.to_i, @client.reload.last_ping.to_i, 100
   assert_in_delta Time.now.utc.to_i, @client.reload.last_checkin.to_i, 100
  end
  
  def test_should_generate_alert
    prev_alerts = Alert.count

    load_average = Plugin.find(1)

    # In the real world, the md5 is taken care of automatically, and private key signing takes place manually.
    # These extra steps are necessary because we have the Sinatra version of the models, not the Rails version.
    new_code="class MyPlugin < Scout::Plugin; def build_report; alert('yo'); end; end"
    load_average.meta.code = new_code
    load_average.meta.save
    load_average.signature=<<EOS
svVV4Qegk2KqqmiHW3ZzlAGFWZSVDPsWn6oCj6hLKWGEvupku7iltk8MLl9O
XIIzzCpkQ1M4izxiQKv+7V9+revh7WJQJDl4xdIL2laYBYRpjHr61YTjCnvw
/aJ1mx/dXHJ6JiYadrAHBIUty/387BAorytIINJppzVre5rWOKyI7ulpC423
3v+qY6ZcpzUCvxDTI82x13xNcAfN6HkTE7RUtwhkaeKmJChEIwhiShdBirTP
dDLxK2GuTGFCn5PWJWvbryQJIjI6CbLGwxq8D8FaOiq6FojfjtsDS3oyR/Vl
2EHBYcHwyZm6WcBypyXblUeqBfZLezfqF1QdYP76HA==
EOS
    load_average.code_md5_signature=Digest::MD5.hexdigest(new_code)
    load_average.save
    
    scout(@client.key,'-F')

    assert_in_delta Time.now.utc.to_i, @client.reload.last_checkin.to_i, 100
    assert_equal prev_alerts + 1, Alert.count
  end
  
  def test_should_generate_report
    prev_checkin = @client.reload.last_checkin
    scout(@client.key,'-F')
    assert_in_delta Time.now.utc.to_i, @client.reload.last_checkin.to_i, 100
    load_average = Plugin.find(1)
    assert_in_delta Time.now.utc.to_i, load_average.last_reported_at.to_i, 100
  end

  def test_should_set_config_path
    assert @client.config_path.blank?
    test_should_run_first_time
    @client.reload
    assert_equal AGENT_DIR, @client.config_path+"/"
  end

  def test_client_version_is_set
    assert_nil @client.last_ping
    @client.update_attribute(:version,nil)
    scout(@client.key)
    assert_equal Gem::Version.new(Scout::VERSION), @client.reload.version
  end

  def test_client_hostname_is_set
    assert_nil @client.hostname
    scout(@client.key)
    assert_equal `hostname`.chomp, @client.reload.hostname
  end


  def test_corrupt_history_file
    File.open(PATH_TO_DATA_FILE,"w") do |f|
      f.write <<-EOS
---
memory: {}
  497081-Nginx monitoring: {}
EOS

    end
    scout(@client.key)

    assert_in_delta Time.now.utc.to_i, @client.reload.last_checkin.to_i, 100, "should have checked in even though history file is corrupt"

    corrupt_history_path=File.join AGENT_DIR, 'history.corrupt'
    assert File.exist?(corrupt_history_path), "Should have backed up corrupted history file"
    File.delete(corrupt_history_path) # just cleanup
  end

  ####################
  ### Test-Related ###
  ####################
  def test_runs_in_test_mode
    code=<<-EOC
      class StarterPlugin < Scout::Plugin
        def build_report
          report(:answer=>42)
        end
      end
    EOC

    run_scout_test(code) do |res|
      assert ":fields=>{:answer=>42}", res
    end
  end


  def test_embedded_options_in_test_mode
    code=<<-EOC
      class StarterPlugin < Scout::Plugin
        OPTIONS=<<-EOS
          lunch:
            label: Lunch Time
            default: 12
        EOS
        def build_report
          report(:lunch_is_at => option(:lunch))
        end
      end
    EOC

    run_scout_test(code) do |res|
      assert_match ":fields=>{:lunch_is_at=>12}", res
    end
  end

  def test_command_line_options_in_test_mode
    code=<<-EOC
      class StarterPlugin < Scout::Plugin
        OPTIONS=<<-EOS
          lunch:
            label: Lunch Time
            default: 12
        EOS
        def build_report
          report(:lunch_is_at => option(:lunch))
        end
      end
    EOC

    run_scout_test(code, 'lunch=13') do |res|      
      assert_match ':fields=>{:lunch_is_at=>"13"', res 
    end
  end

  # Needed to ensure that malformed embedded options don't bork the agent in test mode
  def test_invalid_embedded_options_in_test_mode
    code=<<-EOC
      class StarterPlugin < Scout::Plugin
        OPTIONS=<<-EOS
          invalid yaml, oh noes!
        EOS

        def build_report
          report(:answer=>42)
        end
      end
    EOC
    run_scout_test(code) do |res|
      assert_match "Problem parsing option definition in the plugin code (ignoring and continuing)", res
      assert_match ":fields=>{:answer=>42}", res
    end
  end

  def test_plugin_properties

    code=<<-EOC
      class LookupTest < Scout::Plugin
        OPTIONS=<<-EOS
          foo:
            default: 0
        EOS
        def build_report
          report :foo_value=>option(:foo), :url_value=>option(:url)
        end
      end
    EOC

    run_scout_test(code, 'foo=13') do |res|
      assert_match ':foo_value=>"13"', res
    end

    properties=<<-EOS
# this is a properties file
myfoo=99
mybar=100
myurl=http://foo.com?foo=bar
    EOS

    properties_path=File.join(AGENT_DIR,"plugins.properties")
    File.open(properties_path,"w") {|f| f.write properties}

    run_scout_test(code, 'foo=lookup:myfoo url=lookup:myurl') do |res|
      puts res
      assert_match ':foo_value=>"99"', res
      assert_match ':url_value=>"http://foo.com?foo=bar"', res
    end

    #cleanup
    File.unlink(properties_path)
  end

  def test_plugin_override
    override_path=File.join(AGENT_DIR,"#{@plugin.id}.rb")
    code=<<-EOC
      class OverrideTest < Scout::Plugin
        def build_report; report(:foo=>99);end
      end
    EOC
    File.open(override_path,"w"){|f|f.write(code)}

    scout(@client.key)
    report=YAML.load(@plugin.reload.last_report_raw.to_yaml)
    assert report["foo"].is_a?(Array)
    assert_equal 99, report["foo"].first
    File.delete(override_path)
  end

  def test_local_plugin
    plugin_count=@client.plugins.count
    local_path=File.join(AGENT_DIR,"my_local_plugin.rb")
    code=<<-EOC
      class LocalPluginTest < Scout::Plugin
        def build_report; report(:answer=>42);end
      end
    EOC
    File.open(local_path,"w"){|f|f.write(code)}

    output=scout(@client.key)
    assert_equal plugin_count+1, @client.reload.plugins.count, "there should be one additional plugin records -- created from the local plugin"
    File.delete(local_path)
  end
  
  def test_do_not_run_local_plugins_if_not_a_scout_plugin
    plugin_count=@client.plugins.count
    local_path=File.join(AGENT_DIR,"my_ruby_script.rb")
    code=<<-EOC
      puts 'yo!!!!!!'
      `touch #{AGENT_DIR}/created_file.txt`
    EOC
    File.open(local_path,"w"){|f|f.write(code)}
    
    output=scout(@client.key)
    assert !File.exist?("#{AGENT_DIR}/created_file.txt")
    assert_equal plugin_count, @client.reload.plugins.count
    assert output =~ /doesn't look like a Scout::Plugin/
    File.delete(local_path)
  end

  # Streamer tests

  # includes two plugins of the same class
  def test_streamer_plugin_compilation
    mock_pusher do
      plugins=[]
      plugins << create_plugin(@client, "AclPlugin_1", PLUGIN_FIXTURES[:acl][:code], PLUGIN_FIXTURES[:acl][:sig])
      plugins << create_plugin(@client, "XYZ Plugin",  PLUGIN_FIXTURES[:xyz][:code], PLUGIN_FIXTURES[:xyz][:sig])
      plugins << create_plugin(@client, "AclPlugin_2", PLUGIN_FIXTURES[:acl][:code], PLUGIN_FIXTURES[:acl][:sig])

      scout(@client.key) # to write the initial history file. Sinatra MUST be running
      $continue_streaming = true # so the streamer will run once
      # for debugging, make last arg Logger.new(STDOUT)
      Scout::Streamer.new(PATH_TO_DATA_FILE,"bogus_streaming_key","a","b","c",[@client.plugins.first.id]+plugins.map(&:id),"blade",nil)
    end

    streams = Pusher::Channel.streamer_data  # set by the mock_pusher call
    assert streams.is_a?(Array)
    assert_equal 1, streams.size
    res=streams.first
    assert res.is_a?(Hash)
    assert res[:plugins].is_a?(Array)
    assert_equal 4, res[:plugins].size
    assert_equal 2, res[:plugins][0][:fields][:load]
    assert_equal 1, res[:plugins][1][:fields][:value]
    assert_equal 2, res[:plugins][2][:fields][:value]
    assert_equal 1, res[:plugins][3][:fields][:value]
  end

  # the local plugin shouldn't report
  def test_streamer_with_local_plugin
    local_path=File.join(AGENT_DIR,"my_local_plugin.rb")
    code=<<-EOC
      class LocalPluginTest < Scout::Plugin
        def build_report; report(:answer=>42);end
      end
    EOC
    File.open(local_path,"w"){|f|f.write(code)}
    exec_scout(@client.key)

    mock_pusher do
      $continue_streaming = true # so the streamer will run once
      # for debugging, make last arg Logger.new(STDOUT)
      Scout::Streamer.new(PATH_TO_DATA_FILE,"bogus_streaming_key","a","b","c",[@client.plugins.first.id],"blade",nil)
    end
    streams = Pusher::Channel.streamer_data  # set by the mock_pusher call
    assert streams.is_a?(Array)
    assert_equal 1, streams.size
    res=streams.first

    assert res.is_a?(Hash)
    assert res[:plugins].is_a?(Array)
    assert_equal 1, res[:plugins].size # this is NOT the local plugin, it's a regular plugin that's already there
    assert_equal 2, res[:plugins][0][:fields][:load]
  end


  # test streamer starting and stopping
  def test_streamer_process_management
    streamer_pid_file = File.join(AGENT_DIR, "scout_streamer.pid")
    File.unlink(streamer_pid_file) if File.exist?(streamer_pid_file)

    test_should_run_first_time

    assert !File.exist?(streamer_pid_file)

    assert @client.update_attribute(:streamer_command, "start,A0000000000123,a,b,c,1,3")
    exec_scout(@client.key)
    assert File.exist?(streamer_pid_file)
    process_id = File.read(streamer_pid_file).to_i
    assert process_running?(process_id)
    assert_nil @client.reload.streamer_command

    sleep 2
    assert @client.update_attribute(:streamer_command, "stop")
    exec_scout(@client.key)
    assert !File.exist?(streamer_pid_file)
    sleep 2 # give process time to shut down
    assert !process_running?(process_id)
    assert_nil @client.reload.streamer_command
  end

  # Unfortunately, the Scout::Streamer::MAX_DURATION needs to be set in another process,
  #   so even Scout::Streamer.const_set :MAX_DURATION, 0 doesn't work
  # The only way to test this is to 1) open up streamer.rb and change MAX_DURATION=0, 2) uncomment this test, 3, run this test
  #
  #def test_streamer_removes_process_id_after_shutting_down
  #  streamer_pid_file = File.join(AGENT_DIR, "scout_streamer.pid")
  #  File.unlink(streamer_pid_file) if File.exist?(streamer_pid_file)
  #  test_should_run_first_time
  #  assert !File.exist?(streamer_pid_file)
  #
  #  assert @client.update_attribute(:streamer_command, "start,A0000000000123,a,b,c,1,3")
  #  exec_scout(@client.key)
  #  assert File.exist?(streamer_pid_file)
  #  process_id = File.read(streamer_pid_file).to_i
  #  assert process_running?(process_id)
  #
  #  sleep 2
  #
  #  assert !process_running?(process_id)
  #  assert !File.exist?(streamer_pid_file)
  #end


  def test_streamer_with_memory
    mock_pusher(3) do
      plugin = create_plugin(@client, "memory plugin", PLUGIN_FIXTURES[:memory][:code], PLUGIN_FIXTURES[:memory][:sig])
      exec_scout(@client.key)
      #puts YAML.load(File.read(PATH_TO_DATA_FILE))['memory'].to_yaml
      # for debugging, make last arg Logger.new(STDOUT)
      Scout::Streamer.new(PATH_TO_DATA_FILE,"bogus_streaming_key","a","b","c",[plugin.id],"blade",nil)
    end

    streams = Pusher::Channel.streamer_data  # set by the mock_pusher call
    assert streams.is_a?(Array)
    assert_equal 3, streams.size
    res=streams.last
    assert_equal 3, res[:plugins][0][:fields][:v], "after the two streamer runs, this plugin should report v=3 -- it increments each run"
  end

  def test_new_plugin_instance_every_streamer_run
    mock_pusher(2) do
      plugin = create_plugin(@client, "caching plugin", PLUGIN_FIXTURES[:caching][:code], PLUGIN_FIXTURES[:caching][:sig])
      exec_scout(@client.key)
      # for debugging, make last arg Logger.new(STDOUT)
      Scout::Streamer.new(PATH_TO_DATA_FILE,"bogus_streaming_key","a","b","c",[plugin.id],"blade",nil)
    end

    streams = Pusher::Channel.streamer_data  # set by the mock_pusher call
    assert streams.is_a?(Array)
    assert_equal 2, streams.size

    # the plugin sets :v to be the current time, and caches it in a class variable. we're checking that they are NOT equal
    assert_in_delta Time.now.to_i, streams.last[:plugins][0][:fields][:v], 5, "should be within a few seconds of now"
    assert_in_delta Time.now.to_i, streams.first[:plugins][0][:fields][:v], 5, "should be within a few seconds of now"
    assert_not_equal streams.first[:plugins][0][:fields][:v], streams.last[:plugins][0][:fields][:v]
  end


  # Roles related

  def test_roles_enabled_account
    scout(@roles_account.key)
    client=@roles_account.clients.last
    assert_equal @hostname, client.hostname
    assert_equal 0, client.plugins.count, "the all servers role should have 0 plugins"
    assert_equal 1, client.roles.count
    assert_equal @roles_account.primary_role, client.roles.first
  end

  def test_specify_role
    scout(@roles_account.key, "-rapp")
    client=@roles_account.clients.last
    assert_equal @hostname, client.hostname
    assert_equal 2, client.plugins.count
    assert_equal 2, client.roles.count
  end

  def test_change_roles_on_existing_server
    # first checkin
    exec_scout(@roles_account.key, "-rapp")
    client=@roles_account.clients.last
    assert_equal @hostname, client.hostname
    assert_equal 2, client.roles.count
    assert_equal 2, client.plugins.count

    client.plugins.each do |plugin|
      assert @app_role.plugin_templates.include?(plugin.plugin_template), "#{plugin} should be included in the app role"
    end

    # second checkin - add a role
    exec_scout(@roles_account.key, "-rapp,db --force")
    client=@roles_account.clients.last
    assert_equal 3, client.roles.count
    assert_equal 4, client.plugins.count

    # 3rd checkin - remove a role
    exec_scout(@roles_account.key, "-rdb --force")
    client=@roles_account.clients.last
    assert_equal 2, client.roles.count
    assert_equal 2, client.plugins.count

    client.plugins.each do |plugin|
      assert @db_role.plugin_templates.include?(plugin.plugin_template), "#{plugin} should be included in the db role"
    end

  end

  def test_hostname_override
    hostname_override="app1.production.foobar.com"
    scout(@roles_account.key, "--hostname", hostname_override)
    client=@roles_account.clients.last
    assert_equal hostname_override, client.hostname
  end

  def test_environment_argument_with_new_client
    staging = @roles_account.environments.find_by_name("staging")
    scout(@roles_account.key, "--environment", staging.name)
    @client = @roles_account.clients.last
    assert_equal staging, @client.environment
  end

  def test_environment_argument_with_existing_client
    test_environment_argument_with_new_client
    File.unlink(File.join(AGENT_DIR,"scout_client_pid.txt")) # needed because the "scout" test method leaves the PID file around
    production = @roles_account.environments.find_by_name("production")
    scout(@roles_account.key, "--environment", production.name, "--force")
    @client.reload
    assert_equal production, @client.environment
  end

  def test_create_cron_script
    Scout::Environment.stubs(:rvm?).returns(true)
    Scout::Environment.stubs(:bundler?).returns(true)
    install = Scout::Command::Install.new({:history => PATH_TO_DATA_FILE},{})
    install.send(:create_cron_script, @client.key)
    cron_script = File.join(AGENT_DIR, 'scout_cron.sh')
    assert File.exist?(cron_script)
    assert File.executable?(cron_script)
    File.delete(cron_script)
  end

  def test_generate_rvm_bundler_cron_command
    Scout::Environment.stubs(:rvm?).returns(true)
    Scout::Environment.stubs(:bundler?).returns(true)
    install = Scout::Command::Install.new({},{})
    cron_command = install.send(:cron_command, @client.key)
    assert cron_command.include?('scout_cron.sh')
  end

  def test_generate_non_rvm_bundler_cron_command
    Scout::Environment.stubs(:rvm?).returns(false)
    Scout::Environment.stubs(:bundler?).returns(false)
    install = Scout::Command::Install.new({},{})
    cron_command = install.send(:cron_command, @client.key)
    assert_equal cron_command, "#{`which scout`.strip} #{@client.key}"
  end


  ######################
  ### Helper Methods ###
  ######################
  
  # Runs the scout executable with the given +key+ and +opts+ string (ex: '-F').
  def exec_scout(key, opts = nil, print_output=false)
    opts = "" unless opts
    cmd= "bin/scout #{key} -s http://localhost:4567 -d #{PATH_TO_DATA_FILE} #{opts} 2>&1"
    puts "command: #{cmd}" if print_output
    output=`#{cmd}`
    puts output if print_output
    output
  end
  
  # Runs the scout command with the given +key+ and options. Returns output from the latest run.
  # Example: scout(KEY,'-F', '-v', '-l', 'debug').
  # 
  # Notes:
  # * This runs Scout in the test process - it means exit handlers and spawning processes (for streaming) can't 
  #   be tested with this. Instead, use #exec_scout, which runs the executable. 
  # * It's preferred to use this method vs. #exec_scout when possible as exceptions are properly raised when running
  #   scout in the process, making debugging easier. 
  # * The option handling is different in this method vs. #exec_scout: it takes an Array of options as Scout::Command.dispatch
  #   uses ARGV.
  def scout(args, *opts)
    args = Array(args)
    args += ['-s','http://localhost:4567']
    args += ['-d', PATH_TO_DATA_FILE]
    args += opts if opts.any?
    # args += ['-v', '-l', 'debug'] # if you want to debug
    Scout::Command.dispatch(args)
    File.read(AGENT_LOG) if File.exist?(AGENT_LOG)
  end
  
  # Removes all files from the working directory. Needed as +at_exit+ isn't called when running the agent
  # in our test process via #scout.
  def clear_working_dir
    Dir.glob(AGENT_DIR+'/*').each { |f| File.unlink(f) }
  end

  # you can use this, but you have to create the plugin file and clean up afterwards.
  # Or, you can use the blog version below
  def scout_test(path_to_test_plugin, opts = String.new)
    `bin/scout test #{path_to_test_plugin} -d #{PATH_TO_DATA_FILE} #{opts} -v -ldebug`
  end

  # The preferred way to test the agent in test mode. This creates a plugin file with the code you provide,
  # runs the agent in test mode, and cleans up the file.
  def run_scout_test(code,opts=String.new)
    File.open(PATH_TO_TEST_PLUGIN,"w") do |file|
      file.write(code)
    end

    yield scout_test(PATH_TO_TEST_PLUGIN, opts)

    ensure
      File.unlink(PATH_TO_TEST_PLUGIN)
  end


  def history
    YAML.load(File.read(PATH_TO_DATA_FILE))
  end

  def process_running?(pid)
    begin
      Process.getpgid( pid )
      true
    rescue Errno::ESRCH
      false
    end
  end

  # Establishes AR connection
  def self.connect_ar
    # ActiveRecord configuration
    begin
      $LOAD_PATH << File.join(SCOUT_PATH,'app/models')
      # get an ActiveRecord connection
      db_config_path=File.join(SCOUT_PATH,'config/database.yml')
      db_config=YAML.load(ERB.new(File.read(db_config_path)).result)
      db_hash=db_config['test']
      # Store the full class name (including module namespace) in STI type column
      # For triggers - before, just the class name and not the module name was stored,resulting in errors in the Rails
      # app.
      ActiveRecord::Base.store_full_sti_class = true
      ActiveRecord::Base.establish_connection(db_hash)
      # scout models and local models
      require SCOUT_PATH + '/lib/enum.rb'
      require SINATRA_PATH + '/app/models/ar_models.rb'

      ActiveRecord::Base.default_timezone = :utc
      
      puts "Established connection to Scout database :-)"
      puts "  #{Account.count} accounts there (sanity check)"
    end
  end
  
  # ghetto fixture support
  def load_fixtures(*table_names)
    clear_tables(*table_names)
    table_names.each do |table_name|
      path = "#{SCOUT_PATH}/test/fixtures/#{table_name}.yml"
      model_name = ActiveSupport::Inflector.classify table_name
      model_class = ActiveRecord.const_get(model_name)

      data = YAML.load_file(path)
      data.each do |key, value_hash|
        model_instance = model_class.new
        model_instance.id = key.hash if !value_hash.has_key?(:id) # accounting for named foreign keys in fixtures, part 1
        value_hash.each_pair do |k,v|
          if model_instance.respond_to?(k+"_id") # accounting for named foreign keys in fixtures, part 2
            model_instance.send "#{k}_id=",v.hash
          else
            model_instance.send "#{k}=",v
          end
        end
        model_instance.save
      end
    end
  end

  def clear_tables(*tables)
    tables.each do |table|
      ActiveRecord::Base.connection.execute("truncate table #{table}")
    end    
  end

  # see scout's rake plugin:sign task to create the signature
  def create_plugin(client,name, code, signature)
    p=client.plugins.create(:name=>name)
    PluginMeta.create(:plugin=>p)
    p.reload.meta.code=code
    p.code_md5_signature=Digest::MD5.hexdigest(code)
    p.signature=signature
    p.save
    p.meta.save
    puts "There was a problem creating '#{name}' plugin: #{p.errors.inspect}" if p.errors.any?
    p
  end

  # this with a block to mock the pusher call. You can access the streamer data through the Pusher::Channel.streamer_data
  # Must be called with a code block
  def mock_pusher(num_runs=1)
    # redefine the trigger! method, so the streamer doesn't loop indefinitely. We can't just mock it, because
    # we need to set the $continue_streaming=false
    $num_runs_for_mock_pusher=num_runs
    Pusher::Channel.module_eval do
      alias orig_trigger! trigger!
      def self.streamer_data;@@streamer_data;end # for getting the data back out
      def trigger!(event_name, data, socket=nil)
        @num_run_for_tests = @num_run_for_tests ? @num_run_for_tests+1 : 1
        # puts "in mock pusher trigger! This is run #{@num_run_for_tests} of #{$num_runs_for_mock_pusher}"
        @@streamer_data_temp ||= Array.new
        @@streamer_data_temp << data
        if @num_run_for_tests >= $num_runs_for_mock_pusher
          Scout::Streamer.continue_streaming=false
          @num_run_for_tests=nil
          @@streamer_data = @@streamer_data_temp.clone
          @@streamer_data_temp = nil
        end
      end
    end
    yield # must be called with a block
    Pusher::Channel.module_eval do
      alias trigger! orig_trigger!
    end
  end


  # Use these to create plugins as needed
  PLUGIN_FIXTURES={
      :acl=>{:code=>"class AclPlugin < Scout::Plugin;def build_report; report(:value=>1);end;end",
             :sig=><<EOS
QT/IYlR+/3h0YwBAHJeFz4HRFlisocVGorafNYJSYJC5RaUKqxu3dM+bOU4P
mQ5SmAt1mtXD5BJy2MeHam7Y8HAiWJbDBB318feZrC6xI2amu1b1/YMUyY8y
fMXS9z8J+ABsFIyV26av1KLxU1EHxi9iKxPwMg0HKJhTBStX4uIyncr/+ZSS
QKywEwPIPihFFyh9B2Z5WVSHtGcZG9CXDa20hrbQoNutOTniTkr00evBItYL
FN4L0F0ApIjTTkZW2vjzNR59j8HfZ7zrPfy33VhJkyAS0o9nQt5v0J5wKHj1
c3egj/Ffn/zSWZ1cTf3VSpfrGKUAlyB9KphZeYv2Og==
EOS
      },
      :xyz=>{:code=>"class XYZPlugin < Scout::Plugin;def build_report; report(:value=>2);end;end",
             :sig=><<EOS
6cNcDCM2GWcoT1Iqri+XFPgAiMxQaf0b8kOi4KKafNVD94cPkcy6OknNeQUM
v6GYcfGCAsiZvnjl/2wsqjvrAl/zyuSW/s5YLsjxca1LEvhkyxbpnDGuj32k
3IuWKQ6JuEbmPXPP1aFsosOm7dbTCrjEn1fDQWAzmfCwznHV3MiqzvPD2D9g
7gtxXcblNP6hm7A6AlBzP0hwYORR//gpLLGtmT5ewltHUj9aSUY0GQle3lvH
/uzBDoV1x6mEYR2jPO5QQxL3BvTBvpC06ec8M/ZWbO9IwA7/DOs+vYfngxlp
jbtpAK9QCaAalKy/Z29os/7aViHy9z9IVCpC/z3MDA==
EOS
      },
      :memory=>{:code=>"class MemoryPlugin < Scout::Plugin;def build_report; v=memory(:v)||0; report(:v=>v);remember(:v,v+1);end;end",
                :sig=><<EOS
5GNahpevN9VW5f7rmo6Cfq+2TWp8pwukxbE5laAZtDea44KaNE9gSMfiNCqz
rLAHvNXITJi0uI1rm+HXrak6L5oGvSouivCPtPTq1jRBy4QX2Sk9+gNEtTa8
HXu5TIQLJ/+IYHIG2E5FWcbfddR8cmJkIl4zGs93IatQNTENksRzphob7Cz8
wBwOHDG78kJ4TWEV5NIa5rLW8y2ltthfEPCTnS8/Zxa6h0qFtNrUWiU2KKtp
xTbJ3RgWKUnAR3YrEGB/JjjkPN2FrsDRvlClGujaYIWpWGkf+GZcpUn+QYxP
w7/kFz29Ds4hJRg2E2cWCHPtrD4dI0p/1iwP4XsxOw==
EOS
      },
      :caching=>{:code=>"class CachingPlugin < Scout::Plugin;def build_report; @v||= Time.now.to_i; report(:v=>@v);end;end",
                 :sig=><<EOS
zcEUdxS9h/iD/xYK1SbvTn2mi0vJzfgIkmrouzXeRbEsbcKTdOhc3nOBwUH5
SEOvQnPKmTiN7qaRiDZJypB/ldKxG4PL8zI0kL5G3AUZcxJBfqWe82jCKpyY
I49DWaBW4tZWM3j5T64+60ifPlKVXQMLVIYQtPTpVDMnftzfokDbBYsEhB2e
gNnsaAL5Nar+JE2GqM7nh79IgfXOrrYLdsv4zUJfex/OrKJS53ZCRnDcvlXu
pKFiS6IF2dJkIFlnNlYaXK5ZSXGANGY80Ji4ivz077JpuogQzrVkqHk13A1G
dGvCQOmVn51PKtmDm5DbfZaw4j4w+1pO2+G9Qm1y+A==
EOS
      }
  } # end of PLUGIN_FIXTURES

end

# Connect to AR before running
ScoutTest::connect_ar

