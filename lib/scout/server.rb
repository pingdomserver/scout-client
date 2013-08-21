
Dir.glob(File.join(File.dirname(__FILE__), *%w[.. .. vendor *])).each do |dir|
  $LOAD_PATH << File.join(dir,"lib")
end

require "json"
require "pusher"

module Scout
  class Server < Scout::ServerBase
    # 
    # A plugin cannot take more than DEFAULT_PLUGIN_TIMEOUT seconds to execute, 
    # otherwise, a timeout error is generated.  This can be overriden by
    # individual plugins.
    # 
    DEFAULT_PLUGIN_TIMEOUT = 60
    #
    # A fuzzy range of seconds in which it is okay to rerun a plugin.
    # We consider the interval close enough at this point.
    # 
    RUN_DELTA = 30

    attr_reader :new_plan
    attr_reader :directives
    attr_reader :plugin_config
    attr_reader :streamer_command
    attr_reader :client_key

    # Creates a new Scout Server connection.
    def initialize(server, client_key, history_file, logger=nil, server_name=nil, http_proxy='', https_proxy='', roles='', hostname=nil, environment='')
      @server       = server
      @client_key   = client_key
      @history_file = history_file
      @history      = Hash.new
      @logger       = logger
      @server_name  = server_name
      @http_proxy   = http_proxy
      @https_proxy  = https_proxy
      @roles        = roles || ''
      @hostname     = hostname
      @environment  = environment
      @plugin_plan  = []
      @plugins_with_signature_errors = []
      @directives   = {} # take_snapshots, interval, sleep_interval
      @streamer_command = nil
      @new_plan     = false
      @local_plugin_path = File.dirname(history_file) # just put overrides and ad-hoc plugins in same directory as history file.
      @plugin_config_path = File.join(@local_plugin_path, "plugins.properties")
      @account_public_key_path = File.join(@local_plugin_path, "scout_rsa.pub")
      @history_tmp_file = history_file+'.tmp'
      @plugin_config = load_plugin_configs(@plugin_config_path)
      @data_file = Scout::DataFile.new(@history_file,@logger)
      # the block is only passed for install and test, since we split plan retrieval outside the lockfile for run
      if block_given?
        load_history
        yield self
        save_history
      end
    end

    def refresh?
      return true if !ping_key or account_public_key_changed? # fetch the plan again if the account key is modified/created

      url=URI.join( @server.sub("https://","http://"), "/clients/#{ping_key}/ping.scout?roles=#{@roles}&hostname=#{URI.encode(@hostname)}&env=#{URI.encode(@environment)}")

      headers = {"x-scout-tty" => ($stdin.tty? ? 'true' : 'false')}
      if @history["plan_last_modified"] and @history["old_plugins"]
        headers["If-Modified-Since"] = @history["plan_last_modified"]
      end
      get(url, "Could not ping #{url} for refresh info", headers) do |res|        
        @streamer_command = res["x-streamer-command"] # usually will be nil, but can be [start,abcd,1234,5678|stop]
        if res.is_a?(Net::HTTPNotModified)
          return false
        else
          info "Plan has been modified!"
          return true
        end
      end
    end


    #
    # Retrieves the Plugin Plan from the server. This is the list of plugins
    # to execute, along with all options.
    #
    # This method has a couple of side effects:
    # 1) it sets the @plugin_plan with either A) whatever is in history, B) the results of the /plan retrieval
    # 2) it sets @checkin_to = true IF so directed by the scout server
    def fetch_plan
      if refresh?

        url = urlify(:plan)
        info "Fetching plan from server at #{url}..."
        headers = {"x-scout-tty" => ($stdin.tty? ? 'true' : 'false')}
        headers["x-scout-roles"] = @roles

        get(url, "Could not retrieve plan from server.", headers) do |res|
          begin
            body = res.body
            if res["Content-Encoding"] == "gzip" and body and not body.empty?
              body = Zlib::GzipReader.new(StringIO.new(body)).read
            end
            body_as_hash = JSON.parse(body)
            
            temp_plugins=Array(body_as_hash["plugins"])
            temp_plugins.each_with_index do |plugin,i|
              signature=plugin['signature']
              id_and_name = "#{plugin['id']}-#{plugin['name']}".sub(/\A-/, "")
              if signature
                code=plugin['code'].gsub(/ +$/,'') # we strip trailing whitespace before calculating signatures. Same here.
                decoded_signature=Base64.decode64(signature)
                if !scout_public_key.verify(OpenSSL::Digest::SHA1.new, decoded_signature, code)
                  if account_public_key
                    if !account_public_key.verify(OpenSSL::Digest::SHA1.new, decoded_signature, code)
                      info "#{id_and_name} signature verification failed for both the Scout and account public keys"
                      plugin['sig_error'] = "The code signature failed verification against both the Scout and account public key. Please ensure the public key installed at #{@account_public_key_path} was generated with the same private key used to sign the plugin."
                      @plugins_with_signature_errors << temp_plugins.delete_at(i)
                    end
                  else
                    info "#{id_and_name} signature doesn't match!"
                    plugin['sig_error'] = "The code signature failed verification. Please place your account-specific public key at #{@account_public_key_path}."
                    @plugins_with_signature_errors << temp_plugins.delete_at(i)
                  end
                end
              # filename is set for local plugins. these don't have signatures.
              elsif plugin['filename']
                plugin['code']=nil # should not have any code.
              else
                info "#{id_and_name} has no signature!"
                plugin['sig_error'] = "The code has no signature and cannot be verified."
                @plugins_with_signature_errors << temp_plugins.delete_at(i)
              end
            end

            @plugin_plan = temp_plugins
            @directives = body_as_hash["directives"].is_a?(Hash) ? body_as_hash["directives"] : Hash.new
            @history["plan_last_modified"] = res["last-modified"]
            @history["old_plugins"]        = @plugin_plan
            @history["directives"]         = @directives

            info "Plan loaded.  (#{@plugin_plan.size} plugins:  " +
                 "#{@plugin_plan.map { |p| p['name'] }.join(', ')})" +
                 ". Directives: #{@directives.to_a.map{|a|  "#{a.first}:#{a.last}"}.join(", ")}"

            @new_plan = true # used in determination if we should checkin this time or not

            # Add local plugins to the plan.
            @plugin_plan += get_local_plugins
          rescue Exception =>e
            fatal "Plan from server was malformed: #{e.message} - #{e.backtrace}"
            exit
          end
        end
      else
        info "Plan not modified."
        @plugin_plan = Array(@history["old_plugins"])
        @plugin_plan += get_local_plugins
        @directives = @history["directives"] || Hash.new

      end
      @plugin_plan.reject! { |p| p['code'].nil? }
    end

    # returns an array of hashes representing local plugins found on the filesystem
    # The glob pattern requires that filenames begin with a letter,
    # which excludes plugin overrides (like 12345.rb)
    def get_local_plugins
      local_plugin_paths=Dir.glob(File.join(@local_plugin_path,"[a-zA-Z]*.rb"))
      local_plugin_paths.map do |plugin_path|
        name    = File.basename(plugin_path)
        options = if directives = @plugin_plan.find { |plugin| plugin['filename'] == name }
                     directives['options']
                  else 
                    nil
                  end
        begin
          plugin = {
            'name'            => name,
            'local_filename'  => name,
            'origin'          => 'LOCAL',
            'code'            => File.read(plugin_path),
            'interval'        => 0,
            'options'         => options
          }
          if !plugin['code'].include?('Scout::Plugin')
            info "Local Plugin [#{plugin_path}] doesn't look like a Scout::Plugin. Ignoring."
            nil
          else
            plugin
          end
        rescue => e
          info "Error trying to read local plugin: #{plugin_path} -- #{e.backtrace.join('\n')}"
          nil
        end
      end.compact
    end

    # To distribute pings across a longer timeframe, the agent will sleep for a given
    # amount of time. When using the --force option the sleep_interval is ignored.
    def sleep_interval
      (@history['directives'] || {})['sleep_interval'].to_f
    end

    def ping_key
      (@history['directives'] || {})['ping_key']
    end
    
    def client_key_changed?
      last_client_key=@history['last_client_key']
      # last_client_key will be nil on versions <= 5.5.7. when the agent runs after the upgrade, it will no longer 
      # be nil. don't want to aggressively reset the history file as it clears out memory values which may impact alerts.
      if last_client_key and client_key != last_client_key
        warn "The key associated with the history file has changed [#{last_client_key}] => [#{client_key}]."
        true
      else
        false
      end
    end
    
    # need to load the history file first to determine if the key changed. 
    # if it has, reset.
    def recreate_history_if_client_key_changed
      if client_key_changed?
        create_blank_history
        @history = YAML.load(File.read(@history_file))
      end
    end
    
    # Returns the Scout public key for code verification.
    def scout_public_key
      return @scout_public_key if instance_variables.include?('@scout_public_key')
      public_key_text = File.read(File.join( File.dirname(__FILE__), *%w[.. .. data code_id_rsa.pub] ))
      debug "Loaded scout-wide public key used for verifying code signatures (#{public_key_text.size} bytes)"
      @scout_public_key = OpenSSL::PKey::RSA.new(public_key_text)
    end
    
    # Returns the account-specific public key if installed. Otherwise, nil.
    def account_public_key
      return @account_public_key if instance_variables.include?('@account_public_key')
      @account_public_key = nil
      begin
        public_key_text = File.read(@account_public_key_path)
        debug "Loaded account public key used for verifying code signatures (#{public_key_text.size} bytes)"
        @account_public_key=OpenSSL::PKey::RSA.new(public_key_text)
      rescue Errno::ENOENT
        debug "No account private key provided"
      rescue
        info "Error loading account public key: #{$!.message}"
      end
      return @account_public_key
    end
    
    # This is called in +run_plugins_by_plan+. When the agent starts its next run, it checks to see
    # if the key has changed. If so, it forces a refresh.
    def store_account_public_key
      @history['account_public_key'] = account_public_key.to_s
    end
    
    def account_public_key_changed?
      @history['account_public_key'] != account_public_key.to_s
    end

    # uses values from history and current time to determine if we should checkin at this time
    def time_to_checkin?
      @history['last_checkin'] == nil ||
              @directives['interval'] == nil ||
              (Time.now.to_i - Time.at(@history['last_checkin']).to_i).abs+15+sleep_interval > @directives['interval'].to_i*60
    rescue
      debug "Failed to calculate time_to_checkin. @history['last_checkin']=#{@history['last_checkin']}. "+
              "@directives['interval']=#{@directives['interval']}. Time.now.to_i=#{Time.now.to_i}"
      return true
    end

    # uses values from history and current time to determine if we should ping the server at this time
    def time_to_ping?
      return true if
      @history['last_ping'] == nil ||
              @directives['ping_interval'] == nil ||
              (Time.now.to_i - Time.at(@history['last_ping']).to_i).abs+15 > @directives['ping_interval'].to_i*60
    rescue
      debug "Failed to calculate time_to_ping. @history['last_ping']=#{@history['last_ping']}. "+
              "@directives['ping_interval']=#{@directives['ping_interval']}. Time.now.to_i=#{Time.now.to_i}"
      return true
    end

    # returns a human-readable representation of the next checkin, i.e., 5min 30sec
    def next_checkin
      secs= @directives['interval'].to_i*60 - (Time.now.to_i - Time.at(@history['last_checkin']).to_i).abs
      minutes=(secs.to_f/60).floor
      secs=secs%60
      "#{minutes}min #{secs} sec"
    rescue
      "[next scout invocation]"
    end

    # Runs all plugins from the given plan. Calls process_plugin on each plugin.
    # @plugin_execution_plan is populated by calling fetch_plan
    def run_plugins_by_plan
      prepare_checkin
      @plugin_plan.each do |plugin|
        begin
          process_plugin(plugin)
        rescue Exception
          @checkin[:errors] << build_report(
            plugin,
            :subject => "Exception:  #{$!.message}.",
            :body    => $!.backtrace
          )
          error("Encountered an error: #{$!.message}")
          puts $!.backtrace.join('\n')
        end
      end
      take_snapshot if @directives['take_snapshots']
      process_signature_errors
      store_account_public_key
      checkin
    end
    
    # Reports errors if there are any plugins with invalid signatures and sets a flag
    # to force a fresh plan on the next run.
    def process_signature_errors
      return unless @plugins_with_signature_errors and @plugins_with_signature_errors.any?
      @plugins_with_signature_errors.each do |plugin|
        @checkin[:errors] << build_report(plugin,:subject => "Code Signature Error", :body => plugin['sig_error'])
      end
    end
    
    # 
    # This is the heart of Scout.  
    # 
    # First, it determines if a plugin is past interval and needs to be run.
    # If it is, it simply evals the code, compiling it.
    # It then loads the plugin and runs it with a PLUGIN_TIMEOUT time limit.
    # The plugin generates data, alerts, and errors. In addition, it will
    # set memory and last_run information in the history file.
    #
    # The plugin argument is a hash with keys: id, name, code, timeout, options, signature.
    def process_plugin(plugin)
      info "Processing the '#{plugin['name']}' plugin:"
      id_and_name = "#{plugin['id']}-#{plugin['name']}".sub(/\A-/, "")
      plugin_id = plugin['id']
      last_run    = @history["last_runs"][id_and_name] ||
                    @history["last_runs"][plugin['name']]
      memory      = @history["memory"][id_and_name] ||
                    @history["memory"][plugin['name']]
      run_time    = Time.now
      delta       = last_run.nil? ? nil : run_time -
                                          (last_run + plugin['interval'] * 60)
      if last_run.nil? or delta.between?(-RUN_DELTA, 0) or delta >= 0
        debug "Plugin is past interval and needs to be run.  " +
              "(last run:  #{last_run || 'nil'})"
        code_to_run = plugin['code']
        if plugin_id && plugin_id != ""
          override_path=File.join(@local_plugin_path, "#{plugin_id}.rb")
          # debug "Checking for local plugin override file at #{override_path}"
          if File.exist?(override_path)
            code_to_run = File.read(override_path)
            debug "Override file found - Using #{code_to_run.size} chars of code in #{override_path} for plugin id=#{plugin_id}"
            plugin['origin'] = "OVERRIDE"
          else
            plugin['origin'] = nil
          end
        end
        debug "Compiling plugin..."
        begin
          eval( code_to_run,
                TOPLEVEL_BINDING,
                plugin['path'] || plugin['name'] )
          info "Plugin compiled."
        rescue Exception
          raise if $!.is_a? SystemExit
          error "Plugin #{plugin['path'] || plugin['name']} would not compile: #{$!.message}"
          @checkin[:errors] << build_report(plugin,:subject => "Plugin would not compile", :body=>"#{$!.message}\n\n#{$!.backtrace}")
          return
        end

        # Lookup any local options in plugin_config.properies as needed
        options=(plugin['options'] || Hash.new)
        options.each_pair do |k,v|
          if v=~/^lookup:(.+)$/
            lookup_key = $1.strip
            if plugin_config[lookup_key]
              options[k]=plugin_config[lookup_key]
            else
              info "Plugin #{id_and_name}: option #{k} appears to be a lookup, but we can't find #{lookup_key} in #{@plugin_config_path}"
            end
          end
        end

        debug "Loading plugin..."
        if job = Plugin.last_defined.load( last_run, (memory || Hash.new), options)
          info "Plugin loaded."
          debug "Running plugin..."
          begin
            data    = {}
            timeout = plugin['timeout'].to_i
            timeout = DEFAULT_PLUGIN_TIMEOUT unless timeout > 0
            Timeout.timeout(timeout, PluginTimeoutError) do
              data = job.run
            end
          rescue Timeout::Error, PluginTimeoutError
            error "Plugin took too long to run."
            @checkin[:errors] << build_report(plugin,
                                              :subject => "Plugin took too long to run",
                                              :body=>"Execution timed out.")
            return
          rescue Exception
            raise if $!.is_a? SystemExit
            error "Plugin failed to run: #{$!.class}: #{$!.message}\n" +
                  "#{$!.backtrace.join("\n")}"
            @checkin[:errors] << build_report(plugin,
                                              :subject => "Plugin failed to run",
                                              :body=>"#{$!.class}: #{$!.message}\n#{$!.backtrace.join("\n")}")
          end
                    
          info "Plugin completed its run."
          
          %w[report alert error summary].each do |type|
            plural  = "#{type}s".sub(/ys\z/, "ies").to_sym
            reports = data[plural].is_a?(Array) ? data[plural] :
                                                  [data[plural]].compact
            if report = data[type.to_sym]
              reports << report
            end
            reports.each do |fields|
              @checkin[plural] << build_report(plugin, fields)
            end
          end
          
          report_embedded_options(plugin,code_to_run)
          
          @history["last_runs"].delete(plugin['name'])
          @history["memory"].delete(plugin['name'])
          @history["last_runs"][id_and_name] = run_time
          @history["memory"][id_and_name]    = data[:memory]
        else
          @checkin[:errors] << build_report(
            plugin,
            :subject => "Plugin would not load."
          )
        end
      else
        debug "Plugin does not need to be run at this time.  " +
              "(last run:  #{last_run || 'nil'})"
      end
      data
    ensure
      if job
        @history["last_runs"].delete(plugin['name'])
        @history["memory"].delete(plugin['name'])
        @history["last_runs"][id_and_name] = run_time
        @history["memory"][id_and_name]    = job.data_for_server[:memory]
      end
      if Plugin.last_defined
        debug "Removing plugin code..."
        begin
          Object.send(:remove_const, Plugin.last_defined.to_s.split("::").first)
          Plugin.last_defined = nil
          info "Plugin Removed."
        rescue
          raise if $!.is_a? SystemExit
          error "Unable to remove plugin."
        end
      end
      info "Plugin '#{plugin['name']}' processing complete."
    end
    
    # Adds embedded options to the checkin if the plugin is manually installed
    # on this server.
    def report_embedded_options(plugin,code)
      return unless plugin['origin'] and Plugin.has_embedded_options?(code)
      if  options_yaml = Plugin.extract_options_yaml_from_code(code)
        options=PluginOptions.from_yaml(options_yaml)
        if options.error
          debug "Problem parsing option definition in the plugin code:"
          debug options_yaml
        else
          debug "Sending options to server"
          @checkin[:options] << build_report(plugin,options.to_hash)
        end
      end
    end


    # captures a list of processes running at this moment
    def take_snapshot
      info "Taking a process snapshot"
      ps=%x(ps aux).split("\n")[1..-1].join("\n") # get rid of the header line
      @checkin[:snapshot]=ps
      rescue Exception
        error "unable to capture processes on this server. #{$!.message}"
        return nil
    end

    # Prepares a check-in data structure to hold Plugin generated data.
    def prepare_checkin
      @checkin = { :reports          => Array.new,
                   :alerts           => Array.new,
                   :errors           => Array.new,
                   :summaries        => Array.new,
                   :snapshot         => '',
                   :config_path      => File.expand_path(File.dirname(@history_file)),
                   :server_name      => @server_name,
                   :options          => Array.new}
    end

    def show_checkin(printer = :p)
      send(printer, @checkin)
    end

    #
    # Loads the history file from disk. If the file does not exist,
    # it creates one.
    #
    def load_history
      if !File.exist?(@history_file) || File.zero?(@history_file)
        create_blank_history
      end
      debug "Loading history file..."
      contents=File.read(@history_file)
      begin
        @history = YAML.load(contents)
      rescue
        backup_history_and_recreate(contents,
        "Couldn't parse the history file. Deleting it and resetting to an empty history file. Keeping a backup.")
      end
      recreate_history_if_client_key_changed
      # YAML interprets an empty file as false. This condition catches that
      if !@history
        info "There is a problem with the history file at '#{@history_file}'. The root cause is sometimes a full disk. "+
                 "If '#{@history_file}' exists but is empty, your disk is likely full."
        exit(1)
      end
      info "History file loaded."
    end
    
    # Called when a history file is determined to be corrupt / truncated / etc. Backup the existing file for later
    # troubleshooting and create a fresh history file.
    def backup_history_and_recreate(contents,message)
      backup_path=File.join(File.dirname(@history_file), "history.corrupt")
      info(message)
      File.open(backup_path,"w"){|f|f.write contents}
      File.delete(@history_file)
      create_blank_history
      @history = File.open(@history_file) { |file| YAML.load(file) }
    end

    # creates a blank history file
    def create_blank_history
      debug "Creating empty history file..."
      @data_file.save(YAML.dump({"last_runs" => Hash.new, "memory" => Hash.new, "last_client_key" => client_key}))
      info "History file created."
    end

    # Saves the history file to disk. 
    def save_history
      debug "Saving history file..."
      @history['last_client_key'] = client_key
      @data_file.save(YAML.dump(@history))
      info "History file saved."
    end

    private
    
    def build_report(plugin_hash, fields)
      { :plugin_id  => plugin_hash['id'],
        :created_at => Time.now.utc.strftime("%Y-%m-%d %H:%M:%S"),
        :fields     => fields,
        :local_filename => plugin_hash['local_filename'], # this will be nil unless it's an ad-hoc plugin
        :origin => plugin_hash['origin'] # [LOCAL|OVERRIDE|nil]
      }
    end

    def checkin
      debug """
#{PP.pp(@checkin, '')}
      """
      @history['last_checkin'] = Time.now.to_i # might have to save the time of invocation and use here to prevent drift
      io   =  StringIO.new
      gzip =  Zlib::GzipWriter.new(io)
      gzip << @checkin.to_json
      gzip.close
      post( urlify(:checkin),
            "Unable to check in with the server.",
            io.string,
            "Content-Type"     => "application/json",
            "Content-Encoding" => "gzip" )
    rescue Exception
      error "Unable to check in with the server."
      debug $!.class.to_s
      debug $!.message
      debug $!.backtrace
    end

    # Called during initialization; loads the plugin_configs (local plugin configurations for passwords, etc)
    # if the file is there. Returns a hash like {"db.username"=>"secr3t"}
    def load_plugin_configs(path)
      temp_configs={}
      if File.exist?(path)
        debug "Loading Plugin Configs at #{path}"
        begin
          File.open(path,"r").read.each_line do |line|
            line.strip!
            next if line[0] == '#'
            next unless line.include? "="
            k,v =line.split('=',2)
            temp_configs[k]=v
          end
          debug("#{temp_configs.size} plugin config(s) loaded.")
        rescue
          info "Error loading Plugin Configs at #{path}: #{$!}"
        end
      else
        debug "No Plugin Configs at #{path}"
      end
      return temp_configs
    end
  end
end
