# frozen_string_literal: true

require 'iniparse'

# Class provides access to the configuration of machines
class NetworkSettings
  def self.from_file(path)
    document = IniParse.parse(File.read(path))
    settings = parse_document(document)
    Result.ok(NetworkSettings.new(settings))
  rescue IniParse::ParseError => e
    Result.error(e.message)
  end

  def initialize(settings = {})
    @settings = settings
  end

  def add_network_configuration(name, settings)
    @settings[name] = settings
  end

  def node_settings(name)
    @settings[name]
  end

  def node_name_list
    @settings.keys
  end

  # Provide configuration in the form of the configuration hash
  def as_hash
    @settings.each_with_object({}) do |(name, config), result|
      config.each_pair do |key, value|
        result["#{name}_#{key}"] = value
      end
    end
  end

  # Provide configuration in the form of the biding
  def as_binding
    result = binding
    as_hash.merge(ENV).each_pair do |key, value|
      result.local_variable_set(key.downcase.to_sym, value)
    end
    result
  end

  # Save the network information into the files and label information into the files
  def store_network_configuration(configuration)
    store_network_settings(configuration)
    store_labels_information(configuration)
  end

  private

  def store_network_settings(configuration)
    document = IniParse.gen do |doc|
      doc.section('__anonymous__') do |section|
        as_hash.each_pair do |parameter, value|
          section.option(parameter, value)
        end
      end
    end
    document.save(configuration.network_settings_file)
  end

  def store_labels_information(configuration)
    active_labels =  configuration.nodes_by_label.select do |_, nodes|
      nodes.all? { |node| @settings.key?(node) }
    end.keys
    File.write(configuration.labels_information_file, active_labels.sort.join(','))
  end

  # Parse INI document into a set of machine descriptions
  def self.parse_document(document)
    section = document['__anonymous__']
    options = section.enum_for(:each)
    names = options.map(&:key)
                   .select { |key| key.include?('_network') }
                   .map { |key| key.sub('_network', '') }
    configs = Hash.new { |hash, key| hash[key] = {} }
    names.each do |name|
      parameters = options.select { |option| option.key.include?(name) }
      parameters.reduce(configs) do |_result, option|
        key = option.key.sub(name, '').sub('_', '')
        configs[name][key] = option.value.sub(/^"/, '').sub(/"$/, '')
      end
    end
    configs
  end
end
