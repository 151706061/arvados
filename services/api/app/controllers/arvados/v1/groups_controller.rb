class Arvados::V1::GroupsController < ApplicationController

  def self._contents_requires_parameters
    _index_requires_parameters.
      merge({
              uuid: {
                type: 'string', required: false, default: nil
              },
              include_linked: {
                type: 'boolean', required: false, default: false
              },
            })
  end

  def render_404_if_no_object
    if params[:action] == 'contents' and !params[:uuid]
      # OK!
      @object = nil
    else
      super
    end
  end

  def contents
    # Set @objects:
    load_searchable_objects(owner_uuid: @object.andand.uuid, include_linked: params[:include_linked])

    sql = 'link_class=? and head_uuid in (?)'
    sql_params = ['name', @objects.collect(&:uuid)]
    if @object
      sql += ' and tail_uuid=?'
      sql_params << @object.uuid
    end
    @links = Link.where sql, *sql_params
    @object_list = {
      :kind  => "arvados#objectList",
      :etag => "",
      :self_link => "",
      :links => @links.as_api_response(nil),
      :offset => @offset,
      :limit => @limit,
      :items_available => @items_available,
      :items => @objects.as_api_response(nil)
    }
    render json: @object_list
  end

  protected

  def load_searchable_objects opts
    all_objects = []
    @items_available = 0

    # Trick apply_where_limit_order_params into applying suitable
    # per-table values. *_all are the real ones we'll apply to the
    # aggregate set.
    limit_all = @limit
    offset_all = @offset
    @orders = []

    [Group,
     Job, PipelineInstance, PipelineTemplate,
     Collection,
     Human, Specimen, Trait].each do |klass|
      @objects = klass.readable_by(*@read_users)
      if klass == Group
        @objects = @objects.where('group_class = ?', 'project')
      end
      conds = []
      cond_params = []
      if opts[:owner_uuid]
        conds << "#{klass.table_name}.owner_uuid = ?"
        cond_params << opts[:owner_uuid]
      end
      if opts[:include_linked]
        conds << "#{klass.table_name}.uuid IN (SELECT head_uuid FROM links WHERE link_class=#{klass.sanitize 'name'} AND links.tail_uuid=#{klass.sanitize @object.uuid})"
      end
      if conds.any?
        cond_sql = '(' + conds.join(') OR (') + ')'
        @objects = @objects.where(cond_sql, *cond_params)
      end
      @objects = @objects.order("#{klass.table_name}.uuid")
      @limit = limit_all - all_objects.count
      apply_where_limit_order_params
      klass_items_available = @objects.
        except(:limit).except(:offset).
        count(:id, distinct: true)
      @items_available += klass_items_available
      @offset = [@offset - klass_items_available, 0].max

      all_objects += @objects.to_a
    end

    @objects = all_objects
    @limit = limit_all
    @offset = offset_all
  end

end
