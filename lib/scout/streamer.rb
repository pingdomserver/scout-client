require 'rubygems'
require 'json'

module Scout
  class PluginTimeoutError < RuntimeError; end
  class Streamer
    MAX_DURATION = 60*30 # will shut down automatically after this many seconds
    SLEEP = 1

    # * history_file is the *path* to the history file
    # * plugin_ids is an array of integers
    def initialize(history_file, streaming_key, p_app_id, p_key, p_secret, plugin_ids, hostname, http_proxy, logger = nil)
      @@continue_streaming = true
      @history_file = history_file
      @history      = Hash.new
      @logger       = logger

      @plugin_hashes = []

      Pusher.app_id=p_app_id
      Pusher.key=p_key
      Pusher.secret=p_secret
      Pusher.http_proxy = http_proxy if http_proxy !=""

      #[[:app_id,p_app_id],[:key,p_key],[:secret,p_secret]].each { |p| Pusher.send p.first, p.last}

      streamer_start_time = Time.now

      info("Streamer PID=#{$$} starting")

      # load plugin history
      load_history

      # get the array of plugins, AKA the plugin plan
      @all_plugins = Array(@history["old_plugins"])
      info("Starting streamer with key=#{streaming_key} and plugin_ids: #{plugin_ids.inspect}. #{@history_file} includes plugin ids #{@all_plugins.map{|p|p['id']}.inspect}. http_proxy = #{http_proxy}")

      # selected_plugins is subset of the @all_plugins -- those selected in plugin_ids
      selected_plugins = compile_plugins(@all_plugins, plugin_ids)


      # main loop. Continue running until global $continue_streaming is set to false OR we've been running for MAX DURATION
      iteration=1 # use this to log the data at a couple points
      while(streamer_start_time+MAX_DURATION > Time.now && @@continue_streaming) do
        plugins=[]
        selected_plugins.each_with_index do |plugin_hash,i|
          # create an actual instance of the plugin
          plugin=get_instance_of(plugin_hash)

          start_time=Time.now

          data = {}
          begin
            Timeout.timeout(30, PluginTimeoutError) do
              data = plugin.run
            end
          rescue Timeout::Error, PluginTimeoutError
            error "Plugin took too long to run."
          end

          duration=((Time.now-start_time)*1000).to_i

          id_and_name = plugin_hash['id_and_name']
          @history["last_runs"][id_and_name] = start_time
          @history["memory"][id_and_name]    = data[:memory]

          plugins << {:duration=>duration,
                     :fields=>plugin.reports.inject{|memo,hash|memo.merge(hash)},
                     :name=>plugin_hash['name'],
                     :id=>plugin_hash['id'],
                     :class=>plugin_hash['code_class']}
        end

        bundle={:hostname=>hostname,
                 :server_time=>Time.now.strftime("%I:%M:%S %p"),
                 :server_unixtime => Time.now.to_i,
                 :num_processes=>`ps -e | wc -l`.chomp.to_i,
                 :plugins=>plugins }

        # stream the data via pusherapp
        begin
          Pusher[streaming_key].trigger!('server_data', bundle)
        rescue Pusher::Error => e
          # (Pusher::AuthenticationError, Pusher::HTTPError, or Pusher::Error)
          error "Error pushing data: #{e.message}"
        end

        if iteration == 2 || iteration == 100
          info "Run #{iteration} data dump:"
          info bundle.inspect
        end

        sleep(SLEEP)
        iteration+=1
      end

      info("Streamer PID=#{$$} ending.")

      # remove the pid file before exiting
      streamer_pid_file=File.join(File.dirname(history_file),"scout_streamer.pid")
      File.unlink(streamer_pid_file) if File.exist?(streamer_pid_file)
    end

    
    private

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

  end
end