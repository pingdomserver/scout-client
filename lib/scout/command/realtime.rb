module Scout
  class Command
    class Realtime < Command
      def run
        streamer_command = @args.first
        # Spawn or stop streamer as needed
        if streamer_command.start_with?("start")
          puts "streamer command: start"
          Scout::StreamerDaemon.start_daemon(history, streamer_command, @hostname, @http_proxy)
        elsif streamer_command == "stop"
          puts "streamer command: stop"
          Scout::StreamerDaemon.stop_daemon(history)
        end
      end
    end
  end
end
