#!/usr/bin/env ruby

@debug = true
@cleanup = false
MOV_PATTERN = /.+.mov$/

require 'yaml'
require 'find'
require 'pathname'
require 'fileutils'
require 'thread'
require 'tempfile'

Thread.abort_on_exception=true

# List of results for a parallel transcode of a given asset
class TestSummary
  attr_accessor :asset_name, :results, :start_time, :end_time, :duration

  def initialize(asset_name, results, start_time, end_time, duration)
    self.asset_name = asset_name
    self.results = results
    self.start_time = start_time
    self.end_time = end_time
    self.duration = duration
  end

  def total
    return elapsed_time(start_time, end_time)
  end

  def percentage
    duration ? "#{(total.to_f / duration.to_f * 100).round}%" : 'N/A'
  end

  def average
    total = 0
    average = 0

    results.each do |result|
      total += result.elapsed
    end

    average = total / results.size if results.size > 0

    average
  end
end

# Timing results for a single (one thread) transcode of a given asset
class TestResult
  attr_accessor :start_time, :end_time, :command

  def initialize(command, start_time, end_time)
    self.command = command
    self.start_time = start_time
    self.end_time = end_time
  end

  def elapsed
    return elapsed_time(start_time, end_time)
  end

end

# Model representation of a single test in the yaml file
class Test
  attr_accessor :name, :command, :ext, :processes, :interlaced_option, :scaling_option

  def initialize(hash)

    self.name = hash['name']
    self.command = hash['command']
    self.ext = hash['ext']
    self.processes = hash['processes']
    self.interlaced_option = hash['interlaced_option'] ? hash['interlaced_option'] : ''
    self.scaling_option = hash['scaling_option'] ? hash['scaling_option'] : ''
  end

  def filename
    filename = cleanup_filename(name)

    "#{filename}_#{processes}#{ext}"
  end
end

# Transcode the List of Files in parallel
def tx(files, results, test, mediainfo, output_path)
  mutex = Mutex.new
  files.each do |src_file| 
    t = Thread.new do
      puts "Transcoding #{src_file}"

      begin
        basename = File.basename(src_file.to_s, '.mov')
        filename = "#{cleanup_filename(basename.to_s)}-#{test.filename}"
        tx_command = process_command_line(test, mediainfo, src_file, File.join(output_path, filename))

        tx_start = Time.now
        success = run(tx_command, filename)
        tx_end = Time.now
      ensure
        if (@cleanup)
          File.unlink(filename)
        end
      end

      if success
        result = TestResult.new(tx_command, tx_start, tx_end)
        mutex.synchronize do
          results << result
        end
      end
    end
  end
end

def cleanup_filename(name)
  filename = name.gsub(/^.*(\\|\/)/, '')
  filename.gsub(/[^0-9A-Za-z.\-\/]/, '_')
end

# Build up command line adding scaling and interlaced options where relevant
def process_command_line(test, mediainfo, src_file, filename)

  command = test.command

  needs_scaling = mediainfo[:needs_scaling]
  scaling_option = needs_scaling ? test.scaling_option : ''

  interlaced = mediainfo[:interlaced]
  interlaced_option = interlaced ? test.interlaced_option : ''

  params = {'INPUT_FILE' => src_file.to_s, 'OUTPUT_FILE' => filename, 'INTERLACED_OPTION' => interlaced_option, 'SCALING_OPTION' => scaling_option}

  params.each do |key, value|
    command = command.gsub(key, value)
  end

  command
end

def wait_for_completion
  main = Thread.main
  current = Thread.current
  all = Thread.list
  all.each {|t| t.join unless t == current or t == main }
end 


# Recursively find all .movs and return as an alphabetically sorted List of Files
def get_source_movs(path)
  files = []
  Find.find(path) do |filename|
    if !FileTest.directory?(filename)
      if filename =~ MOV_PATTERN
        files << Pathname.new(filename)
      end
    end
  end

  files.sort
end

# Process files in turn (in parallel if specified)
def process(files, parallel, test, output_path)

  summaries = []
  files.each do |file|

    mediainfo = mediainfo(file)

    results = []
    tx_files = duplicate(file, output_path, parallel - 1)
    tx_files << file

    start_time = Time.now
    tx(tx_files, results, test, mediainfo, output_path)
    wait_for_completion
    end_time = Time.now

    summary = TestSummary.new(File.basename(file), results, start_time, end_time, mediainfo[:duration])
    summaries << summary
  end

  summaries
end

def duplicate(filename, output_path, parallel)

  duplicates = []
  puts("Making #{parallel} copies of '#{filename}'") if @debug
  ext = File.extname(filename)
  name = File.basename(filename, ext)
  for i in 1..parallel do
    dest = "#{output_path}/#{name}_#{i}#{ext}"
    if (!File.exists?(dest))
      puts("Copying '#{filename}' to '#{dest}'") if @debug
      FileUtils.cp(filename, dest)
    else
      puts("Skipping copying '#{filename}' as '#{dest}' exists") if @debug
    end

    duplicates << dest
  end

  duplicates
end

def run(command, filename)
  log_file = "#{Dir.tmpdir}/#{filename}.txt"

  full_command = "#{command} &> #{log_file}"
  puts("Executing: #{full_command}") if @debug

  success = system(full_command)
  if !success
    $stderr.puts "Got back error code #{$?} from command '#{full_command}'"
    $stderr.puts "Results written to #{log_file}"
  else
    if (File.exists?(log_file))
      File.unlink(log_file)
    end
  end

  success
end

def elapsed_time(start_time, end_time)
  return (end_time - start_time).round
end

def load_yaml(yaml_filename)
  tests = []
  yaml = YAML.load_file(yaml_filename)
  yaml.each do |hash|
    test = Test.new(hash)
    tests << test
  end

  tests
end

# Run mediainfo and determine if clip is interlaced and needs scaling
def mediainfo(filename)

  puts("Running mediainfo on #{filename}") if @debug
  metadata = {}
  output = %x[mediainfo --full '#{filename}']

  lines = output.split(/$/)

  lines.each do |line|
    line.gsub! /^$\n/, ''
    line.strip!

    if (line =~ /duration\s+:\s+(\d+)/i && metadata[:duration] == nil)
      duration = $1.to_i
      metadata[:duration] = duration / 1000
    end
    if (line =~ /scan type\s+:\s+interlaced/i)
      metadata[:interlaced] = true
    end
    if (line =~ /width\s+:\s+1440/i)
      metadata[:needs_scaling] = true
    end
  end

  metadata
end

def clean_output_folder(path)

  puts("Cleaning output folder '#{path}'") if @debug
  Dir.foreach(path) do |filename|
    if !FileTest.directory?("#{path}/#{filename}")
      File.delete("#{path}/#{filename}")
    end
  end
end


def usage
  $stderr.puts
  $stderr.puts "Transcode a series of files and outputs results in CSV format"
  $stderr.puts "Set @debug to true at top of file for more output"
  $stderr.puts "Set @cleanup to false to prevent output files being deleted"
  $stderr.puts "Usage: ffmbc-perf.rb <asset path> <output path> <tests yaml file>"
  exit -1
end

def main(argv)

  source_path = argv[0]
  if (!File.directory?(source_path))
    $stderr.puts("#{source_path} is not a directory or is not readable!")
    usage
  end

  output_path = argv[1]
  if (!File.directory?(output_path))
    $stderr.puts("#{output_path} is not a directory or is not readable!")
    usage
  end

  yaml_filename = argv[2]
  if (!File.exists?(yaml_filename))
    $stderr.puts("#{yaml_filename} is not readable!")
    usage
  end

  host = `hostname`.strip
  ts = Time.now.strftime("%Y-%m-%d-%H.%M")
  csv_filename = "#{File.basename(yaml_filename, File.extname(yaml_filename))}-#{host}-#{ts}.csv"
  if (File.exists?(csv_filename))
    $stderr.puts("#{csv_filename} exists, please remove or rename!")
    usage
  end

  begin
    # Clean up from previous run
    clean_output_folder(output_path)

    tests = load_yaml(yaml_filename)
    movs = get_source_movs(source_path)

    csv_output = []
    csv_header = ['']
    movs.each {|file| csv_header << File.basename(file)}
    csv_output << csv_header

    tests.each do |test|
      processes = test.processes
      processes.each do |parallel|
        puts "Running '#{test.name}' with #{parallel} process(es)"
        csv_test = ["FFmbc test ('#{host}') '#{test.name}' - #{parallel} process(es)"]
        csv_output << csv_test

        summaries = process(movs, parallel.to_i, test, output_path)

        csv_average = ['Average']
        csv_elapsed = ['Elapsed time']
        csv_duration = ['Clip duration']
        csv_percentage = ['Percentage of real time']
        summaries.each do |summary|
          csv_average << summary.average
          csv_elapsed << summary.total
          csv_percentage << summary.percentage
          csv_duration << summary.duration
        end

        csv_output << csv_average
        csv_output << csv_elapsed
        csv_output << csv_percentage
        csv_output << csv_duration
        csv_output << []
        csv_output << []
      end
    end

    csv(csv_output, csv_filename)
    puts("Results written to #{csv_filename}")
  ensure
    if (@cleanup)
      clean_output_folder(output_path)
    end
  end

end

def csv(csv_output, csv_filename)

  File.open(csv_filename, 'a') do |f|
    csv_output.each do |csv_line|
      f.puts csv_line.join(",")
    end
  end

end

if ARGV.length != 3
  usage
end

main(ARGV)
