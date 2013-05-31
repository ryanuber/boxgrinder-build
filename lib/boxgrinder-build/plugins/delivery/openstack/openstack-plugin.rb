#
# Copyright 2010 Red Hat, Inc.
#
# This is free software; you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation; either version 3 of
# the License, or (at your option) any later version.
#
# This software is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this software; if not, write to the Free
# Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
# 02110-1301 USA, or see the FSF site: http://www.fsf.org.

require 'rubygems'
require 'boxgrinder-build/plugins/base-plugin'
require 'rest_client'
require 'json'

module BoxGrinder
  class OpenStackPlugin < BasePlugin
    plugin :type => :delivery, :name => :openstack, :full_name  => "OpenStack"

    def after_init
      set_default_config_value('nova_host', 'localhost')
      set_default_config_value('glance_host', 'localhost')
      set_default_config_value('nova_port', '5000')
      set_default_config_value('glance_port', '9292')
      set_default_config_value('schema', 'http')
      set_default_config_value('overwrite', false)
      set_default_config_value('public', false)

      register_supported_platform(:ec2)
      register_supported_platform(:vmware)
      register_supported_platform(:virtualbox)

      @disk_format, @container_format = disk_and_container_format
      @appliance_name = "#{@appliance_config.name}-#{@appliance_config.version}.#{@appliance_config.release}-#{@disk_format}"
    end

    def execute
      token = nil
      if @plugin_config.has_key?('tenant_id') and @plugin_config.has_key?('user') and @plugin_config.has_key?('password')
        token = retrieve_token(@plugin_config['tenant_id'], @plugin_config['user'], @plugin_config['password'])
      else
        @log.debug 'Skipped token authentication because user, password, and tenant_id were not set'
      end

      @log.debug "Checking if '#{@appliance_name}' appliance is already registered..."
      images = get_images(:name => @appliance_name, :token => token)

      unless images.empty?
        @log.debug "We found one or more appliances with the name '#{@appliance_name}'."

        unless @plugin_config['overwrite']
          @log.error "One or more appliances are already registered with the name '#{@appliance_name}'. You can specify 'overwrite' parameter to remove them."
          return
        end

        @log.info "Removing all images with name '#{@appliance_name}' because 'overwrite' parameter is set to true..."
        images.each {|i| delete_image(i['id'], :token => token) }
        @log.info "Images removed."
      end

      disk_format, container_format = disk_and_container_format

      post_image(:disk_format => disk_format, :container_format => container_format, :public => @plugin_config['public'], :token => token)
    end

    def disk_and_container_format
      disk_format = :raw
      container_format = :bare

      if @previous_plugin_info[:type] == :platform
        case @previous_plugin_info[:name]
          when :ec2
            disk_format = :ami
            container_format = :ami
          when :vmware
            disk_format = :vmdk
          when :virtualbox
            disk_format = :vmdk
        end
      end

      [disk_format, container_format]
    end

    def post_image(options = {})
      options = {
          :disk_format => :raw, # raw, vhd, vmdk, vdi, qcow2, aki, ari, ami
          :container_format => :bare, # ovf, bare, aki, ari, ami
          :public => true,
          :token => nil
      }.merge(options)

      @log.info "Uploading and registering '#{@appliance_name}' appliance in OpenStack..."

      file_size = File.size(@previous_deliverables.disk)

      @log.trace "Disk format: #{options[:disk_format]}, container format: #{options[:container_format]}, public: #{options[:public]}, size: #{file_size}."


      if options[:token].nil?
        image = JSON.parse(RestClient.post("#{glance_url}/v1/images",
          File.new(@previous_deliverables.disk, 'rb'),
          :content_type => 'application/octet-stream',
          'x-image-meta-size' => file_size,
          'x-image-meta-name' => @appliance_name,
          'x-image-meta-disk-format' => options[:disk_format],
          'x-image-meta-container-format' => options[:container_format],
          'x-image-meta-is-public' => options[:public] ? "true" : false,
          'x-image-meta-property-distro' => "#{@appliance_config.os.name.capitalize} #{@appliance_config.os.version}"
        ))['image']
      else
        image = JSON.parse(RestClient.post("#{glance_url}/v1/images",
          File.new(@previous_deliverables.disk, 'rb'),
          :content_type => 'application/octet-stream',
          'x-image-meta-size' => file_size,
          'x-image-meta-name' => @appliance_name,
          'x-image-meta-disk-format' => options[:disk_format],
          'x-image-meta-container-format' => options[:container_format],
          'x-image-meta-is-public' => options[:public] ? "true" : false,
          'x-image-meta-property-distro' => "#{@appliance_config.os.name.capitalize} #{@appliance_config.os.version}",
          'x-auth-token' => options[:token]
        ))['image']
      end
      @log.info "Appliance registered under id = #{image['id']}."
    end

    # Removes image from the server for specified id.
    #
    def delete_image(id, token=nil)
      @log.trace "Removing image with id = #{id}..."
      if token.nil?
        RestClient.delete("#{glance_url}/v1/images/#{id}")
      else
        RestClient.delete("#{glance_url}/v1/images/#{id}", 'x-auth-token' => token)
      end
      @log.trace "Image removed."
    end

    # Retrieves a list of public images with specified filter. If no filter is specified - all images are returned.
    #
    def get_images(params = {})
      @log.trace "Listing images with params = #{params.reject { |k,v| k == :token }.to_json}..."
      if params[:token].nil?
        data = JSON.parse(RestClient.get("#{glance_url}/v1/images", :params => params))['images']
      else
        data = JSON.parse(RestClient.get("#{glance_url}/v1/images", :params => params, 'x-auth-token' => params[:token]))['images']
      end
      @log.trace "Listing done."
      data
    end

    def nova_url
      "#{@plugin_config['schema']}://#{@plugin_config['nova_host']}:#{@plugin_config['compute_port']}"
    end

    def glance_url
      "#{@plugin_config['schema']}://#{@plugin_config['nova_host']}:#{@plugin_config['glance_port']}"
    end

    def retrieve_token(tenant_id, user, password)
      @log.info "Requesting access token from OpenStack..."
      request_data = {'auth' => {'passwordCredentials' => {'username' => user,'password' => password},'tenantId' => tenant_id}}.to_json
      response = RestClient.post("#{nova_url}/v2.0/tokens", request_data, :content_type => 'application/json', :accept => 'application/json')
      if response.code == 200
        result = JSON.parse(response.to_str)
        return result['access']['token']['id']
      end
    end

  end
end
