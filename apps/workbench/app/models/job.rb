class Job < ArvadosBase
  def self.goes_in_projects?
    true
  end

  def content_summary
    "#{script} job"
  end

  def attribute_editable? attr, *args
    if attr.to_sym == :description
      super && attr.to_sym == :description
    else
      false
    end
  end

  def self.creatable?
    false
  end

  def default_name
    if script
      x = "\"#{script}\" job"
    else
      x = super
    end
    if finished_at
      x += " finished #{finished_at.strftime('%b %-d')}"
    elsif started_at
      x += " started #{started_at.strftime('%b %-d')}"
    elsif created_at
      x += " submitted #{created_at.strftime('%b %-d')}"
    end
  end

  def cancel
    arvados_api_client.api "jobs/#{self.uuid}/", "cancel", {}
  end

  def self.queue_size
    arvados_api_client.api("jobs/", "queue_size", {"_method"=> "GET"})[:queue_size] rescue 0
  end

  def self.queue 
    arvados_api_client.unpack_api_response arvados_api_client.api("jobs/", "queue", {"_method"=> "GET"})
  end

  # The 'job' parameter can be either a Job model object, or a hash containing
  # the same fields as a Job object (such as the :job entry of a pipeline
  # component).
  def self.state job
    # This has a valid state method on it so call that
    if job.respond_to? :state and job.state
      return job.state
    end

    # Figure out the state based on the other fields.
    if job[:cancelled_at]
      "Cancelled"
    elsif job[:success] == false
      "Failed"
    elsif job[:success] == true
      "Complete"
    elsif job[:running] == true
      "Running"
    else
      "Queued"
    end
  end

  def textile_attributes
    [ 'description' ]
  end
end
