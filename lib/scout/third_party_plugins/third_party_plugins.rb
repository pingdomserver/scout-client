# Abstracted logic for handling third-party plugins in the +Server+ class.
module ThirdPartyPlugins
  # Returns true if the plugin hash is associated w/a 3rd-party plugin like Nagios or Munin.
  def third_party?(hash)
    self.munin?(hash) or self.nagios?(hash)
  end

  def munin?(hash)
    hash['type'].to_s == 'MUNIN'
  end

  def nagios?(hash)
    hash['type'].to_s == 'NAGIOS'
  end

  # Loading third-party plugins is simplier as they don't have options or memory.
  def load_third_party(hash)
  	if munin?(hash)
  		MuninPlugin.new(hash['file_name'])
  	elsif nagios?(hash)
  		Scout::NagiosPlugin.new(hash['cmd'])
  	end
  end

  def get_third_party_plugins
		(get_munin_plugins + get_nagios_plugins).compact
  end

  def get_munin_plugins
	  return [] unless @munin_plugin_path
	  munin_plugin_path=Dir.glob(File.join(@munin_plugin_path,"*"))
	  munin_plugin_path.map do |plugin_path|
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
	        'type'            => 'MUNIN',
	        'code'            => name,
	        'interval'        => 0,
	        'options'         => options,
	        'dir'							=> @munin_plugin_path
	      }
	      plugin
	    rescue => e
	      info "Error trying to read local plugin: #{plugin_path} -- #{e.backtrace.join('\n')}"
	      nil
	    end
  	end.compact
	end

	def get_nagios_plugins
	  return [] unless @nrpe_config_file_path
	  begin
	  	nrpe_config = File.read(@nrpe_config_file_path)
	  rescue => e
	  	info "Unable to read Nagios NRPE Config file [#{@nrpe_config_file_path}]: #{e.message}"
	  	return []
	  end
	  commands = {}
	  nrpe_config.split("\n").each do |l|
	    # command[check_total_procs]=/usr/lib/nagios/plugins/check_procs -w 150 -c 200 
	    # TODO - don't parse commands w/remote args. : command[check_load]=/usr/lib/nagios/plugins/check_load -w $ARG1$ -c $ARG2$
	    match = l.match(/(^command\[(.*)\]=)(.*)/)
	    if match  
	    	if match[3].include?('$ARG')
	    		info "Skipping Nagios Command [#{match[2]}] as it contains remote arguments."
	    	else
	      	commands[match[2]] = match[3]
	      end
	    end
	  end
	  debug "Found #{commands.size} Nagios plugins"
	  # todo - ensure cmd file exists
	  plugins = []
	  commands.each do |name,cmd|
	    plugins << {
	      'name'            => name,
	      'local_filename'  => name,
	      'origin'          => 'LOCAL',
	      'type'            => 'NAGIOS',
	      'code'            => name,
	      'interval'        => 0,
	      'cmd'							=> cmd # unique for nagios
	    }
	  end
		 plugins
	end
end # ThirdPartyPlugins