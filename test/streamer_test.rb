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
require 'mocha/setup'

class StreamerTest < Test::Unit::TestCase
  def test_reports_system_metrics
    stub_history_file
    plugin_ids_stub = []
    system_metric_collectors = [:disk]

    mock_pusher do
      streamer = Scout::Streamer.new(:history_file_stub, :streaming_key_stub, :pusher_app_id_stub, :pusher_key_stub, :pusher_secret_stub, plugin_ids_stub, system_metric_collectors, :hostname_stub, :http_proxy_stub)
    end

    response = Pusher::Channel.streamer_data.first
    assert_equal [:disk], response[:system_metrics].keys
  end

  private

  def stub_history_file
    File.stubs(:read).with(:history_file_stub).returns(YAML.dump({:server_metrics => {}}))
    File.stubs(:dirname).with(:history_file_stub).returns('tmp')
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
        $num_run_for_tests = $num_run_for_tests ? $num_run_for_tests+1 : 1
        @@streamer_data_temp ||= Array.new
        @@streamer_data_temp << data
        if $num_run_for_tests >= $num_runs_for_mock_pusher
          Scout::Streamer.continue_streaming=false
          $num_run_for_tests=nil
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
end
