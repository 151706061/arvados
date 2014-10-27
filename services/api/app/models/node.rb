class Node < ArvadosModel
  include HasUuid
  include KindAndEtag
  include CommonApiTemplate
  serialize :info, Hash
  serialize :properties, Hash
  before_validation :ensure_ping_secret
  after_update :dnsmasq_update

  # Only a controller can figure out whether or not the current API tokens
  # have access to the associated Job.  They're expected to set
  # job_readable=true if the Job UUID can be included in the API response.
  belongs_to(:job, foreign_key: :job_uuid, primary_key: :uuid)
  attr_accessor :job_readable

  MAX_SLOTS = 64

  @@confdir = Rails.configuration.dnsmasq_conf_dir
  @@domain = Rails.configuration.compute_node_domain rescue `hostname --domain`.strip
  @@nameservers = Rails.configuration.compute_node_nameservers

  api_accessible :user, :extend => :common do |t|
    t.add :hostname
    t.add :domain
    t.add :ip_address
    t.add :last_ping_at
    t.add :slot_number
    t.add :status
    t.add :api_job_uuid, as: :job_uuid
    t.add :crunch_worker_state
    t.add :properties
  end
  api_accessible :superuser, :extend => :user do |t|
    t.add :first_ping_at
    t.add :info
    t.add lambda { |x| @@nameservers }, :as => :nameservers
  end

  def domain
    super || @@domain
  end

  def api_job_uuid
    job_readable ? job_uuid : nil
  end

  def crunch_worker_state
    return 'down' if slot_number.nil?
    case self.info.andand['slurm_state']
    when 'alloc', 'comp'
      'busy'
    when 'idle'
      'idle'
    else
      'down'
    end
  end

  def status
    if !self.last_ping_at
      if Time.now - self.created_at > 5.minutes
        'startup-fail'
      else
        'pending'
      end
    elsif Time.now - self.last_ping_at > 1.hours
      'missing'
    else
      'running'
    end
  end

  def ping(o)
    raise "must have :ip and :ping_secret" unless o[:ip] and o[:ping_secret]

    if o[:ping_secret] != self.info['ping_secret']
      logger.info "Ping: secret mismatch: received \"#{o[:ping_secret]}\" != \"#{self.info['ping_secret']}\""
      raise ArvadosModel::UnauthorizedError.new("Incorrect ping_secret")
    end
    self.last_ping_at = Time.now

    @bypass_arvados_authorization = true

    # Record IP address
    if self.ip_address.nil?
      logger.info "#{self.uuid} ip_address= #{o[:ip]}"
      self.ip_address = o[:ip]
      self.first_ping_at = Time.now
    end

    # Record instance ID if not already known
    if o[:ec2_instance_id]
      if !self.info['ec2_instance_id']
        self.info['ec2_instance_id'] = o[:ec2_instance_id]
      elsif self.info['ec2_instance_id'] != o[:ec2_instance_id]
        logger.debug "Multiple nodes have credentials for #{self.uuid}"
        raise "#{self.uuid} is already running at #{self.info['ec2_instance_id']} so rejecting ping from #{o[:ec2_instance_id]}"
      end
    end

    # Assign hostname
    if self.slot_number.nil?
      try_slot = 0
      begin
        self.slot_number = try_slot
        begin
          self.save!
          break
        rescue ActiveRecord::RecordNotUnique
          try_slot += 1
        end
        raise "No available node slots" if try_slot == MAX_SLOTS
      end while true
      self.hostname = self.class.hostname_for_slot(self.slot_number)
    end

    # Record other basic stats
    ['total_cpu_cores', 'total_ram_mb', 'total_scratch_mb'].each do |key|
      if value = (o[key] or o[key.to_sym])
        self.properties[key] = value.to_i
      else
        self.properties.delete(key)
      end
    end

    save!
  end

  protected

  def ensure_ping_secret
    self.info['ping_secret'] ||= rand(2**256).to_s(36)
  end

  def dnsmasq_update
    if self.hostname_changed? or self.ip_address_changed?
      if self.hostname and self.ip_address
        self.class.dnsmasq_update(self.hostname, self.ip_address)
      end
    end
  end

  def self.dnsmasq_update(hostname, ip_address)
    return unless @@confdir
    ptr_domain = ip_address.
      split('.').reverse.join('.').concat('.in-addr.arpa')
    hostfile = File.join @@confdir, hostname
    File.open hostfile, 'w' do |f|
      f.puts "address=/#{hostname}/#{ip_address}"
      f.puts "address=/#{hostname}.#{@@domain}/#{ip_address}" if @@domain
      f.puts "ptr-record=#{ptr_domain},#{hostname}"
    end
    File.open(File.join(@@confdir, 'restart.txt'), 'w') do |f|
      # this should trigger a dnsmasq restart
    end
  end

  def self.hostname_for_slot(slot_number)
    "compute#{slot_number}"
  end

  # At startup, make sure all DNS entries exist.  Otherwise, slurmctld
  # will refuse to start.
  if @@confdir and
      !File.exists? (File.join(@@confdir, hostname_for_slot(MAX_SLOTS-1)))
    (0..MAX_SLOTS-1).each do |slot_number|
      hostname = hostname_for_slot(slot_number)
      hostfile = File.join @@confdir, hostname
      if !File.exists? hostfile
        dnsmasq_update(hostname, '127.40.4.0')
      end
    end
  end

  def permission_to_update
    @bypass_arvados_authorization or super
  end

  def permission_to_create
    current_user and current_user.is_admin
  end
end
