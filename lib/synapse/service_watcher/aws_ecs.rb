require 'synapse/service_watcher/base'
require 'aws-sdk'

class Synapse::ServiceWatcher
  # AwsEcsWatcher will use the Amazon ECS and EC2 APIs to discover tasks and containers running in your Amazon ECS cluster.
  #
  # Recognized configuration keys are
  #   aws_region: For the region to speak to ECS and EC2 APIs
  #   aws_ecs_cluster: For the ECS cluster in which you want to discover tasks and containers
  #   aws_ecs_family: Is the family of TaskDefinition to discover, for example my_app, or redis
  #   aws_ec2_interface: "private" or "public" to select which EC2 instance IP address & DNS name to use.
  #   container_port: Select which container port to link to. Optional if there is only one port in the task.
  #
  # Usage:
  #   You'll need to create a TaskDefinition for ECS specifying the service which needs discovery, as well as a linked container
  #   including both haproxy and synapse.  In the synapse container include standard synapse configuration with the ECS cluster and
  #   family set.  By default, this container will use the credentials from the EC2 instance to make calls to ECS and EC2.  With
  #   this configuration, your application container will now be able to use standard Docker mechanisms for speaking to a linked
  #   container but it will instead be routed to one of the running tasks for the specific TaskDefinition family.
  #
  class AwsEcsWatcher < BaseWatcher
    
    attr_reader :check_interval
    attr_reader :aws_ec2_interface
    attr_reader :container_port

    def start
      region = @discovery['aws_region'] || ENV['AWS_REGION']
      log.info "Connecting to ECS region: #{region}"
      if @discovery['aws_access_key_id'] && @discovery['aws_secret_access_key']
        @ec2 = Aws::EC2::Client.new(
          region: region,
          access_key_id: @discovery['aws_access_key_id'],
          secret_access_key: @discovery['aws_secret_access_key'] )
        @ecs = Aws::ECS::Client.new(
          region: region,
          access_key_id: @discovery['aws_access_key_id'],
          secret_access_key: @discovery['aws_secret_access_key'] )
      else
        @ec2 = Aws::EC2::Client.new(region: region)
        @ecs = Aws::ECS::Client.new(region: region)
      end
      
      @check_interval = @discovery['check_interval'] || 15.0
      @aws_ec2_interface = @discovery['aws_ec2_interface'] || 'private'
      @container_port = @discovery['container_port'] || 0

      log.info "Looking for tasks in cluster #{@discovery['aws_ecs_cluster']} " \
        "in family #{@discovery['aws_ecs_family']}"
      
      @watcher = Thread.new { watch }
    end

    def discover_tasks
      new_backends = []
      # api_task_ids returns an array of arrays of task_ids, so each iteration gives us 100 or less task_ids to work with
      api_task_ids.each do |task_ids|
        if task_ids.length == 0
          next
        end
        tasks = api_describe_tasks(task_ids)

        container_instance_arns = tasks.map(&:container_instance_arn)
        container_instances = api_describe_container_instances(container_instance_arns)
        #puts "container_instances: #{container_instances}"

        # Need a lookup based on the arn later, so make the map here
        container_instance_map = container_instances.group_by(&:container_instance_arn)

        ec2_instance_ids = container_instances.map(&:ec2_instance_id).uniq
        ec2_instances = api_describe_instances(ec2_instance_ids)

        # Need a fast lookup on the ec2 instance id for IP and DNS later
        ec2_instance_map = {}
        ec2_instances.each do |reservation|
          reservation.instances.each do |instance|
            ec2_instance_map[instance.instance_id] = instance
          end
        end

        # This loop iterates through each task, and for every container found in a single task,
        # it will consider all network bindings with a host port.
        # NOTE there will be ambiguity if mulitple containers in a task have the same container port,
        # so we raise an error in this situation.
        tasks.each do |t|
          log.debug "Found task: #{t}"
          task_nbs = []
          # Make sure to only discover RUNNING tasks so pre-launch or post-shutdown aren't included
          if t.last_status == "RUNNING"
            t.containers.each do |c|
              if c.network_bindings
                c.network_bindings.each do |nb|
                  if nb.host_port
                    task_nbs << nb
                  end
                end
              end
            end
          end
          if task_nbs.size > 0
            # Find the host port matching the specfied container_port
            host_port = 0
            if container_port == 0
              raise ArgumentError, "container_port needs to be specified for service #{@name}, which has #{task_nbs.size} container ports exposed" unless task_nbs.size == 1
              host_port = task_nbs.first.host_port
            else
              task_nbs.each do |nb|
                if nb.container_port == container_port
                  raise ArgumentError, "container_port matches multiple containers in a single task instance for service #{@name}" unless host_port == 0                  
                  host_port = nb.host_port                  
                end
              end
              if host_port == 0
                raise ArgumentError, "container_port does not match any ports for service #{@name}"
              end
            end
            
            # Find the EC2 instance the task is running on
            ci = container_instance_map[t.container_instance_arn].first
            instance = ec2_instance_map[ci.ec2_instance_id]
            if aws_ec2_interface == 'public'
              new_backends << {
                'name' => instance.public_dns_name,
                'host' => instance.public_ip_address,
                'port' => host_port
              }
            else
              new_backends << {
                'name' => instance.private_dns_name,
                'host' => instance.private_ip_address,
                'port' => host_port
              }
            end
          end
        end
      end
      new_backends
    end

    private
    def validate_discovery_opts
      raise ArgumentError, "invalid discovery method #{@discovery['method']}" \
        unless @discovery['method'] == 'aws_ecs'
      raise ArgumentError, "aws_ecs_cluster is required for service #{@name}" \
        unless @discovery['aws_ecs_cluster']
      raise ArgumentError, "aws_ecs_family is required for service #{@name}" \
        unless @discovery['aws_ecs_family']
      raise ArgumentError, "aws_ec2_interface must be either 'public' or 'private'" \
        unless !@discovery['aws_ec2_interface'] || @discovery['aws_ec2_interface'] == 'public' || @discovery['aws_ec2_interface'] == 'private'
    end

    def watch
      last_backends = []
      until @should_exit
        begin
          start = Time.now
          current_backends = discover_tasks

          if last_backends != current_backends
            log.info "#{@name} backends have changed (count #{current_backends.length})."
            last_backends = current_backends
            configure_backends(current_backends)
          else
            log.info "#{@name} backends are unchanged (count #{current_backends.length})."
          end

          sleep_until_next_check(start)
        rescue Exception => e
          log.warn "Error in aws_ecs watcher thread for #{@name} backends: #{e.inspect}"
          log.warn e.backtrace
          # If we don't sleep, we can end up slamming the AWS API
          sleep (1 + rand(5)) # random number between 1 and 5 seconds
        end
      end

      log.info "aws_ecs watcher exited successfully"
    end

    def configure_backends(new_backends)
      if new_backends.empty?
        if @default_servers.empty?
          log.warn "No backends and no default servers for service #{@name};" \
            " using previous backends: #{@backends.inspect}"
        else
          log.warn "No backends for service #{@name};" \
            " using default servers: #{@default_servers.inspect}"
          @backends = @default_servers
        end
      else
        log.info "Discovered #{new_backends.length} backends for service #{@name} : #{new_backends}"
        @backends = new_backends
      end
      @synapse.reconfigure!
    end

    def sleep_until_next_check(start_time)
      sleep_time = check_interval - (Time.now - start_time)
      if sleep_time > 0.0
        sleep(sleep_time)
      end
    end

    def api_task_ids
      @ecs.list_tasks(cluster: @discovery['aws_ecs_cluster'], family: @discovery['aws_ecs_family']).map(&:task_arns)
    end

    def api_describe_tasks(task_ids)
      @ecs.describe_tasks(cluster: @discovery['aws_ecs_cluster'], tasks: task_ids).tasks
    end

    def api_describe_container_instances(container_instance_arns)
      @ecs.describe_container_instances(cluster: @discovery['aws_ecs_cluster'], container_instances: container_instance_arns).container_instances
    end

    def api_describe_instances(ec2_instance_ids)
      @ec2.describe_instances(instance_ids: ec2_instance_ids).reservations
    end

  end
end

