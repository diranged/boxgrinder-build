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

require 'boxgrinder-core/models/appliance-config'
require 'boxgrinder-build/plugins/base-plugin'
require 'boxgrinder-build/plugins/os/rpm-based/kickstart'
require 'boxgrinder-build/plugins/os/rpm-based/rpm-dependency-validator'
require 'boxgrinder-build/helpers/linux-helper'

module BoxGrinder
  class RPMBasedOSPlugin < BasePlugin
    def after_init
      register_deliverable(
          :disk => "#{@appliance_config.name}-sda.#{@plugin_config['format']}",
          :descriptor => "#{@appliance_config.name}.xml"
      )

      @linux_helper = LinuxHelper.new(:log => @log)
    end

    def validate
      set_default_config_value('format', 'raw')
    end

    def read_file(file)
      read_kickstart(file) if File.extname(file).eql?('.ks')
    end

    def read_kickstart(file)
      appliance_config = ApplianceConfig.new
      appliance_config.name = File.basename(file, '.ks')

      name = nil
      version = nil

      kickstart = File.read(file)

      kickstart.each do |line|
        n = line.scan(/^# bg_os_name: (.*)/).flatten.first
        v = line.scan(/^# bg_os_version: (.*)/).flatten.first

        name = n unless n.nil?
        version = v unless v.nil?
      end

      raise "No operating system name specified, please add comment to you kickstrt file like this: # bg_os_name: fedora" if name.nil?
      raise "No operating system version specified, please add comment to you kickstrt file like this: # bg_os_version: 14" if version.nil?

      appliance_config.os.name = name
      appliance_config.os.version = version

      partitions = {}

      kickstart.each do |line|
        # Parse also the partition scheme
        if line =~ /^part ([\/\w]+)/
          root = $1
          partitions[root] = {}

          # size
          partitions[root]['size'] = $1.to_f / 1024 if line =~ /--size[=\s]*(\d+)/
          # fs type
          partitions[root]['type'] = $1 if line =~ /--fstype[=\s]*(\w+)/
          # fs options
          partitions[root]['options'] = $1 if line =~ /--fsoptions[=\s]*([,\w]+)/

          raise "Partition size not specified for #{root} partition in #{file}" if partitions[root]['size'].nil?
        end
      end

      raise "No partitions specified in your kickstart file #{file}" if partitions.empty?

      appliance_config.hardware.partitions = partitions

      appliance_config
    end

    # Add default repos (if present) to the list of additional repositories specified in appliance definition.
    def add_repos(repos)
      return if repos.empty?

      repos[@appliance_config.os.version].each do |name, repo|
        r = { 'name' => name, 'ephemeral' => true }

        ['baseurl', 'mirrorlist'].each { |type| r[type] = substitute_vars(repo[type]) unless repo[type].nil? }

        @appliance_config.repos << r
      end
    end

    # Substitute variables in selected string.
    def substitute_vars(str)
      return if str.nil?
      @appliance_config.variables.keys.each do |var|
        str = str.gsub("##{var}#", @appliance_config.variables[var])
      end
      str
    end

    def build_with_appliance_creator(appliance_definition_file, repos = {})
      if File.extname(appliance_definition_file).eql?('.ks')
        kickstart_file = appliance_definition_file
      else
        add_repos(repos) if @appliance_config.default_repos
        kickstart_file = Kickstart.new(@config, @appliance_config, @dir, :log => @log).create
        RPMDependencyValidator.new(@config, @appliance_config, @dir, :log => @log).resolve_packages
      end

      @log.info "Building #{@appliance_config.name} appliance..."

      execute_appliance_creator(kickstart_file)

      FileUtils.mv(Dir.glob("#{@dir.tmp}/#{@appliance_config.name}/*"), @dir.tmp)
      FileUtils.rm_rf("#{@dir.tmp}/#{@appliance_config.name}/")

      @image_helper.customize([@deliverables.disk]) do |guestfs, guestfs_helper|
        # TODO is this really needed?
        @log.debug "Uploading '/etc/resolv.conf'..."
        guestfs.upload("/etc/resolv.conf", "/etc/resolv.conf")
        @log.debug "'/etc/resolv.conf' uploaded."

        change_configuration(guestfs_helper)
        # TODO check if this is still required
        apply_root_password(guestfs)
        use_labels_for_partitions(guestfs)
        disable_firewall(guestfs)
        set_motd(guestfs)
        install_repos(guestfs)

        if @appliance_config.os.name == 'fedora' and @appliance_config.os.version == '15'
          disable_biosdevname(guestfs)
          change_runlevel(guestfs)
          disable_netfs(guestfs)
          link_mtab(guestfs)
        end

        guestfs.sh("chkconfig firstboot off") if guestfs.exists('/etc/init.d/firstboot') != 0

        @log.info "Executing post operations after build..."

        unless @appliance_config.post['base'].nil?
          @appliance_config.post['base'].each do |cmd|
            guestfs_helper.sh(cmd, :arch => @appliance_config.hardware.arch)
          end
          @log.debug "Post commands from appliance definition file executed."
        else
          @log.debug "No commands specified, skipping."
        end

        yield guestfs, guestfs_helper if block_given?

        @log.info "Post operations executed."

        # https://issues.jboss.org/browse/BGBUILD-148
        recreate_rpm_database(guestfs, guestfs_helper) if @config.os.name != @appliance_config.os.name or @config.os.version != @appliance_config.os.version
      end

      @log.info "Base image for #{@appliance_config.name} appliance was built successfully."
    end

    def execute_appliance_creator(kickstart_file)
      begin
        @exec_helper.execute "appliance-creator -d -v -t '#{@dir.tmp}' --cache=#{@config.dir.cache}/rpms-cache/#{@appliance_config.path.main} --config '#{kickstart_file}' -o '#{@dir.tmp}' --name '#{@appliance_config.name}' --vmem #{@appliance_config.hardware.memory} --vcpu #{@appliance_config.hardware.cpus} --format #{@plugin_config['format']}"
      rescue InterruptionError => e
        cleanup_after_appliance_creator(e.pid)
        abort
      end
    end

    # https://issues.jboss.org/browse/BGBUILD-204
    def disable_biosdevname(guestfs)
      @log.debug "Disabling biosdevname for Fedora 15..."
      guestfs.sh('sed -i "s/kernel\(.*\)/kernel\1 biosdevname=0/g" /boot/grub/grub.conf')
      @log.debug "Biosdevname disabled."
    end

    # https://issues.jboss.org/browse/BGBUILD-204
    def change_runlevel(guestfs)
      @log.debug "Changing runlevel to multi-user non-graphical..."
      guestfs.rm("/etc/systemd/system/default.target")
      guestfs.ln_sf("/lib/systemd/system/multi-user.target", "/etc/systemd/system/default.target")
      @log.debug "Runlevel changed."
    end

    # https://issues.jboss.org/browse/BGBUILD-204
    def disable_netfs(guestfs)
      @log.debug "Disabling network filesystem mounting..."
      guestfs.sh("chkconfig netfs off")
      @log.debug "Network filesystem mounting disabled."
    end

    # https://issues.jboss.org/browse/BGBUILD-209
    def link_mtab(guestfs)
      @log.debug "Linking /etc/mtab to /proc/self/mounts for Fedora 15..."
      guestfs.ln_sf("/proc/self/mounts", "/etc/mtab")
      @log.debug "/etc/mtab linked."
    end

    # https://issues.jboss.org/browse/BGBUILD-148
    def recreate_rpm_database(guestfs, guestfs_helper)
      @log.debug "Recreating RPM database..."

      guestfs.download("/var/lib/rpm/Packages", "#{@dir.tmp}/Packages")
      @exec_helper.execute("/usr/lib/rpm/rpmdb_dump #{@dir.tmp}/Packages > #{@dir.tmp}/Packages.dump")
      guestfs.upload("#{@dir.tmp}/Packages.dump", "/tmp/Packages.dump")
      guestfs.sh("rm -rf /var/lib/rpm/*")
      guestfs_helper.sh("cd /var/lib/rpm/ && cat /tmp/Packages.dump | /usr/lib/rpm/rpmdb_load Packages")
      guestfs_helper.sh("rpm --rebuilddb")

      @log.debug "RPM database recreated..."
    end

    def cleanup_after_appliance_creator(pid)
      @log.debug "Sending TERM signal to process '#{pid}'..."
      Process.kill("TERM", pid)

      @log.debug "Waiting for process to be terminated..."
      Process.wait(pid)

      @log.debug "Cleaning appliance-creator mount points..."

      Dir["#{@dir.tmp}/imgcreate-*"].each do |dir|
        dev_mapper = @exec_helper.execute "mount | grep #{dir} | awk '{print $1}'"

        mappings = {}

        dev_mapper.each do |mapping|
          if mapping =~ /(loop\d+)p(\d+)/
            mappings[$1] = [] if mappings[$1].nil?
            mappings[$1] << $2 unless mappings[$1].include?($2)
          end
        end

        (['/var/cache/yum', '/dev/shm', '/dev/pts', '/proc', '/sys'] + @appliance_config.hardware.partitions.keys.reverse).each do |mount_point|
          @log.trace "Unmounting '#{mount_point}'..."
          @exec_helper.execute "umount -d #{dir}/install_root#{mount_point}"
        end

        mappings.each do |loop, partitions|
          @log.trace "Removing mappings from loop device #{loop}..."
          @exec_helper.execute "/sbin/kpartx -d /dev/#{loop}"
          @exec_helper.execute "losetup -d /dev/#{loop}"

          partitions.each do |part|
            @log.trace "Removing mapping for partition #{part} from loop device #{loop}..."
            @exec_helper.execute "rm /dev/#{loop}#{part}"
          end
        end
      end

      @log.debug "Cleaned up after appliance-creator."
    end

    # https://issues.jboss.org/browse/BGBUILD-177
    def disable_firewall(guestfs)
      @log.debug "Disabling firewall..."
      guestfs.sh("lokkit -q --disabled")
      @log.debug "Firewall disabled."
    end

    def use_labels_for_partitions(guestfs)
      device = guestfs.list_devices.first

      # /etc/fstab
      if fstab = guestfs.read_file('/etc/fstab').gsub!(/^(\/dev\/sda.)/) { |path| "LABEL=#{read_label(guestfs, path.gsub('/dev/sda', device))}" }
        guestfs.write_file('/etc/fstab', fstab, 0)
      end

      # /boot/grub/grub.conf
      if grub = guestfs.read_file('/boot/grub/grub.conf').gsub!(/(\/dev\/sda.)/) { |path| "LABEL=#{read_label(guestfs, path.gsub('/dev/sda', device))}" }
        guestfs.write_file('/boot/grub/grub.conf', grub, 0)
      end
    end

    def read_label(guestfs, partition)
      (guestfs.respond_to?(:vfs_label) ? guestfs.vfs_label(partition) : guestfs.sh("/sbin/e2label #{partition}").chomp.strip).gsub('_', '')
    end

    def apply_root_password(guestfs)
      @log.debug "Applying root password..."
      guestfs.sh("/usr/bin/passwd -d root")
      guestfs.sh("/usr/sbin/usermod -p '#{@appliance_config.os.password.crypt((0...8).map { 65.+(rand(25)).chr }.join)}' root")
      @log.debug "Password applied."
    end

    def change_configuration(guestfs_helper)
      guestfs_helper.augeas do
        set('/etc/ssh/sshd_config', 'UseDNS', 'no')
        set('/etc/sysconfig/selinux', 'SELINUX', 'permissive')
      end
    end

    def set_motd(guestfs)
      @log.debug "Setting up '/etc/motd'..."
      # set nice banner for SSH
      motd_file = "/etc/init.d/motd"
      guestfs.upload("#{File.dirname(__FILE__)}/src/motd.init", motd_file)
      guestfs.sh("sed -i s/#VERSION#/'#{@appliance_config.version}.#{@appliance_config.release}'/ #{motd_file}")
      guestfs.sh("sed -i s/#APPLIANCE#/'#{@appliance_config.name} appliance'/ #{motd_file}")

      guestfs.sh("/bin/chmod +x #{motd_file}")
      guestfs.sh("/sbin/chkconfig --add motd")
      @log.debug "'/etc/motd' is nice now."
    end

    def recreate_kernel_image(guestfs, modules = [])
      @linux_helper.recreate_kernel_image(guestfs, modules)
    end

    def install_repos(guestfs)
      @log.debug "Installing repositories from appliance definition file..."
      @appliance_config.repos.each do |repo|
        if repo['ephemeral']
          @log.debug "Repository '#{repo['name']}' is an ephemeral repo. It'll not be installed in the appliance."
          next
        end

        @log.debug "Installing #{repo['name']} repo..."
        repo_file = File.read("#{File.dirname(__FILE__)}/src/base.repo").gsub(/#NAME#/, repo['name'])

        ['baseurl', 'mirrorlist'].each do |type|
          repo_file << ("#{type}=#{repo[type]}\n") unless repo[type].nil?
        end

        guestfs.write_file("/etc/yum.repos.d/#{repo['name']}.repo", repo_file, 0)
      end
      @log.debug "Repositories installed."
    end

  end
end
