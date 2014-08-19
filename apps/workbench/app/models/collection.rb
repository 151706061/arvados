class Collection < ArvadosBase
  MD5_EMPTY = 'd41d8cd98f00b204e9800998ecf8427e'

  def default_name
    if Collection.is_empty_blob_locator? self.uuid
      "Empty Collection"
    else
      super
    end
  end

  # Return true if the given string is the locator of a zero-length blob
  def self.is_empty_blob_locator? locator
    !!locator.to_s.match("^#{MD5_EMPTY}(\\+.*)?\$")
  end

  def self.goes_in_projects?
    true
  end

  def content_summary
    ApplicationController.helpers.human_readable_bytes_html(total_bytes) + " " + super
  end

  def total_bytes
    if files
      tot = 0
      files.each do |file|
        tot += file[2]
      end
      tot
    else
      0
    end
  end

  def files_tree
    return [] if files.empty?
    tree = files.group_by { |file_spec| File.split(file_spec.first) }
    # Fill in entries for empty directories.
    tree.keys.map { |basedir, _| File.split(basedir) }.each do |splitdir|
      until tree.include?(splitdir)
        tree[splitdir] = []
        splitdir = File.split(splitdir.first)
      end
    end
    dir_to_tree = lambda do |dirname|
      # First list subdirectories, with their files inside.
      subnodes = tree.keys.select { |bd, td| (bd == dirname) and (td != '.') }
        .sort.flat_map do |parts|
        [parts + [nil]] + dir_to_tree.call(File.join(parts))
      end
      # Then extend that list with files in this directory.
      subnodes + tree[File.split(dirname)]
    end
    dir_to_tree.call('.')
  end

  def attribute_editable? attr, *args
    if %w(name description manifest_text).include? attr.to_s
      true
    else
      super
    end
  end

  def self.creatable?
    false
  end

  def provenance
    arvados_api_client.api "collections/#{self.uuid}/", "provenance"
  end

  def used_by
    arvados_api_client.api "collections/#{self.uuid}/", "used_by"
  end

  def uuid
    if self[:uuid].nil?
      return self.portable_data_hash
    else
      super
    end
  end

  def portable_data_hash
    if self[:portable_data_hash].nil?
      return self.uuid
    else
      super
    end
  end

  def friendly_link_name
    if self.respond_to? :name
      self.name
    else
      self.portable_data_hash
    end
  end

end
