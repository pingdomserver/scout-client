module Scout
  class MuninPlugin < Scout::Plugin
  	attr_accessor :file_name
  	def build_report
  		dir = "/etc/munin/plugins"
  		output = IO.popen("cd #{dir};munin-run #{file_name}").readlines[0..19]
  		data = {}
  		output.each do |l|
  			# "i0.value 724\n"
  			match_data = l.match("^(.*).value\s(.*)$")
  			next if match_data.nil? # "multigraph diskstats_latency\n"
  			name = match_data[1]
  			value = match_data[2].to_f
  			data[name] = value
  		end
  		report(data)
  	end
  end
end