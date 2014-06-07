class PipelineInstance < ArvadosBase
  attr_accessor :pipeline_template

  def self.goes_in_projects?
    true
  end

  def content_summary
    begin
      PipelineTemplate.find(pipeline_template_uuid).name
    rescue
      super
    end
  end

  def update_job_parameters(new_params)
    self.components[:steps].each_with_index do |step, i|
      step[:params].each do |param|
        if new_params.has_key?(new_param_name = "#{i}/#{param[:name]}") or
            new_params.has_key?(new_param_name = "#{step[:name]}/#{param[:name]}") or
            new_params.has_key?(new_param_name = param[:name])
          param_type = :value
          %w(hash data_locator).collect(&:to_sym).each do |ptype|
            param_type = ptype if param.has_key? ptype
          end
          param[param_type] = new_params[new_param_name]
        end
      end
    end
  end
  
  def attribute_editable? attr, *args
    super && (attr.to_sym == :name ||
              (attr.to_sym == :components and
               (self.state == 'New' || self.state == 'Ready')))
  end

  def attributes_for_display
    super.reject { |k,v| k == 'components' }
  end

  def self.creatable?
    false
  end
end
