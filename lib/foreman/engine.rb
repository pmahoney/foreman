require "foreman"
require "foreman/process"
require "foreman/utils"
require "pty"
require "tempfile"
require "timeout"
require "term/ansicolor"
require "fileutils"

class Foreman::Engine

  attr_reader :procfile
  attr_reader :directory
  attr_reader :environment
  attr_reader :options

  extend Term::ANSIColor

  COLORS = [ cyan, yellow, green, magenta, red ]

  def initialize(procfile, options={})
    @procfile  = read_procfile(procfile)
    @directory = File.expand_path(File.dirname(procfile))
    @options = options
    @environment = read_environment_files(options[:env])
  end

  def processes
    @processes ||= begin
      @order = []
      procfile.split("\n").inject({}) do |hash, line|
        next hash if line.strip == ""
        name, command = line.split(/\s*:\s+/, 2)
        unless command
          warn_deprecated_procfile!
          name, command = line.split(/ +/, 2)
        end
        process = Foreman::Process.new(name, command)
        process.color = next_color
        @order << process.name
        hash.update(process.name => process)
      end
    end
  end

  def process_order
    processes
    @order.uniq
  end

  def processes_in_order
    process_order.map do |name|
      [name, processes[name]]
    end
  end

  def start
    proctitle "ruby: foreman master"

    processes_in_order.each do |name, process|
      fork process
    end

    trap("TERM") { puts "SIGTERM received"; terminate_gracefully }
    trap("INT")  { puts "SIGINT received";  terminate_gracefully }

    watch_for_termination
  end

  def execute(name)

    fork processes[name]

    trap("TERM") { puts "SIGTERM received"; terminate_gracefully }
    trap("INT")  { puts "SIGINT received";  terminate_gracefully }

    watch_for_termination
  end

  def port_for(process, num, base_port=nil)
    base_port ||= 5000
    offset = processes_in_order.map { |p| p.first }.index(process.name) * 100
    base_port.to_i + offset + num - 1
  end

private ######################################################################

  def fork(process)
    concurrency = Foreman::Utils.parse_concurrency(@options[:concurrency])

    1.upto(concurrency[process.name]) do |num|
      fork_individual(process, num, port_for(process, num, @options[:port]))
    end
  end

  def fork_individual(process, num, port)
    @environment.each { |k,v| ENV[k] = v }

    ENV["PORT"] = port.to_s
    ENV["PS"]   = "#{process.name}.#{num}"

    pid = Process.fork do
      run(process)
    end

    info "started with pid #{pid}", process
    running_processes[pid] = process
  end

  def run(process)
    proctitle "ruby: foreman #{process.name}"
    trap("SIGINT", "IGNORE")

    begin
      Dir.chdir directory do
        PTY.spawn(process.command) do |stdin, stdout, pid|
          trap("SIGTERM") { Process.kill("SIGTERM", pid) }
          until stdin.eof?
            info stdin.gets, process
          end
        end
      end
    rescue PTY::ChildExited, Interrupt, Errno::EIO
      begin
        info "process exiting", process
      rescue Interrupt
      end
    end
  end

  def kill_all(signal="SIGTERM")
    running_processes.each do |pid, process|
      Process.kill(signal, pid) rescue Errno::ESRCH
    end
  end

  def info(message, process=nil)
    print process.color if process
    print "#{Time.now.strftime("%H:%M:%S")} #{pad_process_name(process)} | "
    print Term::ANSIColor.reset
    print message.chomp
    puts
  end

  def error(message)
    puts "ERROR: #{message}"
    exit 1
  end

  def longest_process_name
    @longest_process_name ||= begin
      longest = processes.keys.map { |name| name.length }.sort.last
      longest = 6 if longest < 6 # system
      longest
    end
  end

  def pad_process_name(process)
    name = process ? "#{ENV["PS"]}" : "system"
    name.ljust(longest_process_name + 3) # add 3 for process number padding
  end

  def print_info
    info "currently running processes:"
    running_processes.each do |pid, process|
      info "pid #{pid}", process
    end
  end

  def proctitle(title)
    $0 = title
  end

  def read_procfile(procfile)
    File.read(procfile)
  end

  def watch_for_termination
    pid, status = Process.wait2
    process = running_processes.delete(pid)
    info "process terminated", process
    terminate_gracefully
    kill_all
  rescue Errno::ECHILD
  end

  def running_processes
    @running_processes ||= {}
  end

  def next_color
    @current_color ||= -1
    @current_color  +=  1
    @current_color >= COLORS.length ? "" : COLORS[@current_color]
  end

  def warn_deprecated_procfile!
    return if @already_warned_deprecated
    @already_warned_deprecated = true
    puts "!!! This format of Procfile is deprecated, and will not work starting in v0.12"
    puts "!!! Use a colon to separate the process name from the command"
    puts "!!! e.g.   web: thin start"
  end

  def read_environment_files(filenames)
    environment = {}

    (filenames || "").split(",").map(&:strip).each do |filename|
      error "No such file: #{filename}" unless File.exists?(filename)
      environment.merge!(read_environment(filename))
    end

    environment.merge!(read_environment(".env")) unless filenames
    environment
  end

  def read_environment(filename)
    return {} unless File.exists?(filename)

    File.read(filename).split("\n").inject({}) do |hash, line|
      if line =~ /\A([A-Za-z_]+)=(.*)\z/
        hash[$1] = $2
      end
      hash
    end
  end

  def runner
    File.expand_path("../../../bin/foreman-runner", __FILE__)
  end

  def terminate_gracefully
    info "sending SIGTERM to all processes"
    kill_all "SIGTERM"
    Timeout.timeout(3) { Process.waitall }
  rescue Timeout::Error
    info "sending SIGKILL to all processes"
    kill_all "SIGKILL"
  end

end
