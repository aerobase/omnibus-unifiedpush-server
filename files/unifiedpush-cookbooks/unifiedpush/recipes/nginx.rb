#
# Copyright:: Copyright (c) 2015.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

account_helper = AccountHelper.new(node)
omnibus_helper = OmnibusHelper.new(node)
domain_helper = DomainHelper.new(node)

install_dir = node['package']['install-dir']
nginx_dir = node['unifiedpush']['nginx']['dir']
nginx_conf_dir = File.join(nginx_dir, "conf")
nginx_confd_dir = File.join(nginx_dir, "conf.d")
nginx_html_dir = File.join(nginx_dir, "www/html")
nginx_ups_html_dir = File.join(nginx_html_dir, "unifiedpush-server")
nginx_gsg_html_dir = File.join(nginx_html_dir, "getting-started")
nginx_log_dir = node['unifiedpush']['nginx']['log_directory']

# These directories do not need to be writable for unifiedpush-server
[
  nginx_dir,
  nginx_conf_dir,
  nginx_confd_dir,
  nginx_html_dir,
  nginx_ups_html_dir,
  nginx_gsg_html_dir,
  nginx_log_dir,
].each do |dir_name|
  directory dir_name do
    owner account_helper.web_server_user
    group 'root'
    mode '0750'
    recursive true
  end
end

link File.join(nginx_dir, "logs") do
  to nginx_log_dir
end

# Link logrotate dir to self.
# A workarround to ensure logrotate always exists at log_directory/logs
link "#{nginx_log_dir}/logs" do
  to nginx_log_dir
end

nginx_config = File.join(nginx_conf_dir, "nginx.conf")

unifiedpush_server_http_conf = File.join(nginx_conf_dir, "aerobase-http.conf")
unifiedpush_locations_http_conf = File.join(nginx_conf_dir, "aerobase-locations.import")
unifiedpush_subdomains_http_conf = File.join(nginx_conf_dir, "aerobase-subdomains.conf")

# If the service is enabled, check if we are using internal nginx
nginx_server_enabled = node['unifiedpush']['nginx']['enable']
unifiedpush_server_enabled = node['unifiedpush']['unifiedpush-server']['enable']
keycloak_server_enabled = node['unifiedpush']['keycloak-server']['enable']

# Include the config file for unifiedpush-server in nginx.conf later
nginx_vars = node['unifiedpush']['nginx'].to_hash.merge({
               :unifiedpush_http_config => unifiedpush_server_enabled || keycloak_server_enabled ? unifiedpush_server_http_conf : nil,
	       :unifiedpush_subdomains_http_conf => unifiedpush_server_enabled || keycloak_server_enabled ? unifiedpush_subdomains_http_conf : nil,
               :unifiedpush_http_configd => nginx_confd_dir
             })

if nginx_vars['listen_https'].nil?
  nginx_vars['https'] = node['unifiedpush']['unifiedpush-server']['server_https']
else
  nginx_vars['https'] = nginx_vars['server_https']
end

template unifiedpush_server_http_conf do
  source "nginx-unifiedpush-http.conf.erb"
  owner "root"
  group "root"
  mode "0644"
  variables(nginx_vars.merge(
    {
      :fqdn => node['unifiedpush']['unifiedpush-server']['server_host'],
      :html_dir => nginx_html_dir
    }
  ))
  notifies :restart, 'runit_service[nginx]' if omnibus_helper.should_notify?("nginx")
  action nginx_server_enabled ? :create : :delete
end

template unifiedpush_locations_http_conf do
  source "nginx-locations-http.conf.erb"
  owner "root"
  group "root"
  mode "0644"
  variables(nginx_vars.merge(
    {
      :fqdn => node['unifiedpush']['unifiedpush-server']['server_host'],
      :html_dir => nginx_html_dir
    }
  ))
  notifies :restart, 'runit_service[nginx]' if omnibus_helper.should_notify?("nginx")
  action nginx_server_enabled ? :create : :delete
end

template unifiedpush_subdomains_http_conf do
  source "nginx-subdomains-http.conf.erb"
  owner "root"
  group "root"
  mode "0644"
  variables(nginx_vars.merge(
    {
      :fqdn => domain_helper.parse_domain(node['unifiedpush']['unifiedpush-server']['server_host']),
      :html_dir => nginx_html_dir
    }
  ))
  notifies :restart, 'runit_service[nginx]' if omnibus_helper.should_notify?("nginx")
  action nginx_server_enabled ? :create : :delete
end

template nginx_config do
  source "nginx.conf.erb"
  owner "root"
  group "root"
  mode "0644"
  variables nginx_vars
  notifies :restart, 'runit_service[nginx]' if omnibus_helper.should_notify?("nginx")
  action nginx_server_enabled ? :create : :delete
end

# Extract aerobae static contect to html directory
if unifiedpush_server_enabled
  execute 'extract_aerobase_static_content' do
    command "#{install_dir}/embedded/bin/rsync --exclude='**/.git*' --delete -a #{install_dir}/embedded/apps/unifiedpush-server/unifiedpush-admin-ui/* #{nginx_ups_html_dir}"
  end
end

if unifiedpush_server_enabled
  execute 'extract_aerobase_static_content' do
    command "#{install_dir}/embedded/bin/rsync --exclude='**/.git*' --delete -a #{install_dir}/embedded/apps/unifiedpush-server/aerobase-gsg-ui/* #{nginx_gsg_html_dir}"
  end
end

# Make sure owner is unifiedpush_user
execute "chown-nginx-resources" do
  command "chown -R #{account_helper.web_server_user}:root #{nginx_ups_html_dir}"
  action :run
end

component_runit_service "nginx" do
  package "unifiedpush"
end

if node['unifiedpush']['bootstrap']['enable']
  execute "/opt/unifiedpush/bin/unifiedpush-ctl start nginx" do
    retries 20
  end
end
