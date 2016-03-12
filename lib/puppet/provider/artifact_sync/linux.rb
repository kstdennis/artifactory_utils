require 'fileutils'

# Synchronized an artifatory repository by name to a destination
Puppet::Type.type(:artifact_sync).provide :linux do
  desc "Synchronizes an Artifactory repository on a linux server."

  defaultfor :osfamily => :RedHat

  # Given a key and properties array return the value
  def get_value(properties, key)
    # If the array is nil return nil
    if properties.nil?
      return nil
    end

    properties.each do |property|
      # Check key
      if property['key'] == key
        return property['value']
      end
    end

    # return nil if no value found
    return nil
  end

  def post_get(url,  user_name, password_hash)
    uri_get = URI.parse(url)
    http_get = Net::HTTP.new(uri_get.host, uri_get.port)

    request_get = Net::HTTP::Get.new(uri_get.request_uri)

    response = http_get.request(request_get)

    return response
  end

  def post_query(url, query, user_name, password_hash)
    uri_post = URI.parse(url)
    http_post = Net::HTTP.new(uri_post.host, uri_post.port)

    request_post = Net::HTTP::Post.new(uri_post.request_uri)

    request_post["Content-Type"] = "text/plain"
    request_post.basic_auth user_name, password_hash
    request_post.body = query.join
    
    response = http_post.request(request_post)

    return response
  end

  # The resource exists if all files and folders in place and
  # the files match the ones in Artifactory
  def exists?
    ensured_value = @resource.value(:ensure).to_s

    # Assign variables assigned by parameters
    #destination      = resource[:name]

    #artifactory_host = @resource.value(:artifactory_host)
    #user             = @resource.value(:user)
    #password         = @resource.value(:password)
    #repository_name  = @resource.value(:repository_name)
    #path_to_file     = @resource.value(:path_to_file)

    destination      = '/tmp/test.txt'

    artifactory_host = 'artifactory.azcender.com'
    user             = 'bryan'
    password         = 'AP3BsrCHWPkwniwUgbgp28RYqKW'
    repository_name  = 'sync-local'
    path_to_file     = '/fslink/11gR2/dir1/app1/file1.txt'


    # If the destination doesn't exists return false
    if !File.exists?(destination)
      return false
    end

    case ensured_value
    when 'absent'
      return true
    else
      # Get SHA1 value from Artifactory

      # File info URL
      file_info = 'http://' + artifactory_host + '/artifactory/' + repository_name + '/' + path_to_file

      response  = get_query(aql_url, user, password)

      results = JSON.parse(response.body)['results']

      p results
    end
  end

  # Delete all directories and files under destination
  def destroy
    destination = @resource.value(:destination)

    # Get all top level directories
    all_directories = Dir.glob(destination + '*')

    # Delete each and every directory
    FileUtils.rm_r all_directories
  end

  def create
    # Assign variables assigned by parameters
    artifactory_host = @resource.value(:artifactory_host)
    destination      = @resource.value(:destination)
    user             = @resource.value(:user)
    password         = @resource.value(:password)

    repository_name  = resource[:name]


    # All of the directories under the root
    all_directories = Dir.glob(destination + '**/')

    # All of the files under the root
    all_files = Dir.glob(destination + '**/*').reject {|fn| File.directory?(fn) }

    # The directories that should not be removed
    current_directories = []

    # The files that should not be removed
    current_files = []

    # AQL api search url
    aql_url = 'http://' + artifactory_host + '/artifactory/api/search/aql'

    query = repository_item_query(repository_name)

    response  = post_query(aql_url, query, user, password)
      
    results = JSON.parse(response.body)['results']

    results.each do |result|
      # Create item path and then remove all instances of ./
      item_path = destination + result['path'] + '/' + result['name']

      item_path.gsub!(/\/\.\//, '/')
      item_path.gsub!(/\/\.$/, '')

      # If the item (folder or file) doesn't exist create it
      if !File.exist?(item_path)
        if result['type'] == 'folder'
          Dir.mkdir item_path
        else
          write_file result, destination, artifactory_host
        end
      end

      # Get owner and group
      owner = Etc.getpwuid(File.stat(item_path).uid).name
      group = Etc.getpwuid(File.stat(item_path).gid).name
      mode =  (File.stat(item_path).mode & 07777).to_s(8)

      artifactory_owner = get_value(result['properties'], 'owner')
      artifactory_group = get_value(result['properties'], 'group')
      artifactory_mode = get_value(result['properties'], 'mode')

      # If the owner is defined make sure it matches
      if !artifactory_owner.nil? and artifactory_owner != owner
        uid = Etc.getpwnam(artifactory_owner).uid

        File.chown(uid, nil, item_path)
      end

      if !artifactory_group.nil? and artifactory_group != group
        gid = Etc.getpwnam(artifactory_group).uid
        
        File.chown(nil, gid, item_path)
      end

      # If the mode is defined make sure it matches
      if !artifactory_mode.nil? and artifactory_mode != mode

        artifactory_mode.gsub!(/^([1-9])/, '0\1')

        File.chmod(artifactory_mode.to_i(8), item_path)
      end

      if result['type'] == 'folder'
        current_directories.push item_path + '/'
      else
        current_files.push(item_path)

        # Compute digest for a file
        sha1 = Digest::SHA1.file item_path

        # Make sure the sha1 hashes match
        if sha1 != result['actual_sha1']
          write_file result, destination, artifactory_host
        end
      end
    end

    delete_files = all_files - current_files

    delete_files.each {|delete_file|
      File.delete(delete_file)
    }

    delete_dirs = all_directories - current_directories

    delete_dirs.each {|delete_dir|
      Dir.delete(delete_dir)
    }
  end
end