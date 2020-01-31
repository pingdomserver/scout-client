require 'rubygems'
require 'json'
require 'pusher-client'

module Scout
  class PluginTimeoutError < RuntimeError; end
  class PusherError < StandardError; end
  class Streamer
    MAX_DURATION = 60*30 # will shut down automatically after this many seconds
    SLEEP = 1

    # * history_file is the *path* to the history file
    # * plugin_ids is an array of integers
    def initialize(history_file, streaming_key, chart_id, p_auth_url, p_app_id, p_key, p_user_id, plugin_ids, system_metric_collectors, hostname, http_proxy, logger = nil)
      @@continue_streaming = true
      @history_file = history_file
      @history      = Hash.new
      @logger       = logger
      @command_pipe = command_pipe_setup

      @streaming_key = "private-#{streaming_key}" # This variable name should be changed to reflect the fact that it is a private channel
      @system_metric_collectors = system_metric_collectors
      @hostname = hostname

      @plugin_hashes = []

      @pusher_auth_url = p_auth_url
      @chart_id = chart_id # Need to decide how to determine which chart id to auth against or use a new auth url for agents
      pusher_logger = ENV['SCOUT_PUSHER_DEBUG'].nil? ? Logger.new(nil) : @logger
      @pusher_socket = PusherClient::Socket.new(p_key, {
        :auth_method => data_channel_auth,
        :logger => pusher_logger,
        :encrypted => true,
        :http_proxy => http_proxy,
      })
      @pusher_socket.connect(true) # connect to pusher
      @pusher_socket.subscribe(@streaming_key, {:user_id => p_user_id}) # the user_id for the private channel sent with the pusher auth data

      @streamer_start_time = Time.now

      info("Streamer PID=#{$$} starting")

      # load plugin history
      load_history

      # get the array of plugins, AKA the plugin plan
      @all_plugins = Array(@history["old_plugins"])
      info("Starting streamer with key=#{streaming_key} and plugin_ids: #{plugin_ids.inspect}. System metric collectors: #{system_metric_collectors.inspect}. #{@history_file} includes plugin ids #{@all_plugins.map{|p|p['id']}.inspect}. http_proxy = #{http_proxy}")

      # @selected_plugins is subset of the @all_plugins -- those selected in plugin_ids
      @selected_plugins = compile_plugins(@all_plugins, plugin_ids)
    end

    def report_loop
      # main loop. Continue running until global $continue_streaming is set to false OR we've been running for MAX DURATION
      iteration=1 # use this to log the data at a couple points
      consecutive_pusher_errors = 0 # used to exit if we reach a certain number of consecutive pusher errors in this loop
      while(@streamer_start_time+MAX_DURATION > Time.now && @@continue_streaming) do
        info("Streaming iteration #{iteration}.")

        read_command_pipe

        pusher_error = false

        begin
          bundle = report
        rescue PusherError => e
          pusher_error = true
          error "Error pushing data: #{e.message}"
          bundle = 'pusher error'
        end

        if pusher_error
          consecutive_pusher_errors += 1
          if consecutive_pusher_errors >= 20
            info("Too many consecutive pusher errors. Exiting.")
            clean_exit(99)
          end
        else
          consecutive_pusher_errors = 0
        end

        if iteration == 2 || iteration == 100
          info "Run #{iteration} data dump:"
          info bundle.inspect
        end

        sleep(SLEEP)
        iteration+=1
      end

      clean_exit
    end

    def report
      plugins = gather_plugin_reports(@selected_plugins)

      system_metric_data = gather_system_metric_reports(@system_metric_collectors)

      bundle={:hostname=>@hostname,
               :server_time=>Time.now.strftime("%I:%M:%S %p"),
               :server_unixtime => Time.now.to_i,
               :num_processes=>`ps -e | wc -l`.chomp.to_i,
               :plugins=>plugins,
               :system_metrics => system_metric_data}

      # stream the data via pusherapp
      begin
        @pusher_socket.send_channel_event(@streaming_key, 'client-server_data', bundle)
      rescue Exception => e
        raise PusherError
      end

      bundle
    end

    private

    def command_pipe_setup
      if Environment.scoutd_child?
        begin
          IO.new(3, "r") # The read pipe of scoutd is passed in as fd 3
        rescue ArgumentError
          IO.new(7, "r") # Ruby >= 1.9.3 reserves FD 3 through 6 for internal use
        end
      else
        pipe_read, pipe_write = IO.pipe
        return pipe_read
      end
    end

    def data_channel_auth
      return Proc.new {|socket_id, channel|
        uri = URI.parse(@pusher_auth_url)
        #http = Scout::build_http(auth_url) # We should use scout's http object so we go through any proxies
        http = Net::HTTP.new(uri.host, uri.port)

        if uri.scheme == "https"
          http.use_ssl = true
          http.verify_mode = uri.host == "checkin.staging.server.pingdom.com" ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER
        end

        request = Net::HTTP::Post.new(uri.path)
        request.set_form_data({'id' => @chart_id, 'socket_id' => socket_id, 'channel_name' => channel.name, 'channel_user_data' => channel.user_data, 'response_auth_key_only' => true})
        response = http.request(request)
        response.body
      }
    end

    def clean_exit(exit_code = 0)
      info("Streamer PID=#{$$} ending.")
      # remove the pid file before exiting
      streamer_pid_file=File.join(File.dirname(@history_file),"scout_streamer.pid")
      File.unlink(streamer_pid_file) if File.exist?(streamer_pid_file)
      # TODO: leave pusher channels and disconnect the pusher client
      exit(exit_code)
    end

    def read_command_pipe
      msg = @command_pipe.read_nonblock(8192) rescue nil
      info("Received message from command pipe: #{msg}") if msg
      case msg
      when /^start,/
        tokens = msg.split(",")[7..-1] # Get the plugin ids and system metrics
        numerical_tokens = tokens.select { |token| token =~ /\A\d+\Z/ }
        system_metric_collectors = (tokens - numerical_tokens).map(&:to_sym)
        plugin_ids = numerical_tokens.map(&:to_i)
        info("Adding metrics - plugins: #{plugin_ids} - system_metrics: #{system_metric_collectors}")
        add_metrics(plugin_ids, system_metric_collectors)
        @streamer_start_time = Time.now
      when /^stop$/
        clean_exit
      end
    end

    def add_metrics(plugin_ids, system_metric_collectors)
      @selected_plugins += compile_plugins(@all_plugins, plugin_ids)
      @selected_plugins.uniq!
      @system_metric_collectors += system_metric_collectors
      @system_metric_collectors.uniq!
    end

    def gather_plugin_reports(selected_plugins)
      plugins = []
      selected_plugins.each_with_index do |plugin_hash, i|
        # create an actual instance of the plugin
        plugin = get_instance_of(plugin_hash)
        start_time = Time.now

        plugin_response = { :fields => {},
                             :name => plugin_hash['name'],
                             :id => plugin_hash['id'],
                             :class => plugin_hash['code_class'] }

        id_and_name = plugin_hash['id_and_name']

        if(failure_count(id_and_name) < 2)
          begin
            Timeout.timeout(3, PluginTimeoutError) do
              data = plugin.run
              plugin_response[:fields] = plugin.reports.inject { |memo, hash| memo.merge(hash) }

              @history["last_runs"][id_and_name] = start_time
              @history["memory"][id_and_name]    = data[:memory]
              mark_success(id_and_name)
            end
          rescue Timeout::Error, PluginTimeoutError # the plugin timed out on this run
            plugin_response[:message] = "took too long to run"
            mark_failure(id_and_name)
          end
        else # the plugin has timed out twice previously, don't continue to run
          plugin_response[:message] = "took too long to run"
        end

        plugin_response[:duration] = ((Time.now-start_time) * 1000).to_i

        plugins << plugin_response
      end
      plugins
    end

    def gather_system_metric_reports(system_metric_collectors)
      system_metric_data = {}
      all_collectors = { :disk           => ServerMetrics::Disk,
                         :cpu            => ServerMetrics::Cpu,
                         :memory         => ServerMetrics::Memory,
                         :network_device => ServerMetrics::Network,
                         :process        => ServerMetrics::Processes }

      realtime_collectors = all_collectors.select { |key, klass| system_metric_collectors.include?(key) }
      realtime_collectors.each do |key_klass|
        key = key_klass.first
        klass = key_klass.last
        begin
          collector_previous_run = @history[:server_metrics][key]
          collector = collector_previous_run.is_a?(Hash) ? klass.from_hash(collector_previous_run) : klass.new() # continue with last run, or just create new
          system_metric_data[key] = collector.run
          @history[:server_metrics][key] = collector.to_hash # store its state for next time
        rescue Exception => e
          raise if e.is_a?(SystemExit)
          error "Problem running server/#{key} metrics: #{e.message}: \n#{e.backtrace.join("\n")}"
        end
      end
      system_metric_data
    end

    # Compile instances of the plugins specified in the passed plugin_ids
    def compile_plugins(all_plugins,plugin_ids)
      num_classes_compiled=0
      selected_plugins=[]
      plugin_ids.each_with_index do |plugin_id,i|
        plugin=all_plugins.find{|p| p['id'] && p['id'].to_i == plugin_id}
        if plugin
          begin
            # take care of plugin overrides
            local_path = File.join(File.dirname(@history_file), "#{plugin_id}.rb")
            if File.exist?(local_path)
              code_to_run = File.read(local_path)
            else
              code_to_run=plugin['code'] || ""
            end

            code_class=Plugin.extract_code_class(code_to_run)

            # eval the plugin code if it's not already defined
            if !Object.const_defined?(code_class)
              eval(code_to_run, TOPLEVEL_BINDING, plugin['name'] )

              # turn certain methods into null-ops, so summaries aren't generated. Note that this is ad-hoc, and not future-proof.
              klass=Scout::Plugin.const_get(code_class)
              if code_class=="RailsRequests"
                klass.module_eval { def analyze;end; }
              end
              if code_class=="ApacheAnalyzer"
                klass.module_eval { def generate_log_analysis;end; }
              end
              info "#{i+1}) #{plugin['name']} (id=#{plugin_id}) - #{code_class} compiled."
              num_classes_compiled+=1
            else
              info "#{i+1}) #{plugin['name']} (id=#{plugin_id}) - #{code_class} was compiled previously."
            end
            # we'll use code_class and id_and name again
            plugin['code_class']=code_class
            plugin['id_and_name']= "#{plugin['id']}-#{plugin['name']}".sub(/\A-/, "")
            selected_plugins << plugin
          rescue Exception
            error("Encountered an error compiling: #{$!.message}")
            error $!.backtrace.join('\n')
          end
        else
          info("#{i+1}) plugin_id=#{plugin_id} specified in #{plugin_ids.inspect} but not found in #{@history_file}")
        end
      end

      info "Finished compilation. #{num_classes_compiled} plugin classes compiled for the #{plugin_ids.size} plugin(s) needed for streaming."
      return selected_plugins
    end

    # plugin is a hash of plugin data from the history file (id, name, code, etc).
    # This plugin returns an instantiated instance of the plugin
    def get_instance_of(plugin)

      id_and_name = plugin['id_and_name']
      last_run    = @history["last_runs"][id_and_name]
      memory      = @history["memory"][id_and_name]
      options=(plugin['options'] || Hash.new)
      options.merge!(:tuner_days=>"")

      # finally, return an instance of the plugin
      klass=Scout::Plugin.const_get(plugin['code_class'])
      return klass.load(last_run, (memory || Hash.new), options)
    end


    def load_history
      begin
        debug "Loading history file..."
        contents=File.read(@history_file)
        @history = YAML.load(contents)
      rescue
        info "Couldn't load or parse the history file at #{@history_file}. Exiting."
        exit(1)
      end
      info "History file loaded."
    end

    # Forward Logger methods to an active instance, when there is one.
    def method_missing(meth, *args, &block)
      if (Logger::SEV_LABEL - %w[ANY]).include? meth.to_s.upcase
        @logger.send(meth, *args, &block) unless @logger.nil?
      else
        super
      end
    end

    # class method is used to stop the running deamon
    def self.continue_streaming=(v)
      @@continue_streaming=v
    end

    def mark_success(id)
      @failing_plugins ||= Hash.new(0) # defaults values to 0
      @failing_plugins[id] = 0 # resets value to zero so only consecutive errors are recorded
    end

    def mark_failure(id)
      @failing_plugins ||= Hash.new(0) # defaults values to 0
      @failing_plugins[id] += 1
    end

    def failure_count(id)
      (@failing_plugins && @failing_plugins[id]).to_i # return zero if nil
    end
  end
end
