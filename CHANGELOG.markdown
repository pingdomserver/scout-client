# 5.9.8

* Added Nagios plugin support via the `--nagios` flag.

# 5.9.7.1

* write a bit more information about system metrics in the realtime log

# 5.9.7

* Preliminary support for realtime compatibility with GO agent
>>>>>>> master

# 5.9.5

* If plugin last_run is in the future, run the plugins now

# 5.9.4

* Use the invocation time when recording last_checkin date

# 5.9.3

* Add server_metrics version to debug log, bump server_metrics dependency to 1.2.5

# 5.9.2

* Fix for network realtime streaming

# 5.9.1

* Upgrade to use server_metrics 1.2.4 (osx disk capacity)

# 5.9.0

* Streaming fix for Ruby 1.8.7

# 5.8.9

* Added support for realtime system metrics (processes, cpu, memory, disks, network devices)

# 5.8.8

* Counters report nil values on initial report, rather than not reporting

# 5.8.7

* Upgrade to use server_metrics 1.2.2 (disk metrics in English, more forgiving Linux check)

# 5.8.6

* Upgrade to use server_metrics 1.2.0 (performance improvements)

# 5.8.5

* Upgrade to use server_metrics 1.1.1 (no more sys-proctable)

# 5.8.4

* Upgrade to use server_metrics 1.0.3 (jiffies)

# 5.8.3

* Ruby gems issue - needed to yank 5.8.2 and republish.

# 5.8.2

* Updated to use server_metrics 1.0.2 (kthread)

# 5.8.1

* Updated to use server_metrics 1.0.1 (khtreadd)

# 5.8.0

* Support for server_metrics

# 5.7.5

* send unix timestamp when streaming data

# 5.7.4

* fixed a JSON error when running under Ruby 1.8.x

# 5.7.3

* Fix for an issue with JRuby validating keys
* More helpful output when installing on a version of RVM < 1.12.0

# 5.7.2

* updated pusher gem and associated vendored gems
* added support for realtime when using an http proxy
* added support for proxies during full signing process and troubleshoot

# 5.7.1

* Using $PROGRAM_NAME to determine scout path in install output

# 5.7.0

* Added support for environments

# 5.6.11

* Remove the scout_streamer.pid file after the realtime processes has expired.

# 5.6.10

* Fix for plugin.properties that contain '=' in the property value

# 5.6.9

* Install command generates a script for cron to run when using RVM or Bundler

# 5.6.8

* Updated JSON to 1.8.0

# 5.6.7

* changed fqdn override to hostname override. We no longer send fqdn.
* hostname is now send exclusively in the URL -- it is no longer sent in the HTTP headers

# 5.6.6

* Fix for urlify query string in Ruby 1.8.6.

# 5.6.5

* remove newline from FQDN

# 5.6.4

* send FQDN in addition to hostname, and provide an override

# 5.6.3

* Removing $VERBOSE = true

# 5.6.2

* More forgiving regex to extract the code class when streaming.

# 5.6.1

* send role names exactly as the user entered - makes it easier to debug role name issues

# 5.6.0

* added roles

# 5.5.10

* fixed SSL error on scout troubleshoot --post
* Updated gem summary + description

# 5.5.9

* Locking data file when writing.

# 5.5.8

* Passing server_name for install + test commands so https_proxy is used.
* Resetting history file when then client key changes

# 5.5.7

* Fixing broken tests
* Using proxy password (was using proxy port on mistake)

# 5.5.6

* Fixing broken tests
* PID file rescue fix
* Only running local plugins if a Scout::Plugin
* Added hostname to troubleshooting output
* Atomic Write history file when saving

# 5.5.5

* Fix for blank PID file
* Added client version + hostname when starting run in debug mode

# 5.5.4

* Fixes warnings with Ruby 1.9.3p0

# 5.5.3

* Fixed 'shadowing outer local variable' messages

# 5.5.2

* Fixed --http-proxy & --https-proxy support, which were broken in 5.5.0

# 5.5.1

* Updating history on plugin timeouts (last run & memory). Previously, the data from the last successful run was retained.

# 5.5.0

* yes, the version number jumped from  5.3.5 to 5.5.0
* Implemented "real time" mode

# 5.3.5

* Moved proxy support to explicit command line flags --http_proxy and https_proxy
* fixed two unused variables that were causing warnings under 1.9.3

# 5.3.4

* Incorporating sleep interval into Server#time_to_checkin?
* Added proxy support command line flags

# 5.3.3

* Sending embedded options to server for local & plugin overrides.
* Reading options for local plugins
* Added support for an account-specific public key (scout_rsa.pub)

# 5.3.2

* New --name="My Server" option to specify server name from the scout command.

# 5.3.1

* Write a log message if a full disk prevents Scout from creating a history file.

# 5.3.0

* Ping over http instead of https. All plan retrievals and check-ins are still SSL
* Added ability to post troubleshooting report back to scoutapp.com  

# 5.2.2

* More graceful handling of *rare* client_history.yaml corruption

# 5.2.1

* Added private-key based code signing
* Added local plugin overrides
* Added local ad-hoc plugins

# 5.1.5

* Added sleep interval directive. Agent will only sleep when used in non-interactive mode.

# 5.1.4

* Normalized header formats

# 5.1.3

* Added debug output when contact with server cannot be established
* Updated to json_pure 1.4.2

# 5.1.2

* Added backtrace to Plugin code compile errors

# 5.1.1

* Fixed Counter functionality for per-minute metrics

# 5.1.0

* Agent now reports data on initial install
* If history file is empty, Agent will resume normal checkin when it can write history file again (thx @jnewland)
* inclusion of counter functionality (thx @lindvall)

# 5.0.3

* fixed regression: Error when running `scout AGENT_KEY` without first running scout and manually entering the agent key 

# 5.0.2

* fixed silent failure when plugin didn't inherit from Scout::Plugin
* beefed up error reporting

# 5.0.1

* plugin errors are now reported to scout server as errors, for easier plugin troubleshooting

# 5.0.0

* crontab must now run Scout every minute, regardless of what plan you are on
* Support for server downtime notifications
* Pings server every minute. Performs actual checkin on schedule provided by server
* Support for plugin option definition via an inline YAML file.
* Easier format for providing plugin arguments in test mode (scout help for details)
* Prints plugin arguments, including defaults, when run in test mode

# 4.0.2

* Check-in once after all plugins are run instead of once for each plugin for
  better efficiency

# 4.0.1

* Fixed a regression that broken support for some very old plugins

# 4.0.0

* Switched to the new API URL's
* Converted to JSON (using the vendored json_pure) from Marshal
* Upgraded to the data protocol used by the scout_agent
* Added SSL certificate verification to increase security
* Honor Last-Modified headers from the server to improve efficiency
* Added support for individual plugin timeouts
* Inserted a KILL signal for old processes to keep things running
* Removing obsolete clone action
* Removed non-functional test code
* Cleaned up Rake tasks for development
* Started sending an HTTP_CLIENT_HOSTNAME header to the Scout server
* Changed history file storage to be by plugin ID, instead of name

# 2.0.7

* Improved PID file error messages
* Adding a redundant Timeout to work around Net::HTTP hangs

# 2.0.6

* Adding plugin dependency support via the new needs() class method
* Improved Scout error backtraces (patch from dougbarth)

# 2.0.5

* Another Version bump to update gem servers

# 2.0.4

* Version bump to update gem servers

# 2.0.3

* Added documentation for Scout#data_for_server method for new plugin creation
* Added Version option for printing the current version
* Removed a spurious "puts" debug statement

# 2.0.2

* Fixed the logging bug I introduced by moving the PID check into the Command
  class

# 2.0.1

* Added some safety code to ensure SystemExit exceptions are not caught in our
  rescue clauses

# 2.0.0

* Reworked scout executable to work off an underlying command structure, similar
  to Subversion (a bare call and a call with just the key are supported for
  backward compatibility)
* Added various helper functions to Scout::Plugin to ease development
* Added a client clone command for instant setups

# 1.1.8

* Rectifying missing checkin -- this unifies 1.1.6 and 1.1.7 changes to gem

# 1.1.7

* Introducing a delta for the plugin run interval, now allowing runs even if
  they are up to 30 seconds early

# 1.1.6

* minor documentation update in scout installation wizard

# 1.1.5

* A more robust solution for plugin removal
* Added seconds to logging

# 1.1.4

* Trim all space from the client key during install
* Trying a fix for the plugin removal errors

# 1.1.3

* Fixed bug with running plugin using the -p option, new ensure wasn't returning
  the data

# 1.1.2

* Fixed the plugin interval not running on time due to a ">=" bug

# 1.1.1

* Fixed the double plugin load bug
* Ensuring that plugins are unloaded, even on error

# 1.1.0

* Using better url.path + url.query if present to properly encode URLs

# 1.0.9

* Fixed bug when plugin code would not compile, throws Exception
* Added ability to test/call scout on non-https servers (for debugging)
* Client now sends client version to server
* Client can send single values (using report, alert, error symbols) or multiple
  values (using reports, alerts, errors symbols)
* Added test suite, which is now the default rake task

# 1.0.8

* Added optional report field scout_time
* Changed #error method name to #scout_error to fix conflict with Logger#error

# 1.0.7

* Increased the plugin timeout to 60 seconds
* Added PID file protection to the client so only one copy will run at a time
* Fixed a bug that caused the wrong error message to be shown for the case when
  a plugin times out

# 1.0.6

* Improved error backtrace for local testing

# 1.0.5

* Added more documentation to Server and Plugin classes
* Fixed an issue where expand_path(~) would not work if HOME was not set, which  
  should help Scout run in OS X's LaunchDaemon using launchd

# 1.0.4

* Enhanced the -o option to take a Ruby Hash
* Fixed an issue where a failed plugin run would cause the client to skip all
  other plugins

# 1.0.3

* Refactored to allow testing of plugins locally using -p or --plugin option
  and -o or --plugin-options option

# 1.0.2

* Updated to use SSL by default for all communication to scout server
* Added elif dependency

# 1.0.1

* Fixed bug relating to history file – not using specified history file path

# 1.0.0

* Initial release
