#!/usr/bin/env ruby
#
require 'rubygems'
require 'getoptlong'
require 'json'
require 'yaml'
require 'aws-sdk'
require 'aws-sdk-v1'
require 'time'
#require 'AWS'

TIME_STRING='%s'
##########
# Used to prefix the log message with a date.
def log(str)
  begin
    str.split("\n").each do |str|
      puts "#{Time.now.strftime(TIME_STRING)} pid:#{Process.pid}> #{str}"
    end
    $stdout.flush
  rescue Exception => e
    # do nothing -- just catches unimportant errors when we kill the process
    # and it's in the middle of logging or flushing.
  end
end

config_file = "config.yml"
apikey = nil
@apihost = nil
@debug = false
@verbose = false
@freq = 60  # update frequency in seconds
@interupted = false
@supported_services = [ 'ec2', 'elb', 'rds', 'billing', 'sqs' ]
@worker_pids = []

####################################################################


# Look for config file
@config = YAML.load(File.open(config_file))

if !@config.nil?
  if !@config["aws"].nil?
    @services = @config['aws']['services']
    log "Reading config: services are #{@services.inspect}\n"

    @regions = @config['aws']['regions']
    @regions = ['eu-west-1'] if !@regions || @regions.length == 0
    log "Reading config: regions are #{@regions.inspect}\n"

  end 
        @graphite_host= @config['graphite']['host']
        @graphite_port= @config['graphite']['port']
        @graphite_path= @config['graphite']['path']
        puts "Reading config: graphite params are #{@graphite.inspect}\n"
else
  log "You need to have a config.yml to set your AWS credentials"
  exit
end

if @services.length == 0
  log "No AWS services listed in the config file."
  log "Nothing will be monitored!"
  exit
end

@freq = 60 if ![5, 15, 60, 300, 900, 3600, 21600].include?(@freq)
log "Update frequency set to #{@freq}s."

####################################################################
def fetch_cloudwatch_stats(namespace, metric_name, stats, dimensions, cl=nil, duration=@freq*4)

  duration = 300 if duration < 300
  # need to create it fresh every time because we can switch regions arbitrarily
  start_time = (Time.now - duration).iso8601

  begin
    cl ||= AWS::CloudWatch::Client.new()
    stats_hash = { :namespace => namespace,
                   :metric_name => metric_name,
                   :dimensions => dimensions,
                   :start_time => start_time,
                   :end_time => Time.now.utc.iso8601,
                   :period => @freq,
                   :statistics => stats }
    stats = cl.get_metric_statistics(stats_hash)
    if stats && stats[:datapoints] && stats[:datapoints][0] && stats[:datapoints][0][:timestamp]
      # Cloudwatch doesn't necessarily sort the values.  Ensure that they are.
      stats[:datapoints].sort!{|a,b| a[:timestamp] <=> b[:timestamp]}
    end
    log "fetch_cl_st:  cl               : #{cl.inspect}" if @debug
    log "fetch_cl_st:  stats_hash (post):    #{stats_hash.inspect}" if @debug
    log "fetch_cl_st:  stats     (reply):    #{stats.inspect}" if @debug
    #log "fetch_cl_st:  cl:  #{cl.inspect}" if @debug

  rescue Exception => e
    log "Error getting cloudwatch stats: #{metric_name} [skipping]"
    log "Stats hash: #{stats_hash.inspect}" if @debug
    log e.inspect if @debug
    log e.backtrace.join("\n") if @debug
    stats = nil
  end
  return stats
end
                       
####################################################################

def monitor_aws_rds(group_name)
  log "Monitoring AWS RDS.."

  @timestamp = Time.now.strftime(TIME_STRING)

  @aws_config_default = { :access_key_id => @config["aws"]["access_key_id"],
                          :secret_access_key => @config["aws"]["secret_access_key"],
                          :max_retries => 2,
                          :http_open_timeout => 5,
                          :http_read_timeout => 10 }
  
  graphite_host= @config["graphite"]["host"]
  graphite_port= @config['graphite']["port"]
  graphite_path= @config["graphite"]["path"]
                          
  while !@interupted do
    return if @interrupted
    @regions.each do |region|
      begin
        AWS.config(@aws_config_default.merge({
          :rds_endpoint => "rds.#{region}.amazonaws.com",
          :ec2_endpoint => "ec2.#{region}.amazonaws.com",
          :cloud_watch_endpoint => "monitoring.#{region}.amazonaws.com"
        }))
        rds = AWS::RDS.new()

        cl = AWS::CloudWatch::Client.new()

        dbs = rds.db_instances()
        dbs.each do |db|
          return if @interrupted
          metrics = {}
          instance = db.db_instance_id
        
          stats = fetch_cloudwatch_stats("AWS/RDS", "DiskQueueDepth", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}], cl)

          if stats != nil && stats[:datapoints].length > 0
            send_to_graphite("#{@graphite_path}.#{db.db_instance_id}.DiskQueueDepth #{stats[:datapoints][-1][:average]}  #{@timestamp}") 
            log "RDS: #{db.db_instance_id} #{stats[:datapoints][-1][:average]} queue depth" if @debug
            metrics["DiskQueueDepth"] = stats[:datapoints][-1][:average].to_i
          else
            metrics["DiskQueueDepth"] = 0
          end

          stats = fetch_cloudwatch_stats("AWS/RDS", "ReadLatency", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}], cl)
          if stats != nil && stats[:datapoints].length > 0
            send_to_graphite( "#{@graphite_path}.#{db.db_instance_id}.ReadLatency #{stats[:datapoints][-1][:average]}  #{@timestamp}")
            log "RDS: #{db.db_instance_id} #{stats[:datapoints][-1][:average]*1000} read latency (ms)" if @debug
            metrics["ReadLatency"] = stats[:datapoints][-1][:average]*1000
          else
            metrics["ReadLatency"] = 0
          end

          stats = fetch_cloudwatch_stats("AWS/RDS", "WriteLatency", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}], cl)
          if stats != nil && stats[:datapoints].length > 0
            send_to_graphite( "#{@graphite_path}.#{db.db_instance_id}.WriteLatency #{stats[:datapoints][-1][:average]}  #{@timestamp}")
            log "RDS: #{db.db_instance_id} #{stats[:datapoints][-1][:average]*1000} write latency (ms)" if @debug
            metrics["WriteLatency"] = stats[:datapoints][-1][:average]*1000
          else
            metrics["WriteLatency"] = 0
          end

          stats = fetch_cloudwatch_stats("AWS/RDS", "CPUUtilization", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}], cl)
          if stats != nil && stats[:datapoints].length > 0
            send_to_graphite( "#{@graphite_path}.#{db.db_instance_id}.CPUUtilization #{stats[:datapoints][-1][:average]}  #{@timestamp}")
            log "RDS: #{db.db_instance_id} #{stats[:datapoints][-1][:average]} CPUUtilization" if @debug
            metrics["CPUUtilization"] = stats[:datapoints][-1][:average]
          else
            metrics["CPUUtilization"] = 0
          end

          stats = fetch_cloudwatch_stats("AWS/RDS", "FreeableMemory", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}], cl)
          if stats != nil && stats[:datapoints].length > 0
            send_to_graphite( "#{@graphite_path}.#{db.db_instance_id}.FreeableMemory #{stats[:datapoints][-1][:average]}  #{@timestamp}")
            log "RDS: #{db.db_instance_id} #{stats[:datapoints][-1][:average]/1048576} FreeableMemory" if @debug
            metrics["FreeableMemory"] = stats[:datapoints][-1][:average]/1048576
          else
            metrics["FreeableMemory"] = 0
          end

          stats = fetch_cloudwatch_stats("AWS/RDS", "FreeStorageSpace", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}], cl)
          if stats != nil && stats[:datapoints].length > 0
            send_to_graphite( "#{@graphite_path}.#{db.db_instance_id}.FreeStorageSpace #{stats[:datapoints][-1][:average]}  #{@timestamp}")
            log "RDS: #{db.db_instance_id} #{stats[:datapoints][-1][:average]/1048576} FreeStorageSpace" if @debug
            metrics["FreeStorageSpace"] = stats[:datapoints][-1][:average]/1048576
          else
            metrics["FreeStorageSpace"] = 0
          end


          stats = fetch_cloudwatch_stats("AWS/RDS", "DatabaseConnections", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}], cl)
          if stats != nil && stats[:datapoints].length > 0
            send_to_graphite( "#{@graphite_path}.#{db.db_instance_id}.DatabaseConnections #{stats[:datapoints][-1][:average]}  #{@timestamp}")
            log "RDS: #{db.db_instance_id} #{stats[:datapoints][-1][:average]} DatabaseConnections" if @debug
            metrics["DatabaseConnections"] = stats[:datapoints][-1][:average]
          else
            metrics["DatabaseConnections"] = 0
          end

          stats = fetch_cloudwatch_stats("AWS/RDS", "ReadIOPS", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}], cl)
          if stats != nil && stats[:datapoints].length > 0
            send_to_graphite( "#{@graphite_path}.#{db.db_instance_id}.ReadIOPS #{stats[:datapoints][-1][:average]}  #{@timestamp}")
            log "RDS: #{db.db_instance_id} #{stats[:datapoints][-1][:average]} ReadIOPS" if @debug
            metrics["ReadIOPS"] = stats[:datapoints][-1][:average]
          else
            metrics["ReadIOPS"] = 0
          end

          stats = fetch_cloudwatch_stats("AWS/RDS", "WriteIOPS", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}], cl)
          if stats != nil && stats[:datapoints].length > 0
            send_to_graphite( "#{@graphite_path}.#{db.db_instance_id}.WriteIOPS #{stats[:datapoints][-1][:average]}  #{@timestamp}")
            log "RDS: #{db.db_instance_id} #{stats[:datapoints][-1][:average]} WriteIOPS" if @debug
            metrics["WriteIOPS"] = stats[:datapoints][-1][:average]
          else
            metrics["WriteIOPS"] = 0
          end

          stats = fetch_cloudwatch_stats("AWS/RDS", "ReplicaLag", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}], cl)
          if stats != nil && stats[:datapoints].length > 0
            send_to_graphite( "#{@graphite_path}.#{db.db_instance_id}.ReplicaLag #{stats[:datapoints][-1][:average]}  #{@timestamp}")
            log "RDS: #{db.db_instance_id} #{stats[:datapoints][-1][:average]} ReplicaLag" if @debug
            metrics["ReplicaLag"] = stats[:datapoints][-1][:average]
          else
            metrics["ReplicaLag"] = 0
          end

          log "rds: RDS - #{instance} - #{metrics.inspect}" if @verbose
        end

      rescue Exception => e
        log "Exception getting rds list for region #{region}:\n#{e.to_s}.\nIgnoring and moving on"
        log e.inspect if @debug
        log e.backtrace.join("\n") if @debug
      end
    end
    exit
  end
end

####################################################################


    def send_to_graphite(contents)
      sock = nil
      # contents = contents.join("\n") if contents.kind_of?(Array)

      log("Attempting to send #{contents.length}  bytes " +
        "to #{@graphite_host}:#{@graphite_port} via tcp") if @debug
      puts contents
      begin
        sock = TCPSocket.open("graphite.wuaki.tv", 2003)
        sock.write(contents + "\n")
      rescue Exception => e
        log "Exception sending data to graphite" if debug
        log e.inspect if @debug
        log e.backtrace.join("\n") if @debug
      ensure
        sock.close
      end
    end


####################################################################

def monitor_aws(service)
  if service == "ec2"
    monitor_aws_ec2(@config[service]["group_name"])
  elsif service == "elb"
    monitor_aws_elb(@config[service]["group_name"])
  elsif service == "rds"
    monitor_aws_rds(@config[service]["group_name"])
  elsif service == "billing"
    monitor_aws_billing(@config[service]["group_name"])
  elsif service == "sqs"
    monitor_aws_sqs(@config[service]["group_name"])
  else
    log "Service #{service} not recognized"
  end
end

####################################################################


# metric group check
log "Checking for existence of AWS metric groups"
trap("INT") { parent_interrupt }
trap("TERM") { parent_interrupt }
MAX_RETRIES = 1
last_failure = 0

MAX_SETUP_RETRIES = 5
setup_retries = MAX_SETUP_RETRIES

@services.each do |service|
  if @config[service] && @config[service]["group_name"] && @config[service]["group_label"]

    if !@supported_services.include?(service)
      log "Unknown service #{service}.  Skipping"
      next
    end

    identifiers = nil
    if service == "billing"
      identifiers = ['aws_charges']
    end


      begin
        monitor_aws(service)
      rescue => e
        puts "Error monitoring #{service}.  Retying (#{retries}) more times..."
        log "#{e.inspect}"
        log e.backtrace[0..30].join("\n") if @debug
        raise e if @debug
        sleep 2
        retries -= 1
        retries = MAX_RETRIES if Time.now.to_i - last_failure > 600
        last_failure = Time.now.to_i
        retry if retries > 0
        raise e
      end

    sleep 3  # Give aws api a little breathing space

  end
end



