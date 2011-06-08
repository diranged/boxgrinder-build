require 'boxgrinder-build/plugins/base-plugin'
require 'boxgrinder-build/helpers/linux-helper'
require 'tempfile'

module BoxGrinder
  class CitrixPlugin < BasePlugin
    def after_init
      register_deliverable(:disk => "#{@appliance_config.name}.raw")
      register_supported_os('rhel', ['5', '6'])
      register_supported_os('centos', ['5', '6'])
      register_supported_os('sl', ['5', '6'])
    end

    ## if this plugin is called directly, execute build_citrix
    def execute
      build_citrix
    end

    ## encapsulate all of our code in build_Citrix, so that it can be used by other modules.
    def build_citrix
      @linux_helper = LinuxHelper.new(:log => @log)
      @log.info "Beginning Citrix XenServer conversion..."

      ## Calculate the size of all of the partitions from the appliance_Config, and create a new disk image with that size.
      @log.info "Creating new #{@appliance_config.name} appliance image..."
      size = 0
      @appliance_config.hardware.partitions.each_value do |partition| 
        @log.debug "Adding #{partition['size']} GB to the overal disk size..."
        size += partition['size']
        @log.debug "Total size is now: #{size}"
      end
      @image_helper.create_disk(@deliverables.disk, size.to_f)

      ## Now that the disk is created, prep it and copy all the data from the old drive to the new one.
      @image_helper.customize([@previous_deliverables.disk, @deliverables.disk], :automount => false) do |guestfs, guestfs_helper| 
        ## Make sure we use EXT3 as the filesystem, Citrix 5.6 doesnt support ext4 at all
        @image_helper.sync_filesystem(guestfs, guestfs_helper, :filesystem_type => 'ext3')

        ## Using the defined commands below, set up this image
        build_initrd(guestfs,guestfs_helper)
        create_devices(guestfs)
        enable_networking(guestfs)
        upload_rc_local(guestfs)
        install_menu_lst(guestfs)
        install_xe_guest_tools(guestfs)

        ## If we were called by another module, pass back guestfs/guestfs_helper
        yield guestfs, guestfs_helper if block_given?
      end
      @log.info "Image converted to Citrix format."
    end

    def build_initrd(guestfs,guestfs_helper) 
        ## If we are RHEL5/CentOS5 then we need to make sure the xen kernel is installed and that the initrd is rebuilt.
        if (@appliance_config.os.name == 'rhel' or @appliance_config.os.name == 'centos') and @appliance_config.os.version == '5'
          @log.debug "Removing kernel RPM from system..."
          # Remove normal kernel
          guestfs.sh("yum -y remove kernel")

          @log.debug "Installing kernel-xen RPM...."
          # because we need to install kernel-xen package
          guestfs.sh("yum -y install kernel-xen")

          @log.debug "Rebuilding the initrd file..."
          # and add require modules
          @linux_helper.recreate_kernel_image(guestfs, ['xenblk', 'xennet'])
          execute_post(guestfs_helper)
        end
    end

    def create_devices(guestfs)
      return if guestfs.exists('/sbin/MAKEDEV') == 0

      @log.debug "Creating required devices..."
      guestfs.sh("/sbin/MAKEDEV -d /dev -x console")
      guestfs.sh("/sbin/MAKEDEV -d /dev -x null")
      guestfs.sh("/sbin/MAKEDEV -d /dev -x zero")
      @log.debug "Devices created."
    end

    def install_menu_lst(guestfs)
      @log.debug "Uploading '/boot/grub/menu.lst' file..."
      menu_lst_data = File.open("#{File.dirname(__FILE__)}/src/menu.lst").read

      menu_lst_data.gsub!(/#TITLE#/, @appliance_config.name)
      menu_lst_data.gsub!(/#KERNEL_VERSION#/, @linux_helper.kernel_version(guestfs))
      menu_lst_data.gsub!(/#KERNEL_IMAGE_NAME#/, @linux_helper.kernel_image_name(guestfs))

      menu_lst = Tempfile.new('menu_lst')
      menu_lst << menu_lst_data
      menu_lst.flush

      guestfs.upload(menu_lst.path, "/boot/grub/menu.lst")

      menu_lst.close
      @log.debug "'/boot/grub/menu.lst' file uploaded."

      @log.debug "Adding xvc0 to /etc/securetty..."
      guestfs.sh("echo xvc0 >> /etc/securetty") 

      @log.debug "Adding hvc0 to /etc/securetty..."
      guestfs.sh("echo hvc0 >> /etc/securetty") 
    end

    def install_xe_guest_tools(guestfs)
      @log.debug "Installing XE Guest Utils... "
      guestfs.sh("rpm -ivh http://ftp.prz.edu.pl/archlinux/archrak/src/xe-guest-utilities-5.6.0-578.#{@appliance_config.hardware.base_arch}.rpm http://ftp.prz.edu.pl/archlinux/archrak/src/xe-guest-utilities-xenstore-5.6.0-578.#{@appliance_config.hardware.base_arch}.rpm ")
    end

    # enable networking on default runlevels
    def enable_networking(guestfs)
      @log.debug "Enabling networking..."
      guestfs.sh("/sbin/chkconfig network on")
      guestfs.upload("#{File.dirname(__FILE__)}/src/ifcfg-eth0", "/etc/sysconfig/network-scripts/ifcfg-eth0")
      @log.debug "Networking enabled."
    end

    def upload_rc_local(guestfs)
      @log.debug "Uploading '/etc/rc.local' file..."
      rc_local = Tempfile.new('rc_local')
      rc_local << guestfs.read_file("/etc/rc.local") + File.read("#{File.dirname(__FILE__)}/src/rc_local")
      rc_local.flush

      guestfs.upload(rc_local.path, "/etc/rc.local")

      rc_local.close
      @log.debug "'/etc/rc.local' file uploaded."
    end


    def execute_post(guestfs_helper)
      unless @appliance_config.post['citrix'].nil?
        @appliance_config.post['citrix'].each do |cmd|
          guestfs_helper.sh(cmd, :arch => @appliance_config.hardware.arch)
        end
        @log.debug "Post commands from appliance definition file executed."
      else
        @log.debug "No commands specified, skipping."
      end
    end
  end
end

plugin :class => BoxGrinder::CitrixPlugin, :type => :platform, :name => :citrix, :full_name => "Citrix Plugin"

