module Scout
  module Environment
    def self.bundler?
      ENV['BUNDLE_BIN_PATH'] && ENV['BUNDLE_GEMFILE']
    end

    def self.rvm?
      ENV['MY_RUBY_HOME'] && ENV['MY_RUBY_HOME'].include?('rvm')
    end

    def self.rvm_path
      rvm_path = `rvm env --path`
      $?.exitstatus == 0 ? rvm_path : false
    end

    def self.rvm_path_instructions
      self.rvm_path || "[PATH TO RVM ENVIRONMENT FILE]"
    end

    def self.old_rvm_version?
      self.rvm? && !self.rvm_path
    end
  end
end
