#!/usr/bin/env ruby -wKU


module Scout

  class Plugin

    EMBEDDED_OPTIONS_REGEX = /OPTIONS ?= ?<<-?([A-Z_]+)(.*)\1/m

    class << self
      attr_accessor :last_defined

      def inherited(new_plugin)
        @last_defined = new_plugin
      end

      def load(last_run, memory, options)
        new(last_run, memory, options)
      end
      
      # 
      # You can use this method to indicate one or more libraries your plugin
      # requires:
      # 
      #   class MyNeedyPlugin < Scout::Plugin
      #     needs "faster_csv", "elif"
      #     # ...
      #   end
      # 
      # Your build_report() method will not be called if all libraries cannot
      # be loaded.  RubyGems will be loaded if needed to find the libraries.
      # 
      def needs(*libraries)
        if libraries.empty?
          @needs ||= [ ]
        else
          needs.push(*libraries.flatten)
        end
      end

      # true if the code seems to have embedded options
      def has_embedded_options?(code)
        code =~ EMBEDDED_OPTIONS_REGEX
      end

      # extracts the internal YAML, if any, and returns the YAML string.
      # returns nil if no embedded options.
      def extract_options_yaml_from_code(code)
        code =~ EMBEDDED_OPTIONS_REGEX
        return $2
      end

      def extract_code_class(code)
        match = /class\s\b(\w*)\s*?<\s*Scout::Plugin/.match(code)

        if match
          return match[1]
        else
          raise ArgumentError, "can't identify plugin class"
        end
      end
    end

    # Creates a new Scout Plugin to run.
    def initialize(last_run, memory, options)
      @last_run = last_run
      @memory   = memory
      @options  = options
    end
    
    def option(name)
      @options[name] || @options[name.is_a?(String) ? name.to_sym : String(name)]
    end

    # Builds the data to send to the server.
    #
    # We programatically define several helper methods for creating this data.
    # 
    # Usage:
    # 
    #   reports << {:data => "here"}
    #   report(:data => "here")
    #   add_report(:data => "here")
    # 
    #   alerts << {:subject => "subject", :body => "body"}
    #   alert("subject", "body")
    #   alert(:subject => "subject", :body => "body")
    #   add_alert("subject", "body")
    #   add_alert(:subject => "subject", :body => "body")
    # 
    #   errors << {:subject => "subject", :body => "body"}
    #   error("subject", "body")
    #   error(:subject => "subject", :body => "body")
    #   add_error("subject", "body")
    #   add_error(:subject => "subject", :body => "body")
    #     
    def data_for_server
      @data_for_server ||= { :reports   => [ ],
                             :alerts    => [ ],
                             :errors    => [ ],
                             :summaries => [ ],
                             :memory  => { } }
    end
    
    %w[report alert error summary].each do |kind|
      class_eval <<-END
        if "#{kind}" == "summary"
          def summaries
            data_for_server[:summaries]
          end
        else
          def #{kind}s
            data_for_server[:#{kind}s]
          end
        end
        
        if "#{kind}" == "report"
          def report(new_entry)
            reports << new_entry
          end
        elsif "#{kind}" == "summary"
          def summary(new_entry)
            summaries << new_entry
          end
        else
          def #{kind}(*fields)
            #{kind}s << ( fields.first.is_a?(Hash) ?
                          fields.first :
                          {:subject => fields.first, :body => fields.last} )
          end
        end
        alias_method :add_#{kind}, :#{kind}
      END
    end

    #
    # Usage:
    # 
    #   memory(:no_track)
    #   memory.delete(:no_track)
    #   memory.clear
    # 
    def memory(name = nil)
      if name.nil?
        data_for_server[:memory]
      else
        @memory[name] ||
        @memory[name.is_a?(String) ? name.to_sym : String(name)]
      end
    end
    
    #
    # Usage:
    # 
    #   remember(:name, value)
    #   remember(:name1, value1, :name2, value2)
    #   remember(:name => value)
    #   remember(:name1 => value1, :name2 => value2)
    #   remember(:name1, value1, :name2 => value2)
    # 
    def remember(*args)
      hashes, other = args.partition { |value| value.is_a? Hash }
      hashes.each { |hash| memory.merge!(hash) }
      (0...other.size).step(2) { |i| memory.merge!(other[i] => other[i + 1]) }
    end
    
    #
    # Usage:
    #
    #   counter(:rkbps, stats['rsect'] / 2, :per => :second)
    #   counter(:rpm, request_counter, :per => :minute)
    #   counter(:swap_ins, vmstat['pswpin'], :per => :second, :round => true)
    #
    def counter(name, value, options = {}, &block)
      current_time = Time.now

      if data = memory("_counter_#{name}")
        last_time, last_value = data[:time], data[:value]
        elapsed_seconds       = current_time - last_time

        # We won't log it if the value has wrapped or enough time hasn't
        # elapsed
        if value >= last_value && elapsed_seconds >= 1
          if block
            result = block.call(last_value, value)
          else
            result = value - last_value
          end

          case options[:per]
          when :second, 'second'
            result = result / elapsed_seconds.to_f
          when :minute, 'minute'
            result = result / elapsed_seconds.to_f * 60.0
          when :hour, 'hour'
            result = result / elapsed_seconds.to_f * 60.0 * 60
          when :day, 'day'
            result = result / elapsed_seconds.to_f * 60.0 * 60 * 24
          when :month, 'month'
            result = result / elapsed_seconds.to_f * 60.0 * 60 * 24 * 30
          when :year, 'year'
            result = result / elapsed_seconds.to_f * 60.0 * 60 * 24 * 30 * 365
          else
            raise "Unknown option for ':per': #{options[:per].inspect}"
          end

          if options[:round]
            # Backward compatibility
            options[:round] = 1 if options[:round] == true

            result = (result * (10 ** options[:round])).round / (10 ** options[:round]).to_f
          end

          report(name => result)
        end
      else # report nil to reserve the metric name in rrd
        report(name => nil)
      end

      remember("_counter_#{name}" => { :time => current_time, :value => value })
    end

    #
    # Old plugins will work because they override this method.  New plugins can
    # now leave this method in place, add a build_report() method instead, and
    # use the new helper methods to build up content inside which will
    # automatically be returned as the end result of the run.
    # 
    def run
      build_report if self.class.needs.all? { |l| library_available?(l) }
      data_for_server
    end
    
    private
    
    #
    # Returns true is a library can be loaded.  A bare require is made as the
    # first attempt.  If that fails, RubyGems is loaded and another attempt is
    # made.  If the library cannot be loaded either way, an error() is generated
    # and build_report() will not be called.
    # 
    def library_available?(library)
      begin
        require library
      rescue LoadError
        begin
          require "rubygems"
          require library
        rescue LoadError
          error("Failed to load library", "Could not load #{library}")
          return false
        end
      end
      true
    end
  end
end
