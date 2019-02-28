# frozen_string_literal: true

require 'date'
require 'fileutils'
require 'json'
require 'pathname'
require 'securerandom'
require 'socket'
require 'erb'
require 'set'
require_relative 'base_command'
require_relative '../out'
require_relative '../models/configuration.rb'
require_relative '../services/shell_commands'

# Command generates
class GenerateCommand < BaseCommand
  def self.synopsis
    'Generate a configuration based on the template.'
  end

  def self.role_file_name(path, role)
    "#{path}/#{role}.json"
  end

  def self.node_config_file_name(path, role)
    "#{path}/#{role}-config.json"
  end

  def vagrant_file_header
    <<-HEADER
# !! Generated content, do not edit !!
# Generated by MariaDB Continuous Integration Tool (https://github.com/mariadb-corporation/mdbci)
#### Created #{Time.now} ####
    HEADER
  end

  def aws_provider_config(aws_config, pemfile_path, keypair_name)
    <<-PROVIDER
    ###           AWS Provider config block                 ###
    ###########################################################
    config.vm.box = "dummy"

    config.vm.provider :aws do |aws, override|
      aws.keypair_name = "#{keypair_name}"
      override.ssh.private_key_path = "#{pemfile_path}"
      aws.region = "#{aws_config['region']}"
      aws.security_groups = ['default', '#{aws_config['security_group']}']
      aws.access_key_id = "#{aws_config['access_key_id']}"
      aws.secret_access_key = "#{aws_config['secret_access_key']}"
      aws.user_data = "#!/bin/bash\nsed -i -e 's/^Defaults.*requiretty/# Defaults requiretty/g' /etc/sudoers"
      override.nfs.functional = false
    end ## of AWS Provider config block
    PROVIDER
  end

  def provider_config
    <<-CONFIG
### Default (VBox, Libvirt) Provider config ###
#######################################################
# Network autoconfiguration
config.vm.network "private_network", type: "dhcp"
config.vm.boot_timeout = 60
    CONFIG
  end

  def vagrant_config_header
    <<-HEADER
### Vagrant configuration block  ###
####################################
Vagrant.configure(2) do |config|
    HEADER
  end

  def vagrant_config_footer
    <<-FOOTER
end
### end of Vagrant configuration block
    FOOTER
  end

  # Vagrantfile for Vbox provider
  # rubocop:disable Metrics/MethodLength
  # The method returns a template; decomposition will complicate the code.
  def get_virtualbox_definition(_cookbook_path, node_params)
    template = ERB.new <<-VBOX
      config.vm.define '<%= name %>' do |box|
        box.vm.box = '<%= boxurl %>'
        box.vm.hostname = '<%= host %>'
        <% if ssh_pty %>
           box.ssh.pty = true
        <% end %>
        <% if template_path %>
           box.vm.synced_folder '<%= template_path %>', '/home/vagrant/cnf_templates'
        <% end %>
        box.vm.provider :virtualbox do |vbox|
          <% if vm_mem %>
             vbox.memory = <%= vm_mem %>
          <% end %>
          vbox.name = "\#{File.basename(File.dirname(__FILE__))}_<%= name %>"
        end
      end
    VBOX
    template.result(OpenStruct.new(node_params).instance_eval { binding })
  end
  # rubocop:enable Metrics/MethodLength

  # Vagrantfile for Libvirt provider
  # rubocop:disable Metrics/MethodLength
  # The method returns a template; decomposition will complicate the code.
  def get_libvirt_definition(_cookbook_path, path, node_params)
    node_params = node_params.merge(expand_path: File.expand_path(path), ipv6: @env.ipv6)
    template = ERB.new <<-LIBVIRT
      #  --> Begin definition for machine: <%= name %>
      config.vm.define '<%= name %>' do |box|
        box.vm.box = '<%= boxurl %>'
        box.vm.hostname = '<%= host %>'
        <% if ssh_pty %>
          box.ssh.pty = true
        <% end %>
        <% if template_path %>
          box.vm.synced_folder '<%= template_path %>', '/home/vagrant/cnf_templates', type:'rsync'
        <% else %>
          box.vm.synced_folder '<%= expand_path %>', '/vagrant', type: 'rsync'
        <% end %>
        <% if ipv6 %>
          box.vm.network :public_network, :dev => 'virbr0', :mode => 'bridge', :type => 'bridge'
        <% end %>
        box.vm.provider :libvirt do |qemu|
          qemu.driver = 'kvm'
          qemu.cpu_mode = 'host-passthrough'
          qemu.cpus = <%= vm_cpu %>
          qemu.memory = <%= vm_mem %>
        end
      end #  <-- End of Qemu definition for machine: <%= name %>
    LIBVIRT
    template.result(OpenStruct.new(node_params).instance_eval { binding })
  end
  # rubocop:enable Metrics/MethodLength

  # Get the package manager name by the platform name.
  #
  # @param platform [String] name of the platform
  # @return [String] name of the package manager
  # @raise RuntimeError if platform is unknown.
  def get_package_manager_name(platform)
    case platform
    when 'ubuntu', 'debian' then 'apt'
    when 'centos', 'redhat' then 'yum'
    when 'suse' then 'zypper'
    else raise 'Unknown platform'
    end
  end

  # Convert the Hash to the String.
  #
  # @param hash [Hash] hash of the tags
  # @return [String] converted hash in the format "{ 'key' => 'value', ... }"
  def generate_aws_tag(hash)
    vagrantfile_tags = hash.map { |key, value| "'#{key}' => '#{value}'" }.join(', ')
    "{ #{vagrantfile_tags} }"
  end

  # Vagrantfile for AWS provider
  # rubocop:disable Metrics/MethodLength
  # The method returns a template; decomposition will complicate the code.
  def get_aws_vms_definition(_cookbook_path, tags, node_params)
    node_params = node_params.merge(tags: tags)
    template = ERB.new <<-AWS
      #  --> Begin definition for machine: <%= name %>
      config.vm.define '<%= name %>' do |box|
        <% if ssh_pty %>
          box.ssh.pty = true
        <% end %>
        <% if template_path %>
          box.vm.synced_folder '<%=template_path %>', '/home/vagrant/cnf_templates', type: 'rsync'
        <% end %>
        box.vm.provider :aws do |aws, override|
          aws.ami = '<%= amiurl %>'
          aws.tags = <%= tags %>
          aws.instance_type = '<%= instance %>'
          <% if device_name %>
            aws.block_device_mapping = [{ 'DeviceName' => '<%= device_name %>', 'Ebs.VolumeSize' => 100 }]
          <% end %>
          override.ssh.username = '<%= user %>'
        end
      end #  <-- End of AWS definition for machine: <%= name %>
    AWS
    template.result(OpenStruct.new(node_params).instance_eval { binding })
  end
  # rubocop:enable Metrics/MethodLength

  # Make the list of the product parameters.
  #
  # @param product_name [String] name of the product for install
  # @param product [Hash] parameters of the product to configure from configuration file
  # @param box information about the box
  # @param repo [String] repo
  # @return [Hash] pretty formatted role description in JSON format.
  def make_product_config(product_name, product, box, repo)
    repo = @env.repos.findRepo(product_name, product, box) if repo.nil?
    raise "Repo for product #{product['name']} #{product['version']} for #{box} not found" if repo.nil?

    config = { 'version': repo['version'], 'repo': repo['repo'], 'repo_key': repo['repo_key'] }
    if !product['cnf_template'].nil? && !product['cnf_template_path'].nil?
      config['cnf_template'] = product['cnf_template']
      config['cnf_template_path'] = product['cnf_template_path']
    end
    config['node_name'] = product['node_name'] unless product['node_name'].nil?
    attribute_name = @env.repos.attribute_name(product_name)
    { "#{attribute_name}": config }
  end

  # Make the list of the role parameters in the JSON-format.
  #
  # @param name [String] internal name of the machine specified in the template
  # @param product_config [Hash] list of the product parameters
  # @param recipe_name [String] name of the recipe
  # @return [String] pretty formatted role description in JSON format.
  def make_role_json(name, product_config, recipe_name)
    role = {
      name: name,
      default_attributes: {},
      override_attributes: product_config,
      json_class: 'Chef::Role',
      description: '',
      chef_type: 'role',
      run_list: ['recipe[mdbci_provision_mark::remove_mark]',
                 "recipe[#{recipe_name}]",
                 'recipe[mdbci_provision_mark::default]']
    }
    JSON.pretty_generate(role)
  end

  # Generate the role description for the specified node.
  #
  # @param name [String] internal name of the machine specified in the template
  # @param product [Hash] parameters of the product to configure from configuration file
  # @param box information about the box
  # @return [String] pretty formatted role description in JSON format
  # rubocop:disable Metrics/MethodLength
  # The method performs a single function; decomposition of the method will complicate the code.
  def get_role_description(name, product, box)
    error_text = "#NONE, due invalid repo name \n"
    repo = nil
    if !product['repo'].nil?
      repo_name = product['repo']
      @ui.info("Repo name: #{repo_name}")
      unless @env.repos.knownRepo?(repo_name)
        @ui.warning("Unknown key for repo #{repo_name} will be skipped")
        return error_text
      end
      @ui.info("Repo specified [#{repo_name}] (CORRECT), other product params will be ignored")
      repo = @env.repos.getRepo(repo_name)
      product_name = @env.repos.productName(repo_name)
    else
      product_name = product['name']
    end
    recipe_name = @env.repos.recipe_name(product_name)
    product_config = if product_name != 'packages'
                       make_product_config(product_name, product, box, repo)
                     else
                       {}
                     end
    @ui.info("Recipe #{recipe_name}")
    make_role_json(name, product_config, recipe_name)
  end
  # rubocop:enable Metrics/MethodLength

  # Check for the existence of a path, create it if path is not exists or clear path
  # if it is exists and override parameter is true.
  #
  # @param path [String] path of the configuration file
  # @param override [Bool] clean directory if it is already exists
  # @return [Bool] false if directory path is already exists and override is false, otherwise - true.
  def check_path(path, override)
    if Dir.exist?(path) && !override
      @ui.error("Folder already exists: #{path}. Please specify another name or delete")
      return false
    end
    FileUtils.rm_rf(path)
    Dir.mkdir(path)
    true
  end

  # Check for MDBCI node names defined in the template to be valid Ruby object names.
  #
  # @param config [Hash] value of the configuration file
  # @return [Bool] true if all nodes names are valid, otherwise - false.
  def check_nodes_names(config)
    invalid_names = config.map do |node|
      (node[0] =~ /^[a-zA-Z_]+[a-zA-Z_\d]*$/).nil? ? node[0] : nil
    end.compact
    return true if invalid_names.empty?

    @ui.error("Invalid nodes names: #{invalid_names}. "\
              'Nodes names defined in the template to be valid Ruby object names.')
    false
  end

  # Check for the box emptiness and existence of a box in the boxes list.
  #
  # @param box [String] name of the box
  # @param boxes a list of boxes known to the configuration.
  def box_valid?(box, boxes)
    return false if box.empty?

    !boxes.getBox(box).nil?
  end

  # Make a hash list of, generic for all providers, node parameters by a node configuration and
  # information of the box parameters.
  #
  # @param node [Array] information of the node from configuration file
  # @param box_params [Hash] information of the box parameters
  # @return [Hash] list of the node parameters.
  def make_generic_node_params(node, box_params)
    params = {
      name: node[0].to_s,
      host: node[1]['hostname'].to_s,
      vm_mem: node[1]['memory_size'].nil? ? '1024' : node[1]['memory_size'].to_s,
      vm_cpu: (@env.cpu_count || node[1]['cpu_count'] || '1').to_s,
      provider: box_params['provider'].to_s
    }
    params[:ssh_pty] = box_params['ssh_pty'] == 'true' unless box_params['ssh_pty'].nil?
    params
  end

  # Make a hash list of the provider-specific node parameters by a information of the box parameters.
  #
  # @param box_params [Hash] information of the box parameters
  # @return [Hash] list of the node parameters.
  def make_provider_specific_node_params(box_params)
    if box_params['provider'] == 'aws'
      { amiurl: box_params['ami'].to_s, user: box_params['user'].to_s,
        instance: box_params['default_instance_type'].to_s,
        device_name: @aws_service.device_name_for_ami(box_params['ami'].to_s) }
    else
      { boxurl: box_params['box'].to_s, platform: box_params['platform'].to_s,
        platform_version: box_params['platform_version'].to_s }
    end
  end

  # Make a hash list of the node parameters by a node configuration and
  # information of the box parameters. Includes generic and provider-specific node parameters.
  #
  # @param node [Array] information of the node from configuration file
  # @param box_params [Hash] information of the box parameters
  # @return [Hash] list of the node parameters.
  def make_node_params(node, box_params)
    make_generic_node_params(node, box_params).merge(make_provider_specific_node_params(box_params))
  end

  # Log the information about the main parameters of the node.
  #
  # @param node_params [Hash] list of the node parameters
  # @param box [String] name of the box.
  def print_node_info(node_params, box)
    @ui.info("Requested memory #{node_params[:vm_mem]}")
    @ui.info("Requested number of CPUs #{node_params[:vm_cpu]}")
    if node_params[:provider] == 'aws'
      @ui.info("AWS definition for host:#{node_params[:host]}, ami:#{node_params[:amiurl]}, "\
               "user:#{node_params[:user]}, instance:#{node_params[:instance]}")
    end
    @ui.info("config.ssh.pty option is #{node_params[:ssh_pty]} for a box #{box}") unless node_params[:ssh_pty].nil?
  end

  # Generate a node definition for the Vagrantfile, depending on the provider
  # uses the appropriate generation method.
  #
  # @param node_params [Hash] list of the node parameters
  # @param cookbook_path [String] path of the cookbook
  # @param path [String] path of the configuration file
  # @return [String] node definition for the Vagrantfile.
  def generate_node_defenition(node_params, cookbook_path, path)
    case node_params[:provider]
    when 'virtualbox'
      get_virtualbox_definition(cookbook_path, node_params)
    when 'aws'
      tags = generate_aws_tag('hostname' => Socket.gethostname, 'username' => Etc.getlogin,
                              'full_config_path' => File.expand_path(path), 'machinename' => node_params[:name])
      get_aws_vms_definition(cookbook_path, tags, node_params)
    when 'libvirt'
      get_libvirt_definition(cookbook_path, path, node_params)
    else
      @ui.warning('Configuration type invalid! It must be vbox, aws or libvirt type. Check it, please!')
      ''
    end
  end

  # Make a list of node parameters, create the role and node_config files, generate
  # node definition for the Vagrantfile.
  #
  # @param node [Array] internal name of the machine specified in the template
  # @param boxes a list of boxes known to the configuration
  # @param path [String] path of the configuration file
  # @param cookbook_path [String] path of the cookbook
  # @return [String] node definition for the Vagrantfile.
  # rubocop:disable Metrics/MethodLength
  # Further decomposition of the method will complicate the code.
  def node_definition(node, boxes, path, cookbook_path)
    box = node[1]['box'].to_s
    unless box.empty?
      node_params = make_node_params(node, boxes.getBox(box))
      print_node_info(node_params, box)
    end
    provisioned = !node[1]['product'].nil?
    if provisioned
      product = node[1]['product']
      node_params[:template_path] = product['cnf_template_path'] unless product['cnf_template_path'].nil?
    else
      product = { 'name' => 'packages' }
    end
    @ui.info("Machine #{node_params[:name]} is provisioned by #{product}")
    # box with mariadb, maxscale provision - create role
    role = get_role_description(node_params[:name], product, box)
    IO.write(GenerateCommand.role_file_name(path, node_params[:name]), role)
    IO.write(GenerateCommand.node_config_file_name(path, node_params[:name]),
             JSON.pretty_generate('run_list' => ["role[#{node_params[:name]}]"]))
    # generate node definition
    if box_valid?(box, boxes)
      generate_node_defenition(node_params, cookbook_path, path)
    else
      @ui.warning("Box #{box} is not installed or configured ->SKIPPING")
      ''
    end
  end
  # rubocop:enable Metrics/MethodLength

  # Generate the key pair for the AWS.
  #
  # @param path [String] path of the configuration file.
  def generate_key_pair(path)
    full_path = File.expand_path(path)
    key_pair = @env.aws_service.generate_key_pair(full_path)
    path_to_keyfile = File.join(full_path, 'maxscale.pem')
    File.write(path_to_keyfile, key_pair.key_material)
    path_to_keypair_file = File.join(full_path, Configuration::AWS_KEYPAIR_NAME)
    File.write(path_to_keypair_file, key_pair.key_name)
    [path_to_keyfile, key_pair.key_name]
  end

  # Generate a Vagrantfile.
  #
  # @param path [String] path of the configuration file
  # @param config [Hash] value of the configuration file
  # @param boxes a list of boxes known to the configuration
  # @param provider [String] provider name of the nodes
  # @param cookbook_path [String] path of the cookbook.
  # rubocop:disable Metrics/MethodLength
  # The method performs a single function; decomposition of the method will complicate the code.
  def generate_vagrant_file(path, config, boxes, provider, cookbook_path)
    vagrant = File.open(File.join(path, 'Vagrantfile'), 'w')
    vagrant.puts vagrant_file_header, vagrant_config_header
    if provider == 'aws'
      @ui.info('Generating AWS configuration')
      path_to_keyfile, keypair_name = generate_key_pair(path)
      vagrant.puts aws_provider_config(@env.tool_config['aws'], path_to_keyfile, keypair_name)
    else
      @ui.info('Generating libvirt/VirtualBox configuration')
      vagrant.puts provider_config
    end
    config.each do |node|
      unless node[1]['box'].nil?
        @ui.info("Generating node definition for [#{node[0]}]")
        vagrant.puts node_definition(node, boxes, path, cookbook_path)
      end
    end
    vagrant.puts vagrant_config_footer
    vagrant.close
    SUCCESS_RESULT
  rescue RuntimeError => e
    @ui.error(e.message)
    @ui.error('Configuration is invalid')
    @env.aws_service.delete_key_pair(keypair_name) if provider == 'aws'
    vagrant.close
    FileUtils.rm_rf(path)
    ERROR_RESULT
  end
  # rubocop:enable Metrics/MethodLength

  # Check parameters and generate a Vagrantfile.
  #
  # @param path [String] path of the configuration file
  # @param config [Hash] value of the configuration file
  # @param boxes a list of boxes known to the configuration
  # @param override [Bool] clean directory if it is already exists
  # @param provider [String] provider name of the nodes
  # @return [Integer] SUCCESS_RESULT if the execution of the method passed without errors,
  # otherwise - ERROR_RESULT or ARGUMENT_ERROR_RESULT.
  def generate(path, config, boxes, override, provider)
    # TODO: MariaDb Version Validator
    checks_result = check_path(path, override) && check_nodes_names(config)
    return ARGUMENT_ERROR_RESULT unless checks_result

    cookbook_path = if config['cookbook_path'].nil?
                      File.join(@env.mdbci_dir, 'recipes', 'cookbooks') # default cookbook path
                    else
                      config['cookbook_path']
                    end
    @ui.info("Global cookbook_path = #{cookbook_path}")
    @ui.info("Nodes provider = #{provider}")
    return ERROR_RESULT if generate_vagrant_file(path, config, boxes, provider, cookbook_path) == ERROR_RESULT
    return SUCCESS_RESULT unless File.size?(File.join(path, 'Vagrantfile')).nil?

    @ui.error('Generated Vagrantfile is empty! Please check configuration file and regenerate it.')
    ERROR_RESULT
  end

  # Generate provider and template files in the configuration directory.
  #
  # @param path [String] configuration directory
  # @param provider [String] nodes provider
  # @raise RuntimeError if provider or template files already exists.
  def generate_provider_and_template_files(path, provider)
    provider_file = File.join(path, 'provider')
    template_file = File.join(path, 'template')
    raise 'Configuration \'provider\' file already exists' if File.exist?(provider_file)
    raise 'Configuration \'template\' file already exists' if File.exist?(template_file)

    File.open(provider_file, 'w') { |f| f.write(provider) }
    File.open(template_file, 'w') { |f| f.write(File.expand_path(@env.configFile)) }
  end

  # Check that all boxes specified in the the template are identical.
  #
  # @param providers [Array] list of nodes providers from config file
  # @return [Bool] false if unable to detect the provider for all boxes or
  # there are several providers in the template, otherwise - true.
  def check_providers(providers)
    if providers.empty?
      @ui.error('Unable to detect the provider for all boxes. Please fix the template.')
      return false
    end
    unique_providers = Set.new(providers)
    return true if unique_providers.size == 1

    @ui.error("There are several node providers defined in the template: #{unique_providers.to_a.join(', ')}.\n"\
              'You can specify only nodes from one provider in the template.')
    false
  end

  # Check that all boxes specified in the the template are exist in the boxes.json
  # and all providers specified in the the template are identical.
  # Save provider to the @nodes_provider if check successful.
  #
  # @param configs [Array] list of nodes specified in template
  # @return [Bool] true if the result of passing all checks successful, otherwise - false.
  # rubocop:disable Metrics/MethodLength
  # The method performs a single function; decomposition of the method will complicate the code.
  def load_nodes_provider_and_check_it(configs)
    nodes = configs.map { |node| %w[aws_config cookbook_path].include?(node[0]) ? nil : node }.compact.to_h
    providers = nodes.map do |node_name, node_params|
      box = node_params['box'].to_s
      if box.empty?
        @ui.error("Box in #{node_name} is not found")
        return false
      end
      box_params = @env.boxes.getBox(box)
      if box_params.nil?
        @ui.error("Box #{box} from node #{node_name} not found in #{@env.boxes_dir}!")
        return false
      end
      box_params['provider'].to_s
    end
    return false unless check_providers(providers)

    @nodes_provider = providers.first
    true
  end
  # rubocop:enable Metrics/MethodLength

  # Generate a configuration.
  #
  # @param name [String] name of the configuration file
  # @param boxes a list of boxes known to the configuration
  # @param override [Bool] clean directory if it is already exists
  # @return [Number] exit code for the command execution
  # @raise RuntimeError if configuration file is invalid.
  # rubocop:disable Metrics/MethodLength
  # Further decomposition of the method will complicate the code.
  def execute(name, boxes, override)
    @aws_service = @env.aws_service
    path = name.nil? ? File.join(Dir.pwd, 'default') : File.absolute_path(name.to_s)
    begin
      instance_config_file = IO.read(@env.configFile)
      config = JSON.parse(instance_config_file)
    rescue IOError, JSON::ParserError
      @ui.error('Instance configuration file is invalid or not found!')
      return ERROR_RESULT
    end
    nodes_checking_result = load_nodes_provider_and_check_it(config)
    return ARGUMENT_ERROR_RESULT unless nodes_checking_result

    generate_result = generate(path, config, boxes, override, @nodes_provider)
    return generate_result unless generate_result == SUCCESS_RESULT

    @ui.info "Generating config in #{path}"
    generate_provider_and_template_files(path, @nodes_provider)
    SUCCESS_RESULT
  end
  # rubocop:enable Metrics/MethodLength
end
