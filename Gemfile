source "http://rubygems.org"

# Specify your gem's dependencies in scout.gemspec
gemspec

gem "server_metrics"

group :test do
  gem "newrelic_rpm"
  gem "rails", "4.0.8"
  gem "activerecord", "4.0.8"
  gem "mysql2"
  gem "mocha", :require => false
  gem "json"
  gem 'pry'
  gem 'rake'
  gem 'pusher-client', git: 'https://github.com/pingdomserver/pusher-ruby-client'
  gem 'timecop'
end
