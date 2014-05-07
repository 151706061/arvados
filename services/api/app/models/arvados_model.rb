require 'assign_uuid'
class ArvadosModel < ActiveRecord::Base
  self.abstract_class = true

  include CurrentApiClient      # current_user, current_api_client, etc.

  attr_protected :created_at
  attr_protected :modified_by_user_uuid
  attr_protected :modified_by_client_uuid
  attr_protected :modified_at
  after_initialize :log_start_state
  before_save :ensure_permission_to_save
  before_save :ensure_owner_uuid_is_permitted
  before_save :ensure_ownership_path_leads_to_user
  before_destroy :ensure_owner_uuid_is_permitted
  before_destroy :ensure_permission_to_destroy

  before_create :update_modified_by_fields
  before_update :maybe_update_modified_by_fields
  after_create :log_create
  after_update :log_update
  after_destroy :log_destroy
  validate :ensure_serialized_attribute_type
  validate :normalize_collection_uuids
  validate :ensure_valid_uuids

  # Note: This only returns permission links. It does not account for
  # permissions obtained via user.is_admin or
  # user.uuid==object.owner_uuid.
  has_many :permissions, :foreign_key => :head_uuid, :class_name => 'Link', :primary_key => :uuid, :conditions => "link_class = 'permission'"

  class PermissionDeniedError < StandardError
    def http_status
      403
    end
  end

  class UnauthorizedError < StandardError
    def http_status
      401
    end
  end

  def self.kind_class(kind)
    kind.match(/^arvados\#(.+)$/)[1].classify.safe_constantize rescue nil
  end

  def href
    "#{current_api_base}/#{self.class.to_s.pluralize.underscore}/#{self.uuid}"
  end

  def self.searchable_columns operator
    textonly_operator = !operator.match(/[<=>]/)
    self.columns.collect do |col|
      if [:string, :text].index(col.type)
        col.name
      elsif !textonly_operator and [:datetime, :integer].index(col.type)
        col.name
      end
    end.compact
  end

  def self.attribute_column attr
    self.columns.select { |col| col.name == attr.to_s }.first
  end

  # Return nil if current user is not allowed to see the list of
  # writers. Otherwise, return a list of user_ and group_uuids with
  # write permission. (If not returning nil, current_user is always in
  # the list because can_manage permission is needed to see the list
  # of writers.)
  def writable_by
    unless (owner_uuid == current_user.uuid or
            current_user.is_admin or
            current_user.groups_i_can(:manage).index(owner_uuid))
      return nil
    end
    [owner_uuid, current_user.uuid] + permissions.collect do |p|
      if ['can_write', 'can_manage'].index p.name
        p.tail_uuid
      end
    end.compact.uniq
  end

  # Return a query with read permissions restricted to the union of of the
  # permissions of the members of users_list, i.e. if something is readable by
  # any user in users_list, it will be readable in the query returned by this
  # function.
  def self.readable_by(*users_list)
    # Get rid of troublesome nils
    users_list.compact!

    # Check if any of the users are admin.  If so, we're done.
    if users_list.select { |u| u.is_admin }.empty?

      # Collect the uuids for each user and any groups readable by each user.
      user_uuids = users_list.map { |u| u.uuid }
      uuid_list = user_uuids + users_list.flat_map { |u| u.groups_i_can(:read) }
      sanitized_uuid_list = uuid_list.
        collect { |uuid| sanitize(uuid) }.join(', ')
      sql_conds = []
      sql_params = []
      or_object_uuid = ''

      # This row is owned by a member of users_list, or owned by a group
      # readable by a member of users_list
      # or
      # This row uuid is the uuid of a member of users_list
      # or
      # A permission link exists ('write' and 'manage' implicitly include
      # 'read') from a member of users_list, or a group readable by users_list,
      # to this row, or to the owner of this row (see join() below).
      permitted_uuids = "(SELECT head_uuid FROM links WHERE link_class='permission' AND tail_uuid IN (#{sanitized_uuid_list}))"

      sql_conds += ["#{table_name}.owner_uuid in (?)",
                    "#{table_name}.uuid in (?)",
                    "#{table_name}.uuid IN #{permitted_uuids}"]
      sql_params += [uuid_list, user_uuids]

      if self == Link and users_list.any?
        # This row is a 'permission' or 'resources' link class
        # The uuid for a member of users_list is referenced in either the head
        # or tail of the link
        sql_conds += ["(#{table_name}.link_class in (#{sanitize 'permission'}, #{sanitize 'resources'}) AND (#{table_name}.head_uuid IN (?) OR #{table_name}.tail_uuid IN (?)))"]
        sql_params += [user_uuids, user_uuids]
      end

      if self == Log and users_list.any?
        # Link head points to the object described by this row
        sql_conds += ["#{table_name}.object_uuid IN #{permitted_uuids}"]

        # This object described by this row is owned by this user, or owned by a group readable by this user
        sql_conds += ["#{table_name}.object_owner_uuid in (?)"]
        sql_params += [uuid_list]
      end

      # Link head points to this row, or to the owner of this row (the thing to be read)
      #
      # Link tail originates from this user, or a group that is readable by this
      # user (the identity with authorization to read)
      #
      # Link class is 'permission' ('write' and 'manage' implicitly include 'read')
      where(sql_conds.join(' OR '), *sql_params)
    else
      # At least one user is admin, so don't bother to apply any restrictions.
      self
    end
  end

  def logged_attributes
    attributes
  end

  protected

  def ensure_ownership_path_leads_to_user
    if new_record? or owner_uuid_changed?
      uuid_in_path = {owner_uuid => true, uuid => true}
      x = owner_uuid
      while (owner_class = self.class.resource_class_for_uuid(x)) != User
        begin
          if x == uuid
            # Test for cycles with the new version, not the DB contents
            x = owner_uuid
          elsif !owner_class.respond_to? :find_by_uuid
            raise ActiveRecord::RecordNotFound.new
          else
            x = owner_class.find_by_uuid(x).owner_uuid
          end
        rescue ActiveRecord::RecordNotFound => e
          errors.add :owner_uuid, "is not owned by any user: #{e}"
          return false
        end
        if uuid_in_path[x]
          if x == owner_uuid
            errors.add :owner_uuid, "would create an ownership cycle"
          else
            errors.add :owner_uuid, "has an ownership cycle"
          end
          return false
        end
        uuid_in_path[x] = true
      end
    end
    true
  end

  def ensure_owner_uuid_is_permitted
    raise PermissionDeniedError if !current_user
    self.owner_uuid ||= current_user.uuid
    if self.owner_uuid_changed?
      if current_user.uuid == self.owner_uuid or
          current_user.can? write: self.owner_uuid
        # current_user is, or has :write permission on, the new owner
      else
        logger.warn "User #{current_user.uuid} tried to change owner_uuid of #{self.class.to_s} #{self.uuid} to #{self.owner_uuid} but does not have permission to write to #{self.owner_uuid}"
        raise PermissionDeniedError
      end
    end
    if new_record?
      return true
    elsif current_user.uuid == self.owner_uuid_was or
        current_user.uuid == self.uuid or
        current_user.can? write: self.owner_uuid_was
      # current user is, or has :write permission on, the previous owner
      return true
    else
      logger.warn "User #{current_user.uuid} tried to modify #{self.class.to_s} #{self.uuid} but does not have permission to write #{self.owner_uuid_was}"
      raise PermissionDeniedError
    end
  end

  def ensure_permission_to_save
    unless (new_record? ? permission_to_create : permission_to_update)
      raise PermissionDeniedError
    end
  end

  def permission_to_create
    current_user.andand.is_active
  end

  def permission_to_update
    if !current_user
      logger.warn "Anonymous user tried to update #{self.class.to_s} #{self.uuid_was}"
      return false
    end
    if !current_user.is_active
      logger.warn "Inactive user #{current_user.uuid} tried to update #{self.class.to_s} #{self.uuid_was}"
      return false
    end
    return true if current_user.is_admin
    if self.uuid_changed?
      logger.warn "User #{current_user.uuid} tried to change uuid of #{self.class.to_s} #{self.uuid_was} to #{self.uuid}"
      return false
    end
    return true
  end

  def ensure_permission_to_destroy
    raise PermissionDeniedError unless permission_to_destroy
  end

  def permission_to_destroy
    permission_to_update
  end

  def maybe_update_modified_by_fields
    update_modified_by_fields if self.changed? or self.new_record?
    true
  end

  def update_modified_by_fields
    self.updated_at = Time.now
    self.owner_uuid ||= current_default_owner if self.respond_to? :owner_uuid=
    self.modified_at = Time.now
    self.modified_by_user_uuid = current_user ? current_user.uuid : nil
    self.modified_by_client_uuid = current_api_client ? current_api_client.uuid : nil
    true
  end

  def ensure_serialized_attribute_type
    # Specifying a type in the "serialize" declaration causes rails to
    # raise an exception if a different data type is retrieved from
    # the database during load().  The validation preventing such
    # crash-inducing records from being inserted in the database in
    # the first place seems to have been left as an exercise to the
    # developer.
    self.class.serialized_attributes.each do |colname, attr|
      if attr.object_class
        unless self.attributes[colname].is_a? attr.object_class
          self.errors.add colname.to_sym, "must be a #{attr.object_class.to_s}"
        end
      end
    end
  end

  def foreign_key_attributes
    attributes.keys.select { |a| a.match /_uuid$/ }
  end

  def skip_uuid_read_permission_check
    %w(modified_by_client_uuid)
  end

  def skip_uuid_existence_check
    []
  end

  def normalize_collection_uuids
    foreign_key_attributes.each do |attr|
      attr_value = send attr
      if attr_value.is_a? String and
          attr_value.match /^[0-9a-f]{32,}(\+[@\w]+)*$/
        begin
          send "#{attr}=", Collection.normalize_uuid(attr_value)
        rescue
          # TODO: abort instead of silently accepting unnormalizable value?
        end
      end
    end
  end

  @@UUID_REGEX = /^[0-9a-z]{5}-([0-9a-z]{5})-[0-9a-z]{15}$/

  @@prefixes_hash = nil
  def self.uuid_prefixes
    unless @@prefixes_hash
      @@prefixes_hash = {}
      ActiveRecord::Base.descendants.reject(&:abstract_class?).each do |k|
        if k.respond_to?(:uuid_prefix)
          @@prefixes_hash[k.uuid_prefix] = k
        end
      end
    end
    @@prefixes_hash
  end

  def self.uuid_like_pattern
    "_____-#{uuid_prefix}-_______________"
  end

  def ensure_valid_uuids
    specials = [system_user_uuid, 'd41d8cd98f00b204e9800998ecf8427e+0']

    foreign_key_attributes.each do |attr|
      if new_record? or send (attr + "_changed?")
        next if skip_uuid_existence_check.include? attr
        attr_value = send attr
        next if specials.include? attr_value
        if attr_value
          if (r = ArvadosModel::resource_class_for_uuid attr_value)
            unless skip_uuid_read_permission_check.include? attr
              r = r.readable_by(current_user)
            end
            if r.where(uuid: attr_value).count == 0
              errors.add(attr, "'#{attr_value}' not found")
            end
          end
        end
      end
    end
  end

  class Email
    def self.kind
      "email"
    end

    def kind
      self.class.kind
    end

    def self.readable_by (*u)
      self
    end

    def self.where (u)
      [{:uuid => u[:uuid]}]
    end
  end

  def self.resource_class_for_uuid(uuid)
    if uuid.is_a? ArvadosModel
      return uuid.class
    end
    unless uuid.is_a? String
      return nil
    end
    if uuid.match /^[0-9a-f]{32}(\+[^,]+)*(,[0-9a-f]{32}(\+[^,]+)*)*$/
      return Collection
    end
    resource_class = nil

    Rails.application.eager_load!
    uuid.match @@UUID_REGEX do |re|
      return uuid_prefixes[re[1]] if uuid_prefixes[re[1]]
    end

    if uuid.match /.+@.+/
      return Email
    end

    nil
  end

  def log_start_state
    @old_etag = etag
    @old_attributes = logged_attributes
  end

  def log_change(event_type)
    log = Log.new(event_type: event_type).fill_object(self)
    yield log
    log.save!
    connection.execute "NOTIFY logs, '#{log.id}'"
    log_start_state
  end

  def log_create
    log_change('create') do |log|
      log.fill_properties('old', nil, nil)
      log.update_to self
    end
  end

  def log_update
    log_change('update') do |log|
      log.fill_properties('old', @old_etag, @old_attributes)
      log.update_to self
    end
  end

  def log_destroy
    log_change('destroy') do |log|
      log.fill_properties('old', @old_etag, @old_attributes)
      log.update_to nil
    end
  end
end
