# aws2graphite

## What it does

This is a project to help people to undertand how to easily load data from the aws into graphite

## Config

See the config file.  Script is currently set-up to work only for rds.
New rules can be added easily.

## How to execute 

	#!/bin/bash
	
	# Set environment variables:
	export PATH=$PATH:/opt/chef/embedded/bin:/usr/bin:/bin
	
	echo "Start " `date`
	cd /home/ubuntu/aws2graphite/
	/opt/chef/embedded/bin/ruby /home/ubuntu/aws2graphite/aws2graphite.rb
	> aws2graphite.out
	
	echo "End " `date`
