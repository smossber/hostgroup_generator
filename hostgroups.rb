#!/usr/bin/env ruby

# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA 02110-1301, USA.
#
#
# Sample framework based on katello-cvmanager (https://github.com/RedHatSatellite/katello-cvmanager/)

require 'optparse'
require 'yaml'
require 'apipie-bindings'
require 'highline/import'
require 'time'
require 'logging'
require 'awesome_print'
require 'rest-client'

@defaults = {
  :noop        => false,
  :keep        => 5,
  :uri         => 'https://localhost',
  :timeout     => 300,
  :user        => 'admin',
  :pass        => nil,
  :org         => "1",
  :lifecycle   => 1,
  :force       => false,
  :wait        => false,
  :sequential  => 0,
  :promote_cvs => false,
  :checkrepos  => false,
  :verbose     => false,
  :description => 'autopublish',
  :verify_ssl  => false,
}

@options = {
  :yamlfile  => 'hostgroups.yaml',
}

optparse = OptionParser.new do |opts|
  opts.banner = "Usage: #{opts.program_name} ACTION [options]"
  opts.version = "0.1"
  
  opts.separator ""
  opts.separator "#{opts.summary_indent}ACTION can be any of [clean,update,publish,promote]"
  opts.separator ""

  opts.on("-U", "--uri=URI", "URI to the Satellite") do |u|
    @options[:uri] = u
  end
  opts.on("-t", "--timeout=TIMEOUT", OptionParser::DecimalInteger, "Timeout value in seconds for any API calls. -1 means never timeout") do |t|
    @options[:timeout] = t
  end
  opts.on("-u", "--user=USER", "User to log in to Satellite") do |u|
    @options[:user] = u
  end
  opts.on("-p", "--pass=PASS", "Password to log in to Satellite") do |p|
    @options[:pass] = p
  end
  opts.on("-o", "--organization-id=ID", "ID of the Organization to manage CVs in") do |o|
    @options[:org] = o
  end
  opts.on("-k", "--keep=NUM", OptionParser::DecimalInteger, "how many unused versions should be kept") do |k|
    @options[:keep] = k
  end
  opts.on("-c", "--config=FILE", "configuration in YAML format") do |c|
    @options[:yamlfile] = c
  end
  opts.on("-l", "--to-lifecycle-environment=ID", OptionParser::DecimalInteger, "which LE should the promote be done to") do |l|
    @options[:lifecycle] = l
  end
  opts.on("-d", "--description=STRING", "Description to use for publish operations") do |d|
    @options[:description] = d
  end
  opts.on("-n", "--noop", "do not actually execute anything") do
    @options[:noop] = true
  end
  opts.on("-f", "--force", "force actions that otherwise would have been skipped") do
    @options[:force] = true
  end
  opts.on("--wait", "wait for started tasks to finish") do
    @options[:wait] = true
  end
  opts.on("--sequential [NUM]", OptionParser::DecimalInteger, "wait for each (or NUM) started task(s) to finish before starting the next one") do |s|
    @options[:wait] = true
    @options[:sequential] = s || 1
  end
  opts.on("--checkrepos", "check repository content was changed before publish") do
    @options[:checkrepos] = true
  end
  opts.on("-v", "--verbose", "Get verbose logs from cvmanager") do
    @options[:verbose] = true
  end
  opts.on("--very-verbose", "Get very verbose logs") do
    @options[:very_verbose] = true
    @options[:verbose] = true
  end
  opts.on("--no-verify-ssl", "don't verify SSL certs") do
    @options[:verify_ssl] = false
  end
  opts.on("-t", "--teardown", "Remove all hostgroups before creating them anew.") do
    @options[:teardown] = true
  end
  opts.on("--skip-creation", "Skip creation of hostgroup tree, just display how it would be") do
    @options[:skip_creation] = true
  end
  opts.on("--skip-combos", "Skip the hostgroup update with the combinations") do
    @options[:skip_combos] = true
  end
  opts.on("-u", "--update", "Update hostgroups that already exists") do
    @options[:update] = true
  end
end
optparse.parse!

#if ARGV.empty?
#  puts optparse.help
#  exit
#end

# Load the configuration file 
@yaml = YAML.load_file(@options[:yamlfile])

if @yaml.has_key?(:settings) and @yaml[:settings].is_a?(Hash)
  @yaml[:settings].each do |key,val|
    if not @options.has_key?(key)
      @options[key] = val
    end
  end
end

@defaults.each do |key,val|
  if not @options.has_key?(key)
    @options[key] = val
  end
end

# Ask for Satellite username and password
if not @options[:user]
  @options[:user] = ask('Satellite username: ')
end

if not @options[:pass]
  @options[:pass] = ask('Satellite password: ') { |q| q.echo = false }
end


# Set up the connection
# Uses username and password
if @options[:very_verbose]
	puts "VERY VERBOSE INDEEEED"
	@api = ApipieBindings::API.new({:uri => @options[:uri], :username => @options[:user], :password => @options[:pass], :api_version => '2', :timeout => @options[:timeout], :logger => Logging.logger(STDOUT)}, {:verify_ssl => @options[:verify_ssl]})
else
	@api = ApipieBindings::API.new({:uri => @options[:uri], :username => @options[:user], :password => @options[:pass], :api_version => '2', :timeout => @options[:timeout]}, {:verify_ssl => @options[:verify_ssl]})
end

# To print debug logging of the connection to STDOUT
# use following 
#@api = ApipieBindings::API.new({:uri => @options[:uri], :username => @options[:user], :password => @options[:pass], :api_version => '2', :timeout => @options[:timeout], :logger => Logging.logger(STDOUT)}, {:verify_ssl => @options[:verify_ssl]})


def puts_verbose(message)
  if @options[:verbose]
    puts "    [VERBOSE] #{message}"
  end
end

def depth (a)
  key, value = a.first
  return 0 unless a.is_a?(Hash)
  return 1 + depth(value)
end


# Array. [0] will be the first level, containing an Array of Hashes with the different Hostgroups of Hostgroups
# [1] will have the next level that should get added to each Hostgroup in [0]
# [2] will have the next level that should be added to each Hostgroup in [0].each[1]
# [3] will have the next level that should be added to each Hostgroup in [0].each [1].each [2].each ??
#
#
@tree_structure=[]

@level = 0
# Runs through the setup.
# Since we want a tree
def set_tree_structure(a)
  category, next_level = a.first
  return 0 unless a.is_a?(Hash)

  puts "All hostgroups in category \"#{category}\""
  hostgroups=[] # Array of hashes, to be entered in the levels array

  @categories[category].each do |hostgroup|
    if hostgroup.is_a?(Hash)
      hostgroup_name, hostgroup_props = hostgroup.first
      puts "#{hostgroup_name} "
    else
      puts hostgroup
    end
    hostgroups << hostgroup
  end
  @tree_structure << hostgroups
  @level = @level + 1
  set_tree_structure(next_level)
end



@categories = {}
if @yaml.has_key?(:categories) and @yaml[:categories].is_a?(Hash)
  @yaml[:categories].each do |key,val|
    @categories[key] = val
  end
end

puts "Categories:"
@categories.each do |category|
  puts category[0]
end

            # Workaround for Activation Keys
            # This is a host param ['kt_activation_keys']
            # If it's already present, it needs to be updated

def update_activation_keys(hostgroup_id, activation_keys)
    
    if activation_keys.is_a?(Array)
        activation_keys = activation_keys.join(",")
    end
    puts "Trying to update or create activation key #{activation_keys} for HG_ID #{hostgroup_id}"

    req = @api.call(:hostgroups, :show , {:organization_id => @options[:org], :id => hostgroup_id.to_i }) 
    puts_verbose "Current parameters for hostgroup (#{hostgroup_id}):"
    puts_verbose req['parameters']

    param_activation_key = req['parameters'].select {|param| param['name'] == 'kt_activation_keys' }
    if req['parameters'].empty? or param_activation_key.empty?
        puts_verbose( "No param kt_activation_key present.. creating key")
        req = @api.call(:parameters , :create , { :hostgroup_id => hostgroup_id.to_i, :parameter => { :name => 'kt_activation_keys', :value => activation_keys }}) 
        puts_verbose("added key")

    else
        param_activation_key = param_activation_key.first
        puts_verbose("Current param kt_activation_keys")
        puts_verbose("It has ID: #{param_activation_key['id']}")
        puts "Updating activation_key to #{activation_keys}"
        req = @api.call(:parameters , :update , { :hostgroup_id => hostgroup_id.to_i, :id => param_activation_key['id'].to_i , :parameter => { :name => 'kt_activation_keys', :value => activation_keys }}) 
        puts "Done"
    end

end

def assemble_hostgroup(name, properties=nil, parent_id = nil)
    puts_verbose("assembling hostgroup #{name}")
    hostgroup = {}
    hostgroup[:name] = name
    if properties.is_a?(Hash)
        puts_verbose("Got props")
        
        puts_verbose("fetching property id's")
        properties.each do |key, value|
            prop_id = get_property_id(key,value)
            if key == 'installation_media' or key == 'media'
                key = 'medium_id'
            end
            # Workaround for Lifecycle Environments.
            # Only one that expects a hash and plural key
            if key == 'location'
                key = 'location_ids'
                prop_id = [prop_id]
            elsif not key.end_with? '_id'
                key = key + '_id'	
            end
            hostgroup[key] = prop_id
        end
  
        if not parent_id.nil?
            puts_verbose("Got parent")
            puts_verbose("parent_id: #{parent_id}")
            hostgroup['parent_id'] = parent_id
        end
    end
    return hostgroup
end

# properties must be a Hash
def create_hostgroup(name, properties=nil, parent_id = nil)
    puts_verbose("create_hostgroup()")
    puts_verbose("name: #{name}")
    puts_verbose("properties #{properties}")
    puts_verbose("parent_id #{parent_id}")

    activation_key = ""
    if properties.key?('activation_key')
        activation_key = propertes['activation_key']
        properties.delete(:activation_key)
    end

    
    hostgroup = assemble_hostgroup(name, properties, parent_id)
    puts_verbose( "Serializing Hostgroup")
    # Try creating the hostgroup
    begin
        req = @api.resource(:hostgroups).call(:create, {:organization_id => @options[:org], :hostgroup => hostgroup } )
        if not activation_key.empty?
            update_activation_keys(req['id'], activation_key)
        end

        return req['id']

    # If the Hostgroup already exists, we want to update it.
    rescue RestClient::UnprocessableEntity
        if @options[:update]
            puts_verbose("Updating HG")
            hg_id = nil
            if not hostgroup['parent_id'].nil?
     	        puts_verbose("Got parent id, will look up it's title")
                parent = get_hostgroup_by_id(hostgroup['parent_id'])
                puts_verbose("PARENT TITLE: #{parent['title']}")
                hg_id = get_property_id('hostgroup', "#{parent['title']}/#{name}", "title")
            else
                # must be the first one, so should be safe to search for title = name
                hg_id = get_property_id("hostgroup", name, "title")
            end
            if hg_id.nil?
        		fail "No HG ID to update"
       	    end
       	    req = @api.resource(:hostgroups).call(:update, {:organization_id => @options[:org],:id => hg_id, :hostgroup => hostgroup } )
    		return req['id']
        else
        	fail "Hostgroup #{name} already exists, either specify --teardown or --update to overwrite existing Hostgroups"
        end
    end
end
def update_hostgroup_properties(id, properties)
    
    # Fetch existing Hostgroup
    current_hostgroup = get_hostgroup_by_id(id)
    puts_verbose("Updating Hostgroup #{current_hostgroup['name']}")

    activation_key = ""
    if properties.key?('activation_key')
        activation_key = properties['activation_key']
        properties.delete('activation_key')
    end

    new_hostgroup = assemble_hostgroup(current_hostgroup['name'], properties)
	puts_verbose("properties recieved #{properties}")
	puts_verbose("new hostgroup:")
	puts_verbose(new_hostgroup)
	req = @api.resource(:hostgroups).call(:update, {:organization_id => @options[:org],:id => id, :hostgroup => new_hostgroup } )
    if not activation_key.empty?
        update_activation_keys(req['id'], activation_key)
    end
end

def get_property_id(property_type, value, column=nil)
    puts_verbose("fetching id for property #{property_type} = #{value}")
    
    if value.nil?
        fail "Must specify a search value (get_property_id)"
    end
    if not  column.nil? 
        puts_verbose("specified search column: #{column}")
    end 

    property = [] 
    if property_type == 'content_source'
        property_type = "capsule"
    end
    if not property_type.end_with?('s')
        property_type = property_type + "s"
    end
    if property_type == 'installation_medias' or property_type == 'medias'
        property_type = "media"
    end
    property_type = property_type.to_sym

    begin
        if not column.nil?
            req = @api.call(property_type,:index, {:organization_id => @options[:org], :search => "#{column}=#{value}"}) 
        else
            req = @api.call(property_type,:index, {:organization_id => @options[:org], :search => "==#{value}"}) 
        end
        property.concat(req['results']) 
    
    rescue NameError
        fail "Resource #{property_type} does not exist. Edit your yaml file and change #{property_type} to something that fits the API doc resources"

    rescue RestClient::InternalServerError 
        puts_verbose("Allright, search didn't work, try..")
        puts_verbose("Try with API v1")
        begin
            if @options[:very_verbose]
                @api_v1 = ApipieBindings::API.new({:uri => @options[:uri], :username => @options[:user], :password => @options[:pass], :api_version => '1', :timeout => @options[:timeout], :logger => Logging.logger(STDOUT)}, {:verify_ssl => @options[:verify_ssl]})
            else
                @api_v1 = ApipieBindings::API.new({:uri => @options[:uri], :username => @options[:user], :password => @options[:pass], :api_version => '1', :timeout => @options[:timeout]}, {:verify_ssl => @options[:verify_ssl]})
            end
    
            req = @api_v1.call(property_type,:index, {:organization_id => @options[:org], :search => value }) 
            property = req
        rescue  RestClient::InternalServerError => e 
            puts "Something went wrong communicating with Satellite API"
            puts e.message
            fail
        end
    end
    if property.size > 1 
        fail "Too many results for search #{property_type} == #{value}, try to narrow the search down" 

    elsif property.size < 1  
        fail "No instance #{property_type} named #{value} found" 

    elsif property.size == 1 
        return property.first['id']

    end 
# puts JSON.pretty_generate(property) 
end 

def get_hostgroup(name)
  puts_verbose("Entering get_hostgroup")
  puts_verbose(name)
  if name.nil?
    exit("Name can't be empty (get_hostgroup())")
  end
  puts_verbose("Finding Hostgroup #{name}")
  hostgroups = []
  hostgroups = get_all_hostgroups

  the_hostgroup = {}
  hostgroups.each do |hg|
    if hg['title'] == name
      the_hostgroup = hg
      break
    end
  end
  if not the_hostgroup.nil?
    puts_verbose("Returning hostgroup #{the_hostgroup}")
    return the_hostgroup
  else
    exit("Couldn't find hostgroup named #{the_hostgroup}")
  end
end

def get_all_hostgroups
  hostgroups = []
  req = @api.resource(:hostgroups).call(:index, {:organization_id => @options[:org], :full_results => true})
  hostgroups.concat(req['results'])
  while (req['results'].length == req['per_page'].to_i)
    req = @api.resource(:hostgroups).call(:index, {:organization_id => @options[:org], :full_results => true, :per_page => req['per_page'], :page => req['page'].to_i+1})
    hostgroups.concat(req['results'])
  end
  return hostgroups
end
def get_hostgroup_by_id(id)
  puts_verbose("get_hostgroup_by_id(#{id})")
  hostgroups = []
  hostgroup = @api.resource(:hostgroups).call(:show, {:organization_id => @options[:org], :full_results => true,:id => id})
  puts_verbose("hostgroup")
  puts_verbose(hostgroup)
  puts_verbose("leaving")
  return hostgroup
end

def delete_hostgroup(id)
  req = @api.resource(:hostgroups).action(:destroy).call( :id => id )

end

def teardown
  hostgroups = [] 
  hostgroups = get_all_hostgroups()
  hostgroups = hostgroups.sort_by { |hash| hash['id'] }.reverse
  hostgroups.each do |hg|
    
    puts "Delete HG: #{hg['id']}"
    delete_hostgroup(hg['id'])

  end

end
tree = {}
if @yaml.has_key?(:tree) and @yaml[:tree].is_a?(Hash)
  @yaml[:tree].each do |key,val|
    tree[key] = val
  end
end

#set_tree_structure(tree)



def loop_branch(hash, deep, parent_id=nil) 
  space = "|__" * deep 
  if hash.is_a?(Hash) 
    branch_root, branch_arm = hash.first 
    puts "#{space}# Category: #{branch_root}" 
    @categories[branch_root].each do |hg_hash| 
      # <- should be an array of hash 
      # e.g. site:  <-- array 
      #       - DC01 <-- Hash,       Key 
      #           location: "DC01" , Value  
      #       - DC02                 KEY 
      #           location: "DC02"   Value 
      if hg_hash.is_a?(Hash) 
        hg_name, hg_props = hg_hash.first 


      # But sometimes it's not, when theres no properties assigned to the HG 
      elsif hg_hash.is_a?(String) 
        hg_name = hg_hash 
        hg_props = nil
      end 
        if not @options[:skip_creation]
            created_hg_id = create_hostgroup(hg_name,hg_props,parent_id)
            puts "#{space}#{hg_name}(#{created_hg_id}), parent-id: #{parent_id}" 
        else
            puts "#{space}#{hg_name}" 
        
        end
      # no deeper category
      if branch_arm.nil? 
        break 
      end 
      # enter next loop and increment depth 
      loop_branch(branch_arm, deep + 1, created_hg_id) 
    end 
#    loop_branch(branch_arm) 
  elsif hash.is_a?(Array) 
    hash.each do |branch| 
      loop_branch(branch, deep, parent_id) 
    end  
  end 
end 

# Teardown the Hostgroup tree before creating anew
if @options[:teardown]
	teardown
end

# Start Hostgroup Loop
    deep = 0  
    loop_branch(tree, deep ) 

@hostgroups = []
@hostgroups = get_all_hostgroups
def find_matching_hostgroups(combo)
	if combo.is_a?(Array)
        combo_hostgroups = []
        combo_count = combo.count

        criteria_arrays = []

        combo.each do |combination|
            if combination.is_a?(Array)
                criteria_arrays << combination
            else
                array = [combination]
                criteria_arrays << array
            end
        end

        puts "Criteria_arrays"
        criteria_arrays.each do |crit_combo|
            puts "#{crit_combo}"
        end
        # MAGIC!
        prod = criteria_arrays[0].product(*criteria_arrays[1..-1])
        i=1
        prod.each do |comb|
            puts "Combination (#{i}): #{comb}"
            i = i + 1
        end

		#if combo.any? { |combination| combination.is_a?(Array) }
    	@hostgroups.each do |hostgroup|
		#if hostgroup['title'].include?(combo.to_s)
		    prod.each do |comb|
    			if comb.all? { |word| hostgroup['title'].include?("/#{word}") }
	    			puts_verbose("#{hostgroup['id']}:#{hostgroup['title']} match with #{comb}")
    	    		combo_hostgroups << hostgroup
    		    end
            end
		end
		return combo_hostgroups
	else
		fail "find_matching_hostgroups needs an Array"
	end
end


def combos()
    @combos = []
    if @yaml.has_key?(:combos) and @yaml[:combos].is_a?(Array)
        puts "Combos:"
        puts "======"
        @yaml[:combos].each do |combo|
            puts ""
            puts "# #{combo['name']}"
            combo_hostgroups = []
            properties = {}
            combo.each do |combo_key,combo_val|
                if combo_key != 'name' and combo_key == 'categories'
                    puts "Categories to match:"
                    combo_array = []
                    combo_val.each do |cat|
                        cat_name, cat_value = cat.first
                        puts "- #{cat_name}: #{cat_value}"
                        combo_array << cat_value
                    end
                    combo_hostgroups = find_matching_hostgroups(combo_array)

                    puts ""
                    puts "Matching Hostgroups"
                    combo_hostgroups.each do |hg|
                        puts "- " + hg['title']
                    end
                end
                if combo_key == 'parameters'
                    puts ""
                    puts "Should get:"
                    combo_val.each do |prop|
                        prop_name, prop_value = prop.first
                        puts "#{prop_name}: #{prop_value}"
                        properties[prop_name] = prop_value
                    end
                end
            end # combo.each 

            puts ""
            combo_hostgroups.each do |hostgroup|
                puts "#{hostgroup['title']} #{hostgroup['id']} updating with #{properties}"
                update_hostgroup_properties(hostgroup['id'], properties)
            end
        end
    end
end
if not @options[:skip_combos]
    combos
end



