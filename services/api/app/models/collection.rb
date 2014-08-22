class Collection < ArvadosModel
  include HasUuid
  include KindAndEtag
  include CommonApiTemplate

  before_validation :check_signatures
  before_validation :strip_manifest_text
  before_validation :set_portable_data_hash
  validate :ensure_hash_matches_manifest_text

  api_accessible :user, extend: :common do |t|
    t.add :data_size
    t.add :files
    t.add :name
    t.add :description
    t.add :properties
    t.add :portable_data_hash
    t.add :manifest_text
  end

  def self.attributes_required_columns
    super.merge({ "data_size" => ["manifest_text"],
                  "files" => ["manifest_text"],
                })
  end

  def check_signatures
    return false if self.manifest_text.nil?

    return true if current_user.andand.is_admin

    if self.manifest_text_changed?
      # Check permissions on the collection manifest.
      # If any signature cannot be verified, raise PermissionDeniedError
      # which will return 403 Permission denied to the client.
      api_token = current_api_client_authorization.andand.api_token
      signing_opts = {
        key: Rails.configuration.blob_signing_key,
        api_token: api_token,
        ttl: Rails.configuration.blob_signing_ttl,
      }
      self.manifest_text.lines.each do |entry|
        entry.split[1..-1].each do |tok|
          if /^[[:digit:]]+:[[:digit:]]+:/.match tok
            # This is a filename token, not a blob locator. Note that we
            # keep checking tokens after this, even though manifest
            # format dictates that all subsequent tokens will also be
            # filenames. Safety first!
          elsif Blob.verify_signature tok, signing_opts
            # OK.
          elsif Locator.parse(tok).andand.signature
            # Signature provided, but verify_signature did not like it.
            logger.warn "Invalid signature on locator #{tok}"
            raise ArvadosModel::PermissionDeniedError
          elsif Rails.configuration.permit_create_collection_with_unsigned_manifest
            # No signature provided, but we are running in insecure mode.
            logger.debug "Missing signature on locator #{tok} ignored"
          elsif Blob.new(tok).empty?
            # No signature provided -- but no data to protect, either.
          else
            logger.warn "Missing signature on locator #{tok}"
            raise ArvadosModel::PermissionDeniedError
          end
        end
      end
    end
    true
  end

  def strip_manifest_text
    if self.manifest_text_changed?
      # Remove any permission signatures from the manifest.
      Collection.munge_manifest_locators(self[:manifest_text]) do |loc|
        loc.without_signature.to_s
      end
    end
    true
  end

  def set_portable_data_hash
    if (self.portable_data_hash.nil? or (self.portable_data_hash == "") or (manifest_text_changed? and !portable_data_hash_changed?))
      self.portable_data_hash = "#{Digest::MD5.hexdigest(manifest_text)}+#{manifest_text.length}"
    elsif portable_data_hash_changed?
      begin
        loc = Locator.parse!(self.portable_data_hash)
        loc.strip_hints!
        self.portable_data_hash = loc.to_s
      rescue ArgumentError => e
        errors.add(:portable_data_hash, "#{e}")
        return false
      end
    end
    true
  end

  def ensure_hash_matches_manifest_text
    if manifest_text_changed? or portable_data_hash_changed?
      computed_hash = "#{Digest::MD5.hexdigest(manifest_text)}+#{manifest_text.length}"
      unless computed_hash == portable_data_hash
        logger.debug "(computed) '#{computed_hash}' != '#{portable_data_hash}' (provided)"
        errors.add(:portable_data_hash, "does not match hash of manifest_text")
        return false
      end
    end
    true
  end

  def redundancy_status
    if redundancy_confirmed_as.nil?
      'unconfirmed'
    elsif redundancy_confirmed_as < redundancy
      'degraded'
    else
      if redundancy_confirmed_at.nil?
        'unconfirmed'
      elsif Time.now - redundancy_confirmed_at < 7.days
        'OK'
      else
        'stale'
      end
    end
  end

  def data_size
    inspect_manifest_text if @data_size.nil? or manifest_text_changed?
    @data_size
  end

  def files
    inspect_manifest_text if @files.nil? or manifest_text_changed?
    @files
  end

  def inspect_manifest_text
    if !manifest_text
      @data_size = false
      @files = []
      return
    end

    @data_size = 0
    tmp = {}

    manifest_text.split("\n").each do |stream|
      toks = stream.split(" ")

      stream = toks[0].gsub /\\(\\|[0-7]{3})/ do |escape_sequence|
        case $1
        when '\\' '\\'
        else $1.to_i(8).chr
        end
      end

      toks[1..-1].each do |tok|
        if (re = tok.match /^[0-9a-f]{32}/)
          blocksize = nil
          tok.split('+')[1..-1].each do |hint|
            if !blocksize and hint.match /^\d+$/
              blocksize = hint.to_i
            end
            if (re = hint.match /^GS(\d+)$/)
              blocksize = re[1].to_i
            end
          end
          @data_size = false if !blocksize
          @data_size += blocksize if @data_size
        else
          if (re = tok.match /^(\d+):(\d+):(\S+)$/)
            filename = re[3].gsub /\\(\\|[0-7]{3})/ do |escape_sequence|
              case $1
              when '\\' '\\'
              else $1.to_i(8).chr
              end
            end
            fn = stream + '/' + filename
            i = re[2].to_i
            if tmp[fn]
              tmp[fn] += i
            else
              tmp[fn] = i
            end
          end
        end
      end
    end

    @files = []
    tmp.each do |k, v|
      re = k.match(/^(.+)\/(.+)/)
      @files << [re[1], re[2], v]
    end
  end

  def self.munge_manifest_locators(manifest)
    # Given a manifest text and a block, yield each locator,
    # and replace it with whatever the block returns.
    manifest.andand.gsub!(/ [[:xdigit:]]{32}(\+[[:digit:]]+)?(\+\S+)/) do |word|
      if loc = Locator.parse(word.strip)
        " " + yield(loc)
      else
        " " + word
      end
    end
  end

  def self.normalize_uuid uuid
    hash_part = nil
    size_part = nil
    uuid.split('+').each do |token|
      if token.match /^[0-9a-f]{32,}$/
        raise "uuid #{uuid} has multiple hash parts" if hash_part
        hash_part = token
      elsif token.match /^\d+$/
        raise "uuid #{uuid} has multiple size parts" if size_part
        size_part = token
      end
    end
    raise "uuid #{uuid} has no hash part" if !hash_part
    [hash_part, size_part].compact.join '+'
  end

  # Return array of Collection objects
  def self.find_all_for_docker_image(search_term, search_tag=nil, readers=nil)
    readers ||= [Thread.current[:user]]
    base_search = Link.
      readable_by(*readers).
      readable_by(*readers, table_name: "collections").
      joins("JOIN collections ON links.head_uuid = collections.uuid").
      order("links.created_at DESC")

    # If the search term is a Collection locator that contains one file
    # that looks like a Docker image, return it.
    if loc = Locator.parse(search_term)
      loc.strip_hints!
      coll_match = readable_by(*readers).where(portable_data_hash: loc.to_s).limit(1).first
      if coll_match and (coll_match.files.size == 1) and
          (coll_match.files[0][1] =~ /^[0-9A-Fa-f]{64}\.tar$/)
        return [coll_match]
      end
    end

    if search_tag.nil? and (n = search_term.index(":"))
      search_tag = search_term[n+1..-1]
      search_term = search_term[0..n-1]
    end

    # Find Collections with matching Docker image repository+tag pairs.
    matches = base_search.
      where(link_class: "docker_image_repo+tag",
            name: "#{search_term}:#{search_tag || 'latest'}")

    # If that didn't work, find Collections with matching Docker image hashes.
    if matches.empty?
      matches = base_search.
        where("link_class = ? and links.name LIKE ?",
              "docker_image_hash", "#{search_term}%")
    end

    # Generate an order key for each result.  We want to order the results
    # so that anything with an image timestamp is considered more recent than
    # anything without; then we use the link's created_at as a tiebreaker.
    uuid_timestamps = {}
    matches.all.map do |link|
      uuid_timestamps[link.head_uuid] = [(-link.properties["image_timestamp"].to_datetime.to_i rescue 0),
       -link.created_at.to_i]
    end
    Collection.where('uuid in (?)', uuid_timestamps.keys).sort_by { |c| uuid_timestamps[c.uuid] }
  end

  def self.for_latest_docker_image(search_term, search_tag=nil, readers=nil)
    find_all_for_docker_image(search_term, search_tag, readers).first
  end
end
