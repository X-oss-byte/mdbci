# frozen_string_literal: true

require 'json'
require 'yaml'
require 'tty-table'

require_relative 'base_command'
require_relative '../services/aws_service'
require_relative '../services/gcp_service'
require_relative '../services/configuration_reader'

# Command shows list all active instances on Cloud Providers
class ListCloudInstancesCommand < BaseCommand
  HIDDEN_INSTANCES_FILE_NAME = 'hidden-instances.yaml'

  def self.synopsis
    'Show list all active instances on Cloud Providers'
  end

  def show_help
    info = <<-HELP
List cloud instances command shows a list of active machines on GCP and AWS providers and the time they were created.

Add the --json flag for the list_cloud_instances command to show the machine readable text.
Add the --hours NUMBER_OF_HOURS flag for displaying the machine older than this hours.
    HELP
    @ui.info(info)
  end

  def execute
    if @env.show_help
      show_help
      return SUCCESS_RESULT
    end
    show_list
    SUCCESS_RESULT
  end

  def show_list
    @hidden_instances = read_hidden_instances
    print_lists(generate_aws_list, generate_gcp_list)
  end

  def generate_aws_list
    return Result.error('AWS-service is not configured') unless @env.aws_service.configured?

    all_instances = @env.aws_service.instances_list_with_time_and_name.sort do |first, second|
      first[:launch_time] <=> second[:launch_time]
    end
    unless @hidden_instances['aws'].nil?
      all_instances.reject! do |instance|
        @hidden_instances['aws'].include?(instance[:node_name])
      end
    end
    return Result.error('No instances were found in AWS-services') if all_instances.empty?

    select_by_time(all_instances) unless @env.hours.nil?
    Result.ok(all_instances)
  end

  def generate_gcp_list
    return Result.error('GCP-service is not configured') unless @env.gcp_service.configured?

    all_instances = @env.gcp_service.instances_list_with_time
    unless @hidden_instances['gcp'].nil?
      all_instances.reject! do |instance|
        @hidden_instances['gcp'].include?(instance[:node_name])
      end
    end
    return Result.error('No instances were found in GCP-services') if all_instances.empty?

    all_instances.each do |instance|
      instance[:launch_time] = translate_to_right_time(instance[:launch_time])
    end
    select_by_time(all_instances) unless @env.hours.nil?
    Result.ok(all_instances)
  end

  def translate_to_right_time(time)
    date, times = time.split('T')
    year, month, day = date.split('-')
    hour, min, sec = times.split(':')
    Time.utc(year, month, day, hour, min, sec) + 60 * 60 * 7 # Time delay for GCP-provider is 7 hours
  end

  def select_by_time(instances)
    if @env.hours.to_i <= 0
      @ui.error('The number of hours entered incorrectly. All instances will be shown.')
      return instances
    end
    instances.select! do |instance|
      instance[:launch_time] < Time.now.utc - @env.hours.to_i * 60 * 60
    end
  end

  def print_lists(aws_list, gcp_list)
    if @env.json
      @ui.out(in_json_format(aws_list, gcp_list))
    else
      if aws_list.success?
        @ui.info('List all active instances on AWS:')
        @ui.info("\n" + in_table_format(aws_list.value))
      else
        @ui.info(aws_list.error)
      end
      if gcp_list.success?
        @ui.info('List all active instances on GCP:')
        @ui.info("\n" + in_table_format(gcp_list.value))
      else
        @ui.info(gcp_list.error)
      end
    end
  end

  def in_json_format(aws_list, gcp_list)
    aws_list_json = if aws_list.error?
                      { aws: aws_list.error }
                    else
                      { aws: aws_list.value }
                    end
    gcp_list_json = if gcp_list.error?
                      { gcp: gcp_list.error }
                    else
                      { gcp: gcp_list.value }
                    end
    JSON.generate(aws_list_json.merge(gcp_list_json))
  end

  def in_table_format(list)
    table = TTY::Table.new(header: ['Launch time', 'Node name'])
    list.each do |instance|
      table << [instance[:launch_time], instance[:node_name]]
    end
    table.render(:unicode)
  end

  def read_hidden_instances
    YAML.safe_load(File.read(ConfigurationReader.path_to_file(HIDDEN_INSTANCES_FILE_NAME)))
  end
end
