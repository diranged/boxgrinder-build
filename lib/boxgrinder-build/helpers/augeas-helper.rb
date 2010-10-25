# JBoss, Home of Professional Open Source
# Copyright 2009, Red Hat Middleware LLC, and individual contributors
# by the @authors tag. See the copyright.txt in the distribution for a
# full listing of individual contributors.
#
# This is free software; you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation; either version 2.1 of
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

require 'logger'

module BoxGrinder
  class AugeasHelper
    def initialize( guestfs, guestfs_helper, options = {})
      @guestfs        = guestfs
      @guestfs_helper = guestfs_helper
      @log            = options[:log] || Logger.new(STDOUT)

      @files = {}
    end

    def edit( &block )
      @log.debug "Changing configuration files using augeas..."

      instance_eval &block if block

      if @files.empty?
        @log.debug "No files specified to change, skipping..."
        return
      end

      @log.trace "Enabling coredump catching for augeas..."
      @guestfs.debug( "core_pattern", [ "/sysroot/core" ] )

      @guestfs.aug_init( "/", 32 )

      unload = []

      @files.keys.each do |file_name|
        unload << ". != '#{file_name}'"
      end

      @guestfs.aug_rm( "/augeas/load//incl[#{unload.join(' and ')}]" )
      @guestfs.aug_load

      @files.each do |file, changes|
        changes.each do |key, value|

          @guestfs.aug_set("/files#{file}/#{key}", value)
        end
      end

      @guestfs.aug_save

      @log.debug "Augeas changes saved."
    end

    def set( name, key, value )
      unless @guestfs.exists( name ) != 0
        @log.debug "File '#{name}' doesn't exists, skipping augeas changes..."
        return
      end

      @files[name] = {} unless @files.has_key?( name )
      @files[name][key] = value
    end
  end
end
