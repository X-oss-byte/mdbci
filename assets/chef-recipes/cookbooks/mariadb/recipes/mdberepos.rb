include_recipe 'clear_mariadb_repo_priorities::default'

# Install default packages
%w[net-tools psmisc].each do |pkg|
  package pkg do
    retries 2
    retry_delay 10
  end
end

repo_file_name = node['mariadb']['repo_file_name']

# MDBE repos
case node[:platform_family]
when 'debian', 'ubuntu'
  # Split MaxScale repository information into parts
  if node['mariadb']['repo'].include?('es-repo.mariadb.net')
    file "/etc/apt/sources.list.d/#{repo_file_name}.list" do
      content "deb [trusted=yes] #{node['mariadb']['repo']}"
      mode '0644'
      owner 'root'
      group 'root'
    end
    if node['mariadb'].key?('unsupported_repo')
      file "/etc/apt/sources.list.d/#{repo_file_name}_unsupported.list" do
        content "deb [trusted=yes] #{node['mariadb']['unsupported_repo']}"
        mode '0644'
        owner 'root'
        group 'root'
      end
    end
    remote_file "/tmp/#{repo_file_name}.public" do
      source node['mariadb']['repo_key']
    end
    execute 'install key' do
      command "apt-key add /tmp/#{repo_file_name}.public"
    end
    file "/tmp/#{repo_file_name}.public" do
      action :delete
    end
  else
    repo_uri, repo_distribution = node['mariadb']['repo'].split(/\s+/)
    apt_repository repo_file_name do
      uri repo_uri
      distribution repo_distribution
      components node['mariadb']['components']
      keyserver 'keyserver.ubuntu.com'
      key node['mariadb']['repo_key']
      sensitive true
    end
    if node['mariadb'].key?('unsupported_repo')
      unsupported_repo_uri = node['mariadb']['unsupported_repo'].split(/\s+/).first
      apt_repository "#{repo_file_name}_unsupported" do
        uri unsupported_repo_uri
        distribution repo_distribution
        components node['mariadb']['components']
        keyserver 'keyserver.ubuntu.com'
        key node['mariadb']['repo_key']
        sensitive true
      end
    end
  end
  apt_update do
    action :update
  end
when 'rhel', 'fedora', 'centos'
  yum_repository repo_file_name do
    baseurl node['mariadb']['repo']
    gpgkey node['mariadb']['repo_key']
    sensitive true
    options({ 'module_hotfixes' => '1' })
  end
  if node['mariadb'].key?('unsupported_repo')
    yum_repository "#{repo_file_name}_unsupported" do
      baseurl node['mariadb']['unsupported_repo']
      gpgkey node['mariadb']['repo_key']
      sensitive true
      options({ 'module_hotfixes' => '1' })
    end
  end
when 'suse', 'opensuse', 'sles'
  zypper_repository 'mariadb' do
    action :remove
  end
  zypper_repository 'mariadb_unsupported' do
    action :remove
  end
  remote_file File.join('tmp', 'rpm.key') do
    source node['mariadb']['repo_key']
    action :create
  end
  execute 'Import rpm key' do
    command 'rpm --import /tmp/rpm.key && rm -f /tmp/rpm.key'
  end
  zypper_repository 'mariadb' do
    action :add
    baseurl node['mariadb']['repo']
    sensitive true
  end
  zypper_repository 'MariaDB' do
    action :refresh
  end
  if node['mariadb'].key?('unsupported_repo')
    zypper_repository 'mariadb_unsupported' do
      action :add
      baseurl node['mariadb']['unsupported_repo']
      sensitive true
    end
    zypper_repository 'mariadb_unsupported' do
      action :refresh
    end
  end
end
