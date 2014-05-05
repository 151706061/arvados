class Arvados::V1::RepositoriesController < ApplicationController
  skip_before_filter :find_object_by_uuid, :only => :get_all_permissions
  skip_before_filter :render_404_if_no_object, :only => :get_all_permissions
  before_filter :admin_required, :only => :get_all_permissions
  def get_all_permissions
    @users = {}
    User.includes(:authorized_keys).all.each do |u|
      @users[u.uuid] = u
    end
    @user_aks = {}
    @repo_info = {}
    @repos = Repository.includes(:permissions).all
    @repos.each do |repo|
      gitolite_permissions = ''
      perms = []
      repo.permissions.each do |perm|
        if ArvadosModel::resource_class_for_uuid(perm.tail_uuid) == Group
          @users.each do |user_uuid, user|
            user.group_permissions.each do |group_uuid, perm_mask|
              if perm_mask[:write]
                perms << {name: 'can_write', user_uuid: user_uuid}
              elsif perm_mask[:read]
                perms << {name: 'can_read', user_uuid: user_uuid}
              end
            end
          end
        else
          perms << {name: perm.name, user_uuid: perm.tail_uuid}
        end
      end
      # Owner of the repository, and all admins, can RW
      ([repo.owner_uuid] + @users.keys).each do |user_uuid|
        %w(can_read can_write).each do |name|
          perms << {name: name, user_uuid: user_uuid}
        end
      end
      perms.each do |perm|
        user_uuid = perm[:user_uuid]
        @user_aks[user_uuid] = @users[user_uuid].andand.authorized_keys.andand.
          collect do |ak|
          {
            public_key: ak.public_key,
            authorized_key_uuid: ak.uuid
          }
        end || []
        if @user_aks[user_uuid].any?
          @repo_info[repo.uuid] ||= {
            uuid: repo.uuid,
            name: repo.name,
            push_url: repo.push_url,
            fetch_url: repo.fetch_url,
            user_permissions: {}
          }
          ri = (@repo_info[repo.uuid][:user_permissions][user_uuid] ||= {})
          ri[perm[:name]] = true
        end
      end
    end
    @repo_info.values.each do |repo_users|
      repo_users[:user_permissions].each do |user_uuid,perms|
        if perms['can_write']
          perms[:gitolite_permissions] = 'RW'
          perms['can_read'] = true
        elsif perms['can_read']
          perms[:gitolite_permissions] = 'R'
        end
      end
    end
    render json: {
      kind: 'arvados#RepositoryPermissionSnapshot',
      repositories: @repo_info.values,
      user_keys: @user_aks
    }
  end
end
