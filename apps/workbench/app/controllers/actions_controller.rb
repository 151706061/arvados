class ActionsController < ApplicationController

  @@exposed_actions = {}
  def self.expose_action method, &block
    @@exposed_actions[method] = true
    define_method method, block
  end

  def model_class
    ArvadosBase::resource_class_for_uuid(params[:uuid])
  end

  def show
    @object = model_class.find(params[:uuid])
    if @object.is_a? Link and
        @object.link_class == 'name' and
        ArvadosBase::resource_class_for_uuid(@object.head_uuid) == Collection
      redirect_to collection_path(id: @object.uuid)
    else
      redirect_to @object
    end
  end

  def post
    params.keys.collect(&:to_sym).each do |param|
      if @@exposed_actions[param]
        return self.send(param)
      end
    end
    redirect_to :back
  end

  expose_action :copy_selections_into_project do
    move_or_copy :copy
  end

  expose_action :move_selections_into_project do
    move_or_copy :move
  end

  def move_or_copy action
    uuids_to_add = params["selection"]
    uuids_to_add.
      collect { |x| ArvadosBase::resource_class_for_uuid(x) }.
      uniq.
      each do |resource_class|
      resource_class.filter([['uuid','in',uuids_to_add]]).each do |src|
        if resource_class == Collection
          dst = Link.new(owner_uuid: @object.uuid,
                         tail_uuid: @object.uuid,
                         head_uuid: src.uuid,
                         link_class: 'name',
                         name: src.uuid)
        else
          case action
          when :copy
            dst = src.dup
            if dst.respond_to? :'name='
              if dst.name
                dst.name = "Copy of #{dst.name}"
              else
                dst.name = "Copy of unnamed #{dst.class_for_display.downcase}"
              end
            end
          when :move
            dst = src
          else
            raise ArgumentError.new "Unsupported action #{action}"
          end
          dst.owner_uuid = @object.uuid
          dst.tail_uuid = @object.uuid if dst.class == Link
        end
        dst.save!
      end
    end
    redirect_to @object
  end

  def arv_normalize mt, *opts
    r = ""
    IO.popen(['arv-normalize'] + opts, 'w+b') do |io|
      io.write mt
      io.close_write
      while buf = io.read(2**16)
        r += buf
      end
    end
    r
  end

  expose_action :combine_selected_files_into_collection do
    lst = []
    files = []
    params["selection"].each do |s|
      a = ArvadosBase::resource_class_for_uuid s
      m = nil
      if a == Link
        begin
          m = CollectionsHelper.match(Link.find(s).head_uuid)
        rescue
        end
      else
        m = CollectionsHelper.match(s)
      end

      if m and m[1] and m[2]
        lst.append(m[1] + m[2])
        files.append(m)
      end
    end

    collections = Collection.where(uuid: lst)

    chash = {}
    collections.each do |c|
      c.reload()
      chash[c.uuid] = c
    end

    combined = ""
    files.each do |m|
      mt = chash[m[1]+m[2]].manifest_text
      if m[4]
        combined += arv_normalize mt, '--extract', m[4][1..-1]
      else
        combined += chash[m[1]+m[2]].manifest_text
      end
    end

    normalized = arv_normalize combined
    normalized_stripped = arv_normalize combined, '--strip'

    require 'digest/md5'

    d = Digest::MD5.new()
    d << normalized_stripped
    newuuid = "#{d.hexdigest}+#{normalized_stripped.length}"

    env = Hash[ENV].
      merge({
              'ARVADOS_API_HOST' =>
              arvados_api_client.arvados_v1_base.
              sub(/\/arvados\/v1/, '').
              sub(/^https?:\/\//, ''),
              'ARVADOS_API_TOKEN' => Thread.current[:arvados_api_token],
              'ARVADOS_API_HOST_INSECURE' =>
              Rails.configuration.arvados_insecure_https ? 'true' : 'false'
            })

    IO.popen([env, 'arv-put', '--raw'], 'w+b') do |io|
      io.write normalized_stripped
      io.close_write
      while buf = io.read(2**16)
      end
    end

    newc = Collection.new({:uuid => newuuid, :manifest_text => normalized})
    newc.save!

    chash.each do |k,v|
      l = Link.new({
                     tail_uuid: k,
                     head_uuid: newuuid,
                     link_class: "provenance",
                     name: "provided"
                   })
      l.save!
    end

    redirect_to controller: 'collections', action: :show, id: newc.uuid
  end

end
