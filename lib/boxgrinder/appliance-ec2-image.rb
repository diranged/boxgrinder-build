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

require 'rake/tasklib'
require 'fileutils'
require 'boxgrinder/validator/errors'
require 'yaml'
require 'AWS'
require 'aws/s3'
require 'boxgrinder/aws/aws-support'
require 'boxgrinder/appliance-image-customize'
include AWS::S3

module BoxGrinder
  class ApplianceEC2Image < Rake::TaskLib

    def initialize( config, appliance_config )
      @config            = config
      @appliance_config  = appliance_config

      @exec_helper       = EXEC_HELPER
      @log               = LOG

      @appliance_build_dir          = "#{@config.dir_build}/#{@appliance_config.appliance_path}"
      @bundle_dir                   = "#{@appliance_build_dir}/ec2/bundle"
      @appliance_xml_file           = "#{@appliance_build_dir}/#{@appliance_config.name}.xml"
      @appliance_raw_image          = "#{@appliance_build_dir}/#{@appliance_config.name}-sda.raw"

      @appliance_ec2_image_file     = "#{@appliance_build_dir}/#{@appliance_config.name}.ec2"
      @appliance_ec2_manifest_file  = "#{@bundle_dir}/#{@appliance_config.name}.ec2.manifest.xml"
      @appliance_ec2_register_file  = "#{@appliance_build_dir}/ec2/register"

      @appliance_image_customizer   = ApplianceImageCustomize.new( @config, @appliance_config )

      define_tasks
    end

    def define_tasks
      directory @bundle_dir

      file @appliance_ec2_image_file  => [ @appliance_xml_file ] do
        convert_image_to_ec2_format
      end

      file @appliance_ec2_manifest_file => [ @appliance_ec2_image_file, @bundle_dir ] do
        @aws_support = AWSSupport.new( @config )
        bundle_image
      end

      task "appliance:#{@appliance_config.name}:ec2:upload" => [ @appliance_ec2_manifest_file ] do
        @aws_support = AWSSupport.new( @config )
        upload_image
      end

      task "appliance:#{@appliance_config.name}:ec2:register" => [ "appliance:#{@appliance_config.name}:ec2:upload" ] do
        @aws_support = AWSSupport.new( @config )
        register_image
      end

      desc "Build #{@appliance_config.simple_name} appliance for Amazon EC2"
      task "appliance:#{@appliance_config.name}:ec2" => [ @appliance_ec2_image_file ]
    end

    def bundle_image
      @log.info "Bundling AMI..."

      @exec_helper.execute( "ec2-bundle-image -i #{@appliance_ec2_image_file} --kernel #{AWS_DEFAULTS[:kernel_id][@appliance_config.hardware.arch]} --ramdisk #{AWS_DEFAULTS[:ramdisk_id][@appliance_config.hardware.arch]} -c #{@aws_support.aws_data['cert_file']} -k #{@aws_support.aws_data['key_file']} -u #{@aws_support.aws_data['account_number']} -r #{@config.build_arch} -d #{@bundle_dir}" )

      @log.info "Bundling AMI finished."
    end

    def appliance_already_uploaded?
      begin
        bucket = Bucket.find( @config.release.s3['bucket_name'] )
      rescue
        return false
      end

      manifest_location = @aws_support.bucket_manifest_key( @appliance_config.name )
      manifest_location = manifest_location[ manifest_location.index( "/" ) + 1, manifest_location.length ]

      for object in bucket.objects do
        return true if object.key.eql?( manifest_location )
      end

      false
    end

    def upload_image
      if appliance_already_uploaded?
        @log.debug "Image for #{@appliance_config.simple_name} appliance is already uploaded, skipping..."
        return
      end

      @log.info "Uploading #{@appliance_config.simple_name} AMI to bucket '#{@config.release.s3['bucket_name']}'..."

      @exec_helper.execute( "ec2-upload-bundle -b #{@aws_support.bucket_key( @appliance_config.name )} -m #{@appliance_ec2_manifest_file} -a #{@aws_support.aws_data['access_key']} -s #{@aws_support.aws_data['secret_access_key']} --retry" )
    end

    def register_image
      ami_info    = @aws_support.ami_info( @appliance_config.name )

      if ami_info
        @log.info "Image is registered under id: #{ami_info.imageId}"
        return
      else
        ami_info = @aws_support.ec2.register_image( :image_location => @aws_support.bucket_manifest_key( @appliance_config.name ) )
        @log.info "Image successfully registered under id: #{ami_info.imageId}."
      end
    end

    def convert_image_to_ec2_format
      @log.info "Converting #{@appliance_config.simple_name} appliance image to EC2 format..."

      @appliance_image_customizer.convert_to_ami

      @log.info "Image converted to EC2 format."
    end

  end
end