#!/bin/env ruby
require 'yaml'

@options = {
  :yamlfile  => 'hostgroups.yaml',
}

@yaml = YAML.load_file(@options[:yamlfile])

@categories = {}
if @yaml.has_key?(:categories) and @yaml[:categories].is_a?(Hash)
  @yaml[:categories].each do |key,val|
    @categories[key] = val
  end
end

puts "Categories:"
puts "Hash"
@categories.each do |cat_key,cat_val|
end

setup = {}
if @yaml.has_key?(:tree) and @yaml[:tree].is_a?(Hash)
  @yaml[:tree].each do |key,val|
    setup[key] = val
  end
end

def loop_branch(hash, deep)
  space = "|__" * deep
  if hash.is_a?(Hash)
    branch_root, branch_arm = hash.first
    puts "#{space}# Category: #{branch_root} #{deep}"
    @categories[branch_root].each do |hg_hash|
      # <- should be an array of hash
      # e.g. site:  <-- array
      #       - CB <-- Hash,       Key
      #           location: "CB" , Value 
      #       - HH                 KEY
      #           location: "HH"   Value
      if hg_hash.is_a?(Hash)
        hg_name, hg_props = hg_hash.first

      # But sometimes it's not, when theres no properties assigned to the HG
      # eg. DCD
      elsif hg_hash.is_a?(String)
        hg_name = hg_hash
      end

      puts "#{space}#{hg_name}"

      # increment depth
      if branch_arm.nil?
        break
      end
      loop_branch(branch_arm, deep + 1)
    end
#    loop_branch(branch_arm)
  elsif hash.is_a?(Array)
    hash.each do |branch|
      loop_branch(branch, deep)
    end 
  end
end
deep = 0 
loop_branch(setup, deep )
