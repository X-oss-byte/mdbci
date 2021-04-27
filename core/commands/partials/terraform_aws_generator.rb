# frozen_string_literal: true

require 'date'
require 'socket'
require 'erb'
require_relative '../../models/result'

# The class generates the Terraform infrastructure file for AWS provider
class TerraformAwsGenerator
  # Initializer.
  # @param configuration_id [String] configuration id
  # @param aws_config [Hash] hash of AWS configuration
  # @param logger [Out] logger
  # @param configuration_path [String] path to directory of generated configuration
  # @param ssh_keys [Hash] ssh keys info in format { public_key_value, private_key_file_path }
  # @param aws_service [AwsService] AWS service
  # @return [Result::Base] generation result.
  def initialize(configuration_id, aws_config, logger, configuration_path, ssh_keys, aws_service)
    @configuration_id = configuration_id
    @configuration_tags = { configuration_id: @configuration_id }
    @aws_config = aws_config
    @ui = logger
    @configuration_path = configuration_path
    @public_key_value = ssh_keys[:public_key_value]
    @private_key_file_path = ssh_keys[:private_key_file_path]
    @aws_service = aws_service
  end

  # Generate a Terraform configuration file.
  # @param node_params [Array<Hash>] list of node params
  # @param configuration_file_path [String] path to generated Terraform infrastructure file
  # @return [Result::Base] generation result.
  # rubocop:disable Metrics/MethodLength
  def generate_configuration_file(node_params, configuration_file_path)
    return Result.error('AWS is not configured') if @aws_config.nil?

    need_vpc = false
    need_standard_security_group = false
    file = File.open(configuration_file_path, 'w')
    file.puts(file_header)
    file.puts(provider_resource)
    result = Result.ok('')
    node_params.each do |node|
      result = generate_instance_params(node).and_then do |instance_params|
        print_node_info(instance_params)
        file.puts(instance_resources(instance_params))
        need_vpc ||= node[:vpc]&.to_s == 'true'
        need_standard_security_group ||= node[:vpc]&.to_s != 'true'
        Result.ok('')
      end
      break if result.error?
    end
    file.puts(standard_security_group_resource) if need_standard_security_group
    file.puts(vpc_partial) if need_vpc
  rescue Errno::ENOENT => e
    Result.error(e.message)
  else
    result
  ensure
    file.close unless file.nil? || file.closed?
  end
  # rubocop:enable Metrics/MethodLength

  # Generate key pair name by configuration id.
  # The name includes an identifier, host name,
  # and configuration name to identify the owner of the key.
  #
  # @param configuration_id [String] configuration id
  # @return [String] key pair name
  def self.generate_key_pair_name(configuration_id, configuration_path)
    hostname = Socket.gethostname
    config_name = File.basename(configuration_path)
    "#{configuration_id}-#{config_name}-#{hostname}"
  end

  private

  # Log the information about the main parameters of the node.
  #
  # @param node_params [Hash] list of the node parameters
  def print_node_info(node_params)
    @ui.info("AWS definition for host:#{node_params[:host]}, ami:#{node_params[:ami]}, user:#{node_params[:user]}")
  end

  def file_header
    <<-HEADER
    # !! Generated content, do not edit !!
    # Generated by MariaDB Continuous Integration Tool (https://github.com/mariadb-corporation/mdbci)
    #### Created #{Time.now} ####
    HEADER
  end

  def provider_resource
    aws_config = @aws_config
    use_existing_vpc = use_existing_vpc?
    template = ERB.new <<-PROVIDER
    provider "aws" {
      version = "~> 2.33"
      profile = "default"
      region = "<%= aws_config['region'] %>"
      access_key = "<%= aws_config['access_key_id'] %>"
      secret_key = "<%= aws_config['secret_access_key'] %>"
    }
    locals {
      <% unless use_existing_vpc %>
        cidr_vpc = "10.1.0.0/16" # CIDR block for the VPC
        cidr_subnet = "10.1.0.0/24" # CIDR block for the subnet
      <% end %>
      availability_zone = "<%= aws_config['availability_zone'] %>" # availability zone to create subnet
    }
    #{key_pair_resource}
    PROVIDER
    template.result(binding)
  end

  def vpc_resources
    <<-VPC_RESOURCES
    resource "aws_vpc" "vpc" {
      cidr_block = local.cidr_vpc
      enable_dns_support = true
      enable_dns_hostnames = true
      #{tags_partial(@configuration_tags)}
    }
    resource "aws_internet_gateway" "igw" {
      vpc_id = aws_vpc.vpc.id
      #{tags_partial(@configuration_tags)}
    }
    resource "aws_subnet" "subnet_public" {
      vpc_id = aws_vpc.vpc.id
      cidr_block = local.cidr_subnet
      map_public_ip_on_launch = true
      availability_zone = local.availability_zone
      #{tags_partial(@configuration_tags)}
    }
    resource "aws_route_table" "rtb_public" {
      vpc_id = aws_vpc.vpc.id
      route {
          cidr_block = "0.0.0.0/0"
          gateway_id = aws_internet_gateway.igw.id
      }
      #{tags_partial(@configuration_tags)}
    }
    resource "aws_route_table_association" "rta_subnet_public" {
      subnet_id = aws_subnet.subnet_public.id
      route_table_id = aws_route_table.rtb_public.id
    }
    VPC_RESOURCES
  end

  def vpc_partial
    resources = [vpc_security_group_resource]
    resources << vpc_resources unless use_existing_vpc?
    resources.join("\n")
  end

  # Generate a connection block for AWS instance resource.
  # @param user [String] user name of instance
  # @return [String] connection block definition.
  def connection_partial(user)
    <<-PARTIAL
    connection {
      type = "ssh"
      private_key = file("#{@private_key_file_path}")
      timeout = "10m"
      agent = false
      user = "#{user}"
      host = self.public_ip
    }
    PARTIAL
  end

  def tags_partial(tags)
    template = ERB.new <<-PARTIAL
    tags = {
      <% tags.each do |tag_key, tag_value| %>
          <%= tag_key %> = "<%= tag_value %>"
        <% end %>
      }
    PARTIAL
    template.result(binding)
  end

  def standard_security_group_resource
    group_name = "#{@configuration_id}-standard-security-group"
    tags_block = tags_partial(@configuration_tags)
    template = ERB.new <<-SECURITY_GROUP
    resource "aws_security_group" "security_group" {
      name = "<%= group_name %>"
      description = "MDBCI <%= group_name %> auto generated"
      ingress {
        from_port = 0
        protocol = "tcp"
        to_port = 65535
        cidr_blocks = ["0.0.0.0/0"]
      }
      <%= tags_block %>
    }
    SECURITY_GROUP
    template.result(binding)
  end

  # Generate a security_group resource definition for AWS infrastructure.
  # @return [String] security group resource definition.
  def vpc_security_group_resource
    group_name = "#{@configuration_id}-vpc-security-group"
    tags_block = tags_partial(@configuration_tags)
    <<-SECURITY_GROUP
    resource "aws_security_group" "security_group_vpc" {
      name = "#{group_name}"
      description = "MDBCI #{group_name} auto generated"
      ingress {
        from_port = 0
        protocol = "-1"
        to_port = 0
        cidr_blocks = ["0.0.0.0/0"]
      }
      vpc_id = #{vpc_id}
      egress {
        from_port = 0
        to_port = 0
        protocol = -1
        cidr_blocks = ["0.0.0.0/0"]
      }
      #{tags_block}
    }
    SECURITY_GROUP
  end

  # Generate Terraform configuration resources for instance.
  # @param node_params [Hash] list of the node parameters
  # @return [String] generated resources for instance.
  # rubocop:disable Metrics/MethodLength
  def instance_resources(node_params)
    connection_block = connection_partial(node_params[:user])
    tags_block = tags_partial(node_params[:tags])
    template = ERB.new <<-AWS
    resource "aws_instance" "<%= name %>" {
      ami = "<%= ami %>"
      instance_type = "<%= default_instance_type %>"
      key_name = aws_key_pair.ec2key.key_name
      <% if vpc %>
        vpc_security_group_ids = [aws_security_group.security_group_vpc.id]
        subnet_id = <%= subnet_id %>
        <% unless use_existing_vpc %>
          depends_on = [aws_route_table_association.rta_subnet_public, aws_route_table.rtb_public]
        <% end %>
      <% else %>
        security_groups = ["default", aws_security_group.security_group.name]
      <% end %>
      <%= tags_block %>
      root_block_device {
        volume_size = 500
      }
      <%= connection_block %>
      user_data = <<-EOT
      #!/bin/bash
      sed -i -e 's/^Defaults.*requiretty/# Defaults requiretty/g' /etc/sudoers
      EOT
    }
    output "<%= name %>_network" {
      value = {
        user = "<%= user %>"
        private_ip = aws_instance.<%= name %>.private_ip
        public_ip = aws_instance.<%= name %>.public_ip
        key_file = "<%= key_file %>"
        hostname = "ip-${replace(aws_instance.<%= name %>.private_ip, ".", "-")}"
      }
    }
    AWS
    template.result(OpenStruct.new(node_params).instance_eval { binding })
  end
  # rubocop:enable Metrics/MethodLength

  def key_pair_resource
    key_pair_name = self.class.generate_key_pair_name(@configuration_id, @configuration_path)
    <<-KEY_PAIR_RESOURCE
    resource "aws_key_pair" "ec2key" {
      key_name = "#{key_pair_name}"
      public_key = "#{@public_key_value}"
    }
    KEY_PAIR_RESOURCE
  end

  def vpc_id
    return "\"#{@aws_config['vpc_id']}\"" if use_existing_vpc?

    'aws_vpc.vpc.id'
  end

  def subnet_id
    return "\"#{@aws_config['subnet_id']}\"" if use_existing_vpc?

    'aws_subnet.subnet_public.id'
  end

  # Returns false if a new vpc resources need to be generated for the current configuration, otherwise true.
  # @return [Boolean] result.
  def use_existing_vpc?
    @aws_config['use_existing_vpc']
  end

  # Generate a instance params for the configuration file.
  # @param node_params [Hash] list of the node parameters
  # @return [Result::Base] instance params
  def generate_instance_params(node_params)
    tags = @configuration_tags.merge(hostname: Socket.gethostname,
                                     username: Etc.getlogin,
                                     machinename: node_params[:name],
                                     full_config_path: @configuration_path)
    node_params = node_params.merge({ tags: tags,
                                      key_file: @private_key_file_path,
                                      subnet_id: subnet_id,
                                      use_existing_vpc: use_existing_vpc? })
    machine_types = @aws_service.machine_types_list(node_params[:supported_instance_types])
    CloudServices.choose_instance_type(machine_types, node_params).and_then do |machine_type|
      Result.ok(node_params.merge(machine_type: machine_type))
    end
  end
end
