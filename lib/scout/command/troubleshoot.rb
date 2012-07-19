#!/usr/bin/env ruby -wKU

require "uri"
require "socket"
require "net/https"
require "timeout"


module Scout
  class Command
    class APITimeoutError < RuntimeError; end

    HTTP_HEADERS = { "Client-Version"  => Scout::VERSION,
                     "Client-Hostname" => Scout::CLIENT_HOSTNAME }

    class Troubleshoot < Command
      
      def initialize(options, args)
        @post = options[:troubleshoot_post]
        @include_history = !options[:troubleshoot_no_history]
        @contents=[]
        options[:verbose]=true # force verbose logging for this command
        super
      end

      def run
        puts "Gathering troubleshooting information about your Scout install ... "

        heading "Scout Info"
        bullet "History file", history
        bullet "Version", Scout::VERSION

        heading "Latest Log"
        contents=File.read(log_path) rescue "Log not found at #{log_path}"
        text contents

        heading "Rubygems Environment"
        text `gem env`

        heading "Ruby info"
        bullet "Path to executable", `which ruby`
        bullet "Version", `ruby -v`
        bullet "Ruby's internal path",  $:.join(', ')

        heading "Installed Gems"
        text `gem list --local`


        if @include_history
          heading "History file Contents"
          contents=File.read(history) rescue "History not found at #{log_path}"
          text contents
        else
          heading "Skipping History file Contents"
        end

        heading "Agent directory Contents"
        text `ls -la #{config_dir}`

        heading ""

        if @post
          puts "Posting troubleshooting info to #{@server} ... "
          url = URI.join( @server,"/admin/troubleshooting_reports")
          post_form(url, "Couldn't contact server at #{@server}",{:body=>contents_as_text}) do |res|
            puts "Scout server says: \"#{res.body}\""
          end
        else
          puts contents_as_text
        end

        puts " ... Done"
      end
    end

    private
    def heading(s)
      @contents += ["",s,"**************************************************************************************************",""]
    end

    def bullet(label,s)
      @contents << " - #{label} :  #{s.chomp}"
    end

    def text(s)
      @contents << s
    end

    def contents_as_text
      @contents.join("\n")
    end

    def post_form(url, error, form_data, headers = Hash.new, &response_handler)
      return unless url
      request(url, response_handler, error) do |connection|
        post = Net::HTTP::Post.new( url.path +
                                    (url.query ? ('?' + url.query) : ''),
                                    HTTP_HEADERS.merge(headers) )
        post.set_form_data(form_data)
        connection.request(post)
      end
    end

    def request(url, response_handler, error, &connector)
      response           = nil
      Timeout.timeout(5 * 60, APITimeoutError) do
        http               = Net::HTTP.new(url.host, url.port)
        if url.is_a? URI::HTTPS
          http.use_ssl     = true
          http.ca_file     = File.join( File.dirname(__FILE__),
                                        *%w[.. .. data cacert.pem] )
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER |
                             OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
        end
        response           = no_warnings { http.start(&connector) }
      end
      case response
      when Net::HTTPSuccess, Net::HTTPNotModified
        response_handler[response] unless response_handler.nil?
      else
        error = "Server says: #{response['x-scout-msg']}" if response['x-scout-msg']
        log.fatal error
        raise SystemExit.new(error)
      end
    rescue Timeout::Error
      log.fatal "Request timed out."
      exit
    rescue Exception
      raise if $!.is_a? SystemExit
      log.fatal "An HTTP error occurred:  #{$!.message}"
      exit
    end

    def no_warnings
      old_verbose = $VERBOSE
      $VERBOSE    = false
      yield
    ensure
      $VERBOSE = old_verbose
    end
  end
end
