require 'rubygems'
require 'json'

module Scout
  class Streamer < Scout::ServerBase
    MAX_DURATION = 60*30 # will shut down automatically after this many seconds
    SLEEP = 1

    # * history_file is the *path* to the history file
    # * plugin_ids is an array of integers
    def initialize(server, client_key, history_file, plugin_ids, streaming_key, logger = nil)
      @server       = server
      @client_key   = client_key
      @history_file = history_file
      @history      = Hash.new
      @logger       = logger

      @plugins = []

      Pusher.app_id = '11495'
      Pusher.key = 'a95aa7293cd158100246'
      Pusher.secret = '9c13ccfe325fe3ae682d'

      debug "plugin_ids = #{plugin_ids.inspect}"
      debug "streaming_key = #{streaming_key}"

      streamer_start_time = Time.now

      hostname=Socket.gethostname
      # load history
      load_history

      # get the array of plugins, AKA the plugin plan
      @plugin_plan = Array(@history["old_plugins"])

      # iterate through the plan and compile each plugin. We only compile plugins once at the beginning of the run
      @plugin_plan.each do |plugin|
        begin
          compile_plugin(plugin) # this is what adds to the @plugin array
        rescue Exception
          error("Encountered an error: #{$!.message}")
          puts $!.backtrace.join('\n')
        end
      end

      # main loop. Continue running until global $continue_streaming is set to false OR we've been running for MAX DURATION
      while(streamer_start_time+MAX_DURATION > Time.now && $continue_streaming) do
        plugins=[]

        @plugins.each_with_index do |plugin,i|
          # ignore plugins whose ids are not in the plugin_ids array
          next if !(@plugin_plan[i]['id'] && plugin_ids.include?(@plugin_plan[i]['id'].to_i))
          start_time=Time.now
          plugin.reset!
          plugin.run
          duration=((Time.now-start_time)*1000).to_i

          plugins << {:duration=>duration,
                     :fields=>plugin.reports.inject{|memo,hash|memo.merge(hash)},
                     :name=>@plugin_plan[i]["name"],
                     :id=>@plugin_plan[i]["id"]}
        end

        bundle={:hostname=>hostname,
                 :server_time=>Time.now.strftime("%I:%M:%S %p"),
                 :num_processes=>`ps -e | wc -l`.chomp.to_i,
                 :plugins=>plugins }


        if true
          begin
            Pusher[streaming_key].trigger!('server_data', bundle)
          rescue Pusher::Error => e
            # (Pusher::AuthenticationError, Pusher::HTTPError, or Pusher::Error)
            puts "Error!!! #{e.message}"
          end
          #post_bundle(bundle)
        else
          # debugging
          File.open(File.join(File.dirname(@history_file),"out.txt"),"w") do |f|
            f.puts "... sleeping @ #{Time.now.strftime("%I:%M:%S %p")}..."
            f.puts bundle.to_yaml
          end
        end

        sleep(SLEEP)
      end
    end

    
    private

    #def post_bundle(bundle)
    #  post( urlify(:stream),
    #        "Unable to stream to server.",
    #        bundle.to_json,
    #        "Content-Type"     => "application/json")
    #rescue Exception
    #  error "Unable to stream to server."
    #  debug $!.class.to_s
    #  debug $!.message
    #  debug $!.backtrace.join("\n")
    #end

    # sets up the @plugins array
    def compile_plugin(plugin)
      # todo: account for local plugins - they need to be loaded from their file
      code_to_run=plugin['code'] || ""
      if ["class MPstat","class ApacheLoad"].any?{|snippit| code_to_run.include?(snippit) }
        code_to_run="class DummyPlugin < Scout::Plugin;def build_report;end;end"
        plugin['name']=plugin['name']+" (disabled)"
      end
      id_and_name = "#{plugin['id']}-#{plugin['name']}".sub(/\A-/, "")
      plugin_id = plugin['id']
      last_run    = @history["last_runs"][id_and_name] ||
                    @history["last_runs"][plugin['name']]
      memory      = @history["memory"][id_and_name] ||
                    @history["memory"][plugin['name']]
      options=(plugin['options'] || Hash.new)
      options.merge!(:tuner_days=>"")
      begin
        eval( code_to_run,
              TOPLEVEL_BINDING,
              plugin['path'] || plugin['name'] )
        info "Plugin compiled. It's a #{Plugin.last_defined}. id = #{plugin_id}"
        @plugins << Plugin.last_defined.load(last_run, (memory || Hash.new), options)
        # turn RailsRequest#analyze method into a null-op -- we don't want summaries being generated
        if @plugins.last.class.name=="RailsRequests"
          p=@plugins.last
          def p.analyze; end
        end
      rescue Exception
        raise if $!.is_a? SystemExit
        error "Plugin would not compile: #{$!.message}"
        return
      end
    end


    def load_history
      if !File.exist?(@history_file) || File.zero?(@history_file)
        create_blank_history
      end
      debug "Loading history file..."
      contents=File.read(@history_file)
      begin
        @history = YAML.load(contents)
      rescue => e
        info "Couldn't parse the history file. Exiting"
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

    def growl(message)`growlnotify -m '#{message.gsub("'","\'")}'`;end

  end
end