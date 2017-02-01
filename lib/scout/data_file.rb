# Used to perform locked, atomic writes to the data file. 
module Scout
  class DataFile
    attr_accessor :path, :logger
    attr_reader :data
    
    def initialize(path,logger)
      @path = path
      @logger = logger
    end
    
    # atomic_write first writes to the tmp file.
    def tmp_path
      path+'.tmp'
    end
    
    def is_windows
      ENV['OS'] == 'Windows_NT'
    end

    # saves the data file by (1) locking the file at +path+ to ensure other processes 
    # don't overlap (2) using an atomic write to ensure other processes always read a complete file.
    def save(content)
      unless is_windows
        lock do
          atomic_write(content)
        end
      else
        atomic_write(content)
      end
    end
    
    private
    
    def lock
      File.open(path, File::RDWR | File::CREAT) do |f|
        begin
          f.flock(File::LOCK_EX)
          yield
        ensure
          f.flock(File::LOCK_UN)          
        end
      end
    rescue Errno::ENOENT, Exception  => e
      logger.error("Unable to access data file [#{e.message}]")
    end
    
    # Uses an Atomic Write - first writes to a tmp file then replace the history file. 
    # Ensures reads on the history file don't see a partial write.
    def atomic_write(content)
      File.open(tmp_path, 'w+') do |f|
        f.write(content)
      end
      FileUtils.mv(tmp_path, path)
    end
    
  end
end
