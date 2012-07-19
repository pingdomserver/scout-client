require "socket"

module Scout
  CLIENT_HOSTNAME = ENV.fetch("SCOUT_HOSTNAME", Socket.gethostname)
end

