require 'boxgrinder-build/plugins/base-plugin'
require 'boxgrinder-build/helpers/linux-helper'
require 'tempfile'

module BoxGrinder
  class CloudStackPlugin < CitrixPlugin
    def execute
      @log.info "Beginning CloudStack image customization..."
      build_citrix do |guestfs, guestfs_helper|
        upload_init_scripts(guestfs)
      end
      @log.info "Endof CloudStack image customization..."
    end

    def upload_init_scripts(guestfs)
      @log.debug "Uploading CloudStack init scripts..."
      guestfs.sh("yum install -y wget")

      for script in ["getSSHKeys","getUserData","cloud-set-guest-password"]
        @log.debug "adding: #{script}"
        guestfs.upload("#{File.dirname(__FILE__)}/src/#{script}", "/etc/init.d/#{script}")
        guestfs.sh("chmod +x /etc/init.d/#{script}; /sbin/chkconfig #{script} on")
      end
    end

    def execute_post(guestfs_helper)
      unless @appliance_config.post['cloudstack'].nil?
        @appliance_config.post['cloudstack'].each do |cmd|
          guestfs_helper.sh(cmd, :arch => @appliance_config.hardware.arch)
        end
        @log.debug "Post commands from appliance definition file executed."
      else
        @log.debug "No commands specified, skipping."
      end
    end

  end
end

plugin :class => BoxGrinder::CloudStackPlugin, :type => :platform, :name => :cloudstack, :full_name => "CloudStack Plugin"
