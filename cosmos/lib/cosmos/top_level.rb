# encoding: ascii-8bit

# Copyright 2021 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU Affero General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# This program may also be used under the terms of a commercial or
# enterprise edition license of COSMOS if purchased from the
# copyright holder

# This file contains top level functions in the Cosmos namespace

require 'thread'
require 'digest'
require 'open3'
require 'cosmos/core_ext'
require 'cosmos/version'
require 'cosmos/utilities/logger'
require 'socket'
require 'pathname'

# If a hazardous command is sent through the {Cosmos::Api} this error is raised.
# {Cosmos::Script} rescues the error and prompts the user to continue.
class HazardousError < StandardError
  attr_accessor :target_name
  attr_accessor :cmd_name
  attr_accessor :cmd_params
  attr_accessor :hazardous_description

  def to_s
    "#{target_name} #{cmd_name} with #{cmd_params} is Hazardous due to #{hazardous_description}"
  end
end

# The Ball Aerospace COSMOS system is almost
# wholly contained within the Cosmos module. COSMOS also extends some of the
# core Ruby classes to add additional functionality.

module Cosmos
  BASE_PWD = Dir.pwd

  # FatalErrors cause an exit but are not as dangerous as other errors.
  # They are used for known issues and thus we don't need a full error report.
  class FatalError < StandardError; end

  # Global mutex for the Cosmos module
  COSMOS_MUTEX = Mutex.new

  # Path to COSMOS Gem based on location of top_level.rb
  PATH = File.expand_path(File.join(File.dirname(__FILE__), '../..'))
  PATH.freeze

  # Header to put on all marshal files created by COSMOS
  COSMOS_MARSHAL_HEADER = "ruby #{RUBY_VERSION} (#{RUBY_RELEASE_DATE} patchlevel #{RUBY_PATCHLEVEL}) [#{RUBY_PLATFORM}] COSMOS #{COSMOS_VERSION}"

  # Disables the Ruby interpreter warnings such as when redefining a constant
  def self.disable_warnings
    saved_verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = saved_verbose
  end

  # Adds a path to the global Ruby search path
  #
  # @param path [String] Directory path
  def self.add_to_search_path(path, front = true)
    path = File.expand_path(path)
    $:.delete(path)
    if front
      $:.unshift(path)
    else # Back
      $: << path
    end
  end

  # Creates a marshal file by serializing the given obj
  #
  # @param marshal_filename [String] Name of the marshal file to create
  # @param obj [Object] The object to serialize to the file
  def self.marshal_dump(marshal_filename, obj)
    Cosmos.set_working_dir do
      File.open(marshal_filename, 'wb') do |file|
        file.write(COSMOS_MARSHAL_HEADER)
        file.write(Marshal.dump(obj))
      end
    end
  rescue Exception => exception
    begin
      Cosmos.set_working_dir do
        File.delete(marshal_filename)
      end
    rescue Exception
      # Oh well - we tried
    end
    if exception.class == TypeError and exception.message =~ /Thread::Mutex/
      original_backtrace = exception.backtrace
      exception = exception.exception("Mutex exists in a packet.  Note: Packets must not be read during class initializers for Conversions, Limits Responses, etc.: #{exception}")
      exception.set_backtrace(original_backtrace)
    end
    self.handle_fatal_exception(exception)
  end

  # Loads the marshal file back into a Ruby object
  #
  # @param marshal_filename [String] Name of the marshal file to load
  def self.marshal_load(marshal_filename)
    cosmos_marshal_header = nil
    data = nil
    Cosmos.set_working_dir do
      File.open(marshal_filename, 'rb') do |file|
        cosmos_marshal_header = file.read(COSMOS_MARSHAL_HEADER.length)
        data = file.read
      end
    end
    if cosmos_marshal_header == COSMOS_MARSHAL_HEADER
      return Marshal.load(data)
    else
      Logger.warn "Marshal load failed with invalid marshal file: #{marshal_filename}"
      return nil
    end
  rescue Exception => exception
    Cosmos.set_working_dir do
      if File.exist?(marshal_filename)
        Logger.error "Marshal load failed with exception: #{marshal_filename}\n#{exception.formatted}"
      else
        Logger.info "Marshal file does not exist: #{marshal_filename}"
      end

      # Try to delete the bad marshal file
      begin
        File.delete(marshal_filename)
      rescue Exception
        # Oh well - we tried
      end
      self.handle_fatal_exception(exception) if File.exist?(marshal_filename)
    end
    return nil
  end

  # Changes the current working directory to the USERPATH and then executes the
  # command in a new Ruby Thread.
  #
  # @param command [String] The command to execute via the 'system' call
  def self.run_process(command)
    thread = nil
    Cosmos.set_working_dir do
      thread = Thread.new do
        system(command)
      end
      # Wait for the thread and process to start
      sleep 0.01 until !thread.status.nil?
      sleep 0.1
    end
    thread
  end

  # Changes the current working directory to the USERPATH and then executes the
  # command in a new Ruby Thread.  Will show a messagebox or print the output if the
  # process produces any output
  #
  # @param command [String] The command to execute via the 'system' call
  def self.run_process_check_output(command)
    thread = nil
    Cosmos.set_working_dir do
      thread = Thread.new do
        output, _ = Open3.capture2e(command)
        if !output.empty?
          # Ignore modalSession messages on Mac Mavericks
          new_output = ''
          output.each_line do |line|
            new_output << line if !/modalSession/.match?(line)
          end
          output = new_output

          if !output.empty?
            Logger.error output
            self.write_unexpected_file(output)
          end
        end
      end
      # Wait for the thread and process to start
      sleep 0.01 until !thread.status.nil?
      sleep 0.1
    end
    thread
  end

  # Runs a hash algorithm over one or more files and returns the Digest object.
  # Handles windows/unix new line differences but changes in whitespace will
  # change the hash sum.
  #
  # Usage:
  #   digest = Cosmos.hash_files(files, additional_data, hashing_algorithm)
  #   digest.digest # => the 16 bytes of digest
  #   digest.hexdigest # => the formatted string in hex
  #
  # @param filenames [Array<String>] List of files to read and calculate a hashing
  #   sum on
  # @param additional_data [String] Additional data to add to the hashing sum
  # @param hashing_algorithm [String] Hashing algorithm to use
  # @return [Digest::<algorithm>] The hashing sum object
  def self.hash_files(filenames, additional_data = nil, hashing_algorithm = 'SHA256')
    digest = Digest.const_get(hashing_algorithm).public_send('new')

    Cosmos.set_working_dir do
      filenames.each do |filename|
        next if File.directory?(filename)

        # Read the file's data and add to the running hashing sum
        digest << File.read(filename)
      end
    end
    digest << additional_data if additional_data
    digest
  end

  # Opens a timestamped log file for writing. The opened file is yielded back
  # to the block.
  #
  # @param filename [String] String to append to the exception log filename.
  #   The filename will start with a date/time stamp.
  # @param log_dir [String] By default this method will write to the COSMOS
  #   default log directory. By setting this parameter you can override the
  #   directory the log will be written to.
  # @yieldparam file [File] The log file
  # @return [String|nil] The fully pathed log filename or nil if there was
  #   an error creating the log file.
  def self.create_log_file(filename, log_dir = nil)
    log_file = nil
    Cosmos.set_working_dir do
      begin
        # The following code goes inside a begin rescue because it reads the
        # system.txt configuration file. If this has an error we won't be able
        # to determine the log path but we still want to write the log.
        log_dir = System.instance.paths['LOGS'] unless log_dir
        # Make sure the log directory exists
        raise unless File.exist?(log_dir)
      rescue Exception
        log_dir = nil # Reset log dir since it failed above
        # First check for ./logs
        log_dir = './logs' if File.exist?('./logs')
        # Prefer ./outputs/logs if it exists
        log_dir = './outputs/logs' if File.exist?('./outputs/logs')
        # If all else fails just use the local directory
        log_dir = '.' unless log_dir
      end
      log_file = File.join(log_dir,
                           File.build_timestamped_filename([filename]))
      # Check for the log file existing. This could happen if this method gets
      # called more than once in the same second.
      if File.exist?(log_file)
        sleep 1.01 # Sleep before rebuilding the timestamp to get something unique
        log_file = File.join(log_dir,
                             File.build_timestamped_filename([filename]))
      end
      begin
        COSMOS_MUTEX.synchronize do
          file = File.open(log_file, 'w')
          yield file
        ensure
          file.close unless file.closed?
          File.chmod(0444, log_file) # Make file read only
        end
      rescue Exception
        # Ensure we always return
      end
      log_file = File.expand_path(log_file)
    end
    return log_file
  end

  # Writes a log file with information about the current configuration
  # including the Ruby version, Cosmos version, whether you are on Windows, the
  # COSMOS path and userpath, and the Ruby path along with the exception that
  # is passed in.
  #
  # @param [String] filename String to append to the exception log filename.
  #   The filename will start with a date/time stamp.
  # @param [String] log_dir By default this method will write to the COSMOS
  #   default log directory. By setting this parameter you can override the
  #   directory the log will be written to.
  # @return [String|nil] The fully pathed log filename or nil if there was
  #   an error creating the log file.
  def self.write_exception_file(exception, filename = 'exception', log_dir = nil)
    log_file = create_log_file(filename, log_dir) do |file|
      file.puts "Exception:"
      if exception
        file.puts exception.formatted
        file.puts
      else
        file.puts "No Exception Given"
        file.puts caller.join("\n")
        file.puts
      end
      file.puts "Caller Backtrace:"
      file.puts caller().join("\n")
      file.puts

      file.puts "Ruby Version: ruby #{RUBY_VERSION} (#{RUBY_RELEASE_DATE} patchlevel #{RUBY_PATCHLEVEL}) [#{RUBY_PLATFORM}]"
      file.puts "Rubygems Version: #{Gem::VERSION}"
      file.puts "Cosmos Version: #{Cosmos::VERSION}"
      file.puts "Cosmos::PATH: #{Cosmos::PATH}"
      file.puts ""
      file.puts "Environment:"
      file.puts "RUBYOPT: #{ENV['RUBYOPT']}"
      file.puts "RUBYLIB: #{ENV['RUBYLIB']}"
      file.puts "GEM_PATH: #{ENV['GEM_PATH']}"
      file.puts "GEMRC: #{ENV['GEMRC']}"
      file.puts "RI_DEVKIT: #{ENV['RI_DEVKIT']}"
      file.puts "GEM_HOME: #{ENV['GEM_HOME']}"
      file.puts "PATH: #{ENV['PATH']}"
      file.puts ""
      file.puts "Ruby Path:\n  #{$:.join("\n  ")}\n\n"
      file.puts "Gems:"
      Gem.loaded_specs.values.map { |x| file.puts "#{x.name} #{x.version} #{x.platform}" }
      file.puts ""
      file.puts "All Threads Backtraces:"
      Thread.list.each do |thread|
        file.puts thread.backtrace.join("\n")
        file.puts
      end
      file.puts ""
      file.puts ""
    ensure
      file.close
    end
    return log_file
  end

  # Writes a log file with information about unexpected output
  #
  # @param[String] text The unexpected output text
  # @param [String] filename String to append to the exception log filename.
  #   The filename will start with a date/time stamp.
  # @param [String] log_dir By default this method will write to the COSMOS
  #   default log directory. By setting this parameter you can override the
  #   directory the log will be written to.
  # @return [String|nil] The fully pathed log filename or nil if there was
  #   an error creating the log file.
  def self.write_unexpected_file(text, filename = 'unexpected', log_dir = nil)
    log_file = create_log_file(filename, log_dir) do |file|
      file.puts "Unexpected Output:\n\n"
      file.puts text
    ensure
      file.close
    end
    return log_file
  end

  # Catch fatal exceptions within the block
  # This is intended to catch exceptions before the GUI is available
  def self.catch_fatal_exception
    yield
  rescue Exception => error
    unless error.class == SystemExit or error.class == Interrupt
      Logger.level = Logger::FATAL
      Cosmos.handle_fatal_exception(error, false)
    end
  end

  # Write a message to the Logger, write an exception file, and popup a GUI
  # window if try_gui. Finally 'exit 1' is called to end the calling program.
  #
  # @param error [Exception] The exception to handle
  # @param try_gui [Boolean] Whether to try and create a GUI exception popup
  def self.handle_fatal_exception(error, try_gui = true)
    unless error.class == SystemExit or error.class == Interrupt
      $cosmos_fatal_exception = error
      self.write_exception_file(error)
      Logger.level = Logger::FATAL
      Logger.fatal "Fatal Exception! Exiting..."
      Logger.fatal error.formatted
      if $stdout != STDOUT
        $stdout = STDOUT
        Logger.fatal "Fatal Exception! Exiting..."
        Logger.fatal error.formatted
      end
      sleep 1 # Allow the messages to be printed and then crash
      exit 1
    else
      exit 0
    end
  end

  # CriticalErrors are errors that need to be brought to a user's attention but
  # do not cause an exit. A good example is if the packet log writer fails and
  # can no longer write the log file. Write a message to the Logger, write an
  # exception file, and popup a GUI window if try_gui. Ensure the GUI only
  # comes up once so this method can be called over and over by failing code.
  #
  # @param error [Exception] The exception to handle
  # @param try_gui [Boolean] Whether to try and create a GUI exception popup
  def self.handle_critical_exception(error, try_gui = true)
    Logger.error "Critical Exception! #{error.formatted}"
    self.write_exception_file(error)
  end

  # Creates a Ruby Thread to run the given block. Rescues any exceptions and
  # retries the threads the given number of times before handling the thread
  # death by calling {Cosmos.handle_fatal_exception}.
  #
  # @param name [String] Name of the thread
  # @param retry_attempts [Integer] The number of times to allow the thread to
  #   restart before exiting
  def self.safe_thread(name, retry_attempts = 0)
    Thread.new do
      retry_count = 0
      begin
        yield
      rescue => error
        Logger.error "#{name} thread unexpectedly died. Retries: #{retry_count} of #{retry_attempts}"
        Logger.error error.formatted
        retry_count += 1
        if retry_count <= retry_attempts
          self.write_exception_file(error)
          retry
        end
        handle_fatal_exception(error)
      end
    end
  end

  # Require the class represented by the filename. This uses the standard Ruby
  # convention of having a single class per file where the class name is camel
  # cased and filename is lowercase with underscores.
  #
  # @param class_name_or_class_filename [String] The name of the class or the file which contains the
  #   Ruby class to require
  # @param log_error [Boolean] Whether to log an error if we can't require the class
  def self.require_class(class_name_or_class_filename, log_error = true)
    if class_name_or_class_filename.downcase[-3..-1] == '.rb' or (class_name_or_class_filename[0] == class_name_or_class_filename[0].downcase)
      class_filename = class_name_or_class_filename
      class_name = class_filename.filename_to_class_name
    else
      class_name = class_name_or_class_filename
      class_filename = class_name.class_name_to_filename
    end
    return class_name.to_class if class_name.to_class and defined? class_name.to_class

    self.require_file(class_filename, log_error)
    klass = class_name.to_class
    raise "Ruby class #{class_name} not found" unless klass

    klass
  end

  # Requires a file with a standard error message if it fails
  #
  # @param filename [String] The name of the file to require
  # @param log_error [Boolean] Whether to log an error if we can't require the class
  def self.require_file(filename, log_error = true)
    require filename
  rescue Exception => err
    msg = "Unable to require #{filename} due to #{err.message}. "\
          "Ensure #{filename} is in the COSMOS lib directory."
    Logger.error msg if log_error
    raise $!, msg, $!.backtrace
  end

  # @param filename [String] Name of the file to open in the web browser
  def self.open_in_web_browser(filename)
    if filename
      if Kernel.is_windows?
        self.run_process("cmd /c \"start \"\" \"#{filename.gsub('/', '\\')}\"\"")
      elsif Kernel.is_mac?
        self.run_process("open -a Safari \"#{filename}\"")
      else
        which_firefox = `which firefox`.chomp
        if which_firefox =~ /Command not found/i or which_firefox =~ /no .* in/i
          raise "Firefox not found"
        else
          system_call = "#{which_firefox} \"#{filename}\""
        end

        self.run_process(system_call)
      end
    end
  end

  # Temporarily set the working directory during a block
  def self.set_working_dir(working_dir = Cosmos::PATH)
    current_dir = Dir.pwd
    Dir.chdir(working_dir)
    begin
      yield
    ensure
      Dir.chdir(current_dir)
    end
  end

  # Attempt to gracefully kill a thread
  # @param owner Object that owns the thread and may have a graceful_kill method
  # @param thread The thread to gracefully kill
  # @param graceful_timeout Timeout in seconds to wait for it to die gracefully
  # @param timeout_interval How often to poll for aliveness
  # @param hard_timeout Timeout in seconds to wait for it to die ungracefully
  def self.kill_thread(owner, thread, graceful_timeout = 1, timeout_interval = 0.01, hard_timeout = 1)
    if thread
      if owner and owner.respond_to? :graceful_kill
        if Thread.current != thread
          owner.graceful_kill
          end_time = Time.now.sys + graceful_timeout
          while thread.alive? && ((end_time - Time.now.sys) > 0)
            sleep(timeout_interval)
          end
        else
          Logger.warn "Threads cannot graceful_kill themselves"
        end
      elsif owner
        Logger.info "Thread owner #{owner.class} does not support graceful_kill"
      end
      if thread.alive?
        # If the thread dies after alive? but before backtrace, bt will be nil.
        bt = thread.backtrace

        # Graceful failed
        msg =  "Failed to gracefully kill thread:\n"
        msg << "  Caller Backtrace:\n  #{caller().join("\n  ")}\n"
        msg << "  \n  Thread Backtrace:\n  #{bt.join("\n  ")}\n" if bt
        msg << "\n"
        Logger.warn msg
        thread.kill
        end_time = Time.now.sys + hard_timeout
        while thread.alive? && ((end_time - Time.now.sys) > 0)
          sleep(timeout_interval)
        end
      end
      if thread.alive?
        Logger.error "Failed to kill thread"
      end
    end
  end

  # Close a socket in a manner that ensures that any reads blocked in select
  # will unblock across platforms
  # @param socket The socket to close
  def self.close_socket(socket)
    if socket
      # Calling shutdown and then sleep seems to be required
      # to get select to reliably unblock on linux
      begin
        socket.shutdown(:RDWR)
        sleep(0)
      rescue Exception
        # Oh well we tried
      end
      begin
        socket.close unless socket.closed?
      rescue Exception
        # Oh well we tried
      end
    end
  end
end
