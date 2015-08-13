#!/usr/bin/env ruby

# Take two input parameters: a collection uuid and reason
# Get "src_collection" with the given uuid
# Create a new collection with:
#   src_collection.manifest_text as "invalid_manifest_text.txt"
#   Locators from src_collection.manifest_text as "salvaged_data"
# Update src_collection:
#   Set src_collection.manifest_text to: ""
#   Append to src_collection.name: " (reason; salvaged data at new_collection.uuid)"
#   Set portable_data_hash to "d41d8cd98f00b204e9800998ecf8427e+0"

require 'trollop'

opts = Trollop::options do
  banner ''
  banner "Usage: salvage_collection.rb " +
    "{uuid} {reason}"
  banner ''
  opt :uuid, "uuid of the collection to be salvaged.", type: :string, required: true
  opt :reason, "Reason for salvaging.", type: :string, required: false
end

require File.dirname(__FILE__) + '/../config/environment'
require 'arvados/keep'
include ApplicationHelper
require 'tempfile'
require 'shellwords'

def salvage_collection uuid, reason
  act_as_system_user do
    src_collection = Collection.find_by_uuid uuid
    if !src_collection
      $stderr.puts "No collection found for #{uuid}. Returning."
      exit 1
    end

    begin
      src_manifest = src_collection.manifest_text || ''

      # Get all the locators from the original manifest
      locators = []
      src_manifest.each_line do |line|
        line.split(' ').each do |word|
          if match = Keep::Locator::LOCATOR_REGEXP.match(word)
            word = word.split('+')[0..1].join('+')  # get rid of any hints
            locators << word if !word.start_with?('00000000000000000000000000000000')
          end
        end
      end
      locators << 'd41d8cd98f00b204e9800998ecf8427e+0' if !locators.any?

      # create new collection using 'arv-put' with original manifest_text as the data
      temp_file = Tempfile.new('temp')
      temp_file.write(src_manifest)
      temp_file.close
      new_manifest = %x(arv-put --as-stream --use-filename invalid_manifest_text.txt #{Shellwords::shellescape(temp_file.path)})
      temp_file.unlink

      new_collection = Collection.new

      total_size = 0
      locators.each do |locator|
        total_size += locator.split('+')[1].to_i
      end
      new_manifest += (". #{locators.join(' ')} 0:#{total_size}:salvaged_data\n")

      new_collection.name = "salvaged from #{src_collection.uuid}, #{src_collection.portable_data_hash}"
      new_collection.manifest_text = new_manifest
      new_collection.portable_data_hash = Digest::MD5.hexdigest(new_manifest)

      created = new_collection.save!
      raise "New collection creation failed." if !created

      $stderr.puts "Salvaged manifest and data for #{uuid} are in #{new_collection.uuid}."
      puts "Created new collection #{created}"
    rescue => error
      $stderr.puts "Error creating collection for #{uuid}: #{error}"
      exit 1
    end

    begin
      # update src_collection collection name, pdh, and manifest_text
      src_collection.name = (src_collection.name || '') + ' (' + (reason || '') + '; salvaged data at ' + created + ')'
      src_collection.portable_data_hash = 'd41d8cd98f00b204e9800998ecf8427e+0'
      src_collection.save!
      $stderr.puts "Collection #{uuid} emptied and renamed to #{src_collection.name.inspect}."
    rescue => error
      $stderr.puts "Error salvaging collection #{uuid}: #{error}"
      exit 1
    end
  end
end

# Salvage the collection with the given uuid
salvage_collection opts.uuid, opts.reason
