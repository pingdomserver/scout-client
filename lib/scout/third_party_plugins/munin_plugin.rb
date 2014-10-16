module Scout
  class MuninPlugin < Scout::Plugin
    attr_accessor :file_name, :dir

    # The file name of the munin plugin to run inside the munin plugins directory.
    def initialize(options)
      self.file_name = options['file_name']
      self.dir = options['dir']
    end

    def build_report
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