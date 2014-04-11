require 'test_helper'

class Arvados::V1::UsersControllerTest < ActionController::TestCase
  include CurrentApiClient

  setup do
    @all_links_at_start = Link.all
    @vm_uuid = virtual_machines(:testvm).uuid
  end

  test "activate a user after signing UA" do
    authorize_with :inactive_but_signed_user_agreement
    get :current
    assert_response :success
    me = JSON.parse(@response.body)
    post :activate, uuid: me['uuid']
    assert_response :success
    assert_not_nil assigns(:object)
    me = JSON.parse(@response.body)
    assert_equal true, me['is_active']
  end

  test "refuse to activate a user before signing UA" do
    authorize_with :inactive
    get :current
    assert_response :success
    me = JSON.parse(@response.body)
    post :activate, uuid: me['uuid']
    assert_response 403
    get :current
    assert_response :success
    me = JSON.parse(@response.body)
    assert_equal false, me['is_active']
  end

  test "activate an already-active user" do
    authorize_with :active
    get :current
    assert_response :success
    me = JSON.parse(@response.body)
    post :activate, uuid: me['uuid']
    assert_response :success
    me = JSON.parse(@response.body)
    assert_equal true, me['is_active']
  end

  test "create new user with user as input" do
    authorize_with :admin
    post :create, user: {
      first_name: "test_first_name",
      last_name: "test_last_name",
      email: "foo@example.com"
    }
    assert_response :success
    created = JSON.parse(@response.body)
    assert_equal 'test_first_name', created['first_name']
    assert_not_nil created['uuid'], 'expected uuid for the newly created user'
    assert_not_nil created['email'], 'expected non-nil email'
    assert_nil created['identity_url'], 'expected no identity_url'
  end

  test "create user with user, vm and repo as input" do
    authorize_with :admin
    repo_name = 'test_repo'

    post :setup, {
      repo_name: repo_name,
      openid_prefix: 'https://www.google.com/accounts/o8/id',
      user: {
        uuid: 'zzzzz-tpzed-abcdefghijklmno',
        first_name: "in_create_test_first_name",
        last_name: "test_last_name",
        email: "foo@example.com"
      }
    }
    assert_response :success
    response_items = JSON.parse(@response.body)['items']

    created = find_obj_in_resp response_items, 'User', nil

    assert_equal 'in_create_test_first_name', created['first_name']
    assert_not_nil created['uuid'], 'expected non-null uuid for the new user'
    assert_equal 'zzzzz-tpzed-abcdefghijklmno', created['uuid']
    assert_not_nil created['email'], 'expected non-nil email'
    assert_nil created['identity_url'], 'expected no identity_url'

    # arvados#user, repo link and link add user to 'All users' group
    verify_num_links @all_links_at_start, 4

    verify_link response_items, 'arvados#user', true, 'permission', 'can_login',
        created['uuid'], created['email'], 'arvados#user', false, 'User'

    verify_link response_items, 'arvados#repository', true, 'permission', 'can_write',
        repo_name, created['uuid'], 'arvados#repository', true, 'Repository'

    verify_link response_items, 'arvados#group', true, 'permission', 'can_read',
        'All users', created['uuid'], 'arvados#group', true, 'Group'

    verify_link response_items, 'arvados#virtualMachine', false, 'permission', 'can_login',
        nil, created['uuid'], 'arvados#virtualMachine', false, 'VirtualMachine'

    verify_system_group_permission_link_for created['uuid']

    # invoke setup again with the same data
    post :setup, {
      repo_name: repo_name,
      vm_uuid: @vm_uuid,
      openid_prefix: 'https://www.google.com/accounts/o8/id',
      user: {
        uuid: 'zzzzz-tpzed-abcdefghijklmno',
        first_name: "in_create_test_first_name",
        last_name: "test_last_name",
        email: "foo@example.com"
      }
    }

    response_items = JSON.parse(@response.body)['items']

    created = find_obj_in_resp response_items, 'User', nil
    assert_equal 'in_create_test_first_name', created['first_name']
    assert_not_nil created['uuid'], 'expected non-null uuid for the new user'
    assert_equal 'zzzzz-tpzed-abcdefghijklmno', created['uuid']
    assert_not_nil created['email'], 'expected non-nil email'
    assert_nil created['identity_url'], 'expected no identity_url'

    # arvados#user, repo link and link add user to 'All users' group
    verify_num_links @all_links_at_start, 5

    verify_link response_items, 'arvados#repository', true, 'permission', 'can_write',
        repo_name, created['uuid'], 'arvados#repository', true, 'Repository'

    verify_link response_items, 'arvados#group', true, 'permission', 'can_read',
        'All users', created['uuid'], 'arvados#group', true, 'Group'

    verify_link response_items, 'arvados#virtualMachine', true, 'permission', 'can_login',
        @vm_uuid, created['uuid'], 'arvados#virtualMachine', false, 'VirtualMachine'

    verify_system_group_permission_link_for created['uuid']
  end

  test "setup user with bogus uuid and expect error" do
    authorize_with :admin

    post :setup, {
      uuid: 'bogus_uuid',
      repo_name: 'test_repo',
      vm_uuid: @vm_uuid
    }
    response_body = JSON.parse(@response.body)
    response_errors = response_body['errors']
    assert_not_nil response_errors, 'Expected error in response'
    assert (response_errors.first.include? 'Path not found'), 'Expected 404'
  end

  test "setup user with bogus uuid in user and expect error" do
    authorize_with :admin

    post :setup, {
      user: {uuid: 'bogus_uuid'},
      repo_name: 'test_repo',
      vm_uuid: @vm_uuid,
      openid_prefix: 'https://www.google.com/accounts/o8/id'
    }
    response_body = JSON.parse(@response.body)
    response_errors = response_body['errors']
    assert_not_nil response_errors, 'Expected error in response'
    assert (response_errors.first.include? 'ArgumentError: Require user email'),
      'Expected RuntimeError'
  end

  test "setup user with no uuid and user, expect error" do
    authorize_with :admin

    post :setup, {
      repo_name: 'test_repo',
      vm_uuid: @vm_uuid,
      openid_prefix: 'https://www.google.com/accounts/o8/id'
    }
    response_body = JSON.parse(@response.body)
    response_errors = response_body['errors']
    assert_not_nil response_errors, 'Expected error in response'
    assert (response_errors.first.include? 'Required uuid or user'),
        'Expected ArgumentError'
  end

  test "setup user with no uuid and email, expect error" do
    authorize_with :admin

    post :setup, {
      user: {},
      repo_name: 'test_repo',
      vm_uuid: @vm_uuid,
      openid_prefix: 'https://www.google.com/accounts/o8/id'
    }
    response_body = JSON.parse(@response.body)
    response_errors = response_body['errors']
    assert_not_nil response_errors, 'Expected error in response'
    assert (response_errors.first.include? '<ArgumentError: Require user email'),
        'Expected ArgumentError'
  end

  test "invoke setup with existing uuid, vm and repo and verify links" do
    authorize_with :inactive
    get :current
    assert_response :success
    inactive_user = JSON.parse(@response.body)

    authorize_with :admin

    post :setup, {
      uuid: inactive_user['uuid'],
      repo_name: 'test_repo',
      vm_uuid: @vm_uuid
    }

    assert_response :success

    response_items = JSON.parse(@response.body)['items']
    resp_obj = find_obj_in_resp response_items, 'User', nil

    assert_not_nil resp_obj['uuid'], 'expected uuid for the new user'
    assert_equal inactive_user['uuid'], resp_obj['uuid']
    assert_equal inactive_user['email'], resp_obj['email'],
        'expecting inactive user email'

    # expect repo and vm links
    verify_link response_items, 'arvados#repository', true, 'permission', 'can_write',
        'test_repo', resp_obj['uuid'], 'arvados#repository', true, 'Repository'

    verify_link response_items, 'arvados#virtualMachine', true, 'permission', 'can_login',
        @vm_uuid, resp_obj['uuid'], 'arvados#virtualMachine', false, 'VirtualMachine'
  end

  test "invoke setup with existing uuid in user, verify response" do
    authorize_with :inactive
    get :current
    assert_response :success
    inactive_user = JSON.parse(@response.body)

    authorize_with :admin

    post :setup, {
      user: {uuid: inactive_user['uuid']},
      openid_prefix: 'https://www.google.com/accounts/o8/id'
    }

    assert_response :success

    response_items = JSON.parse(@response.body)['items']
    resp_obj = find_obj_in_resp response_items, 'User', nil

    assert_not_nil resp_obj['uuid'], 'expected uuid for the new user'
    assert_equal inactive_user['uuid'], resp_obj['uuid']
    assert_equal inactive_user['email'], resp_obj['email'],
        'expecting inactive user email'
  end

  test "invoke setup with existing uuid but different email, expect original email" do
    authorize_with :inactive
    get :current
    assert_response :success
    inactive_user = JSON.parse(@response.body)

    authorize_with :admin

    post :setup, {
      uuid: inactive_user['uuid'],
      user: {email: 'junk_email'}
    }

    assert_response :success

    response_items = JSON.parse(@response.body)['items']
    resp_obj = find_obj_in_resp response_items, 'User', nil

    assert_not_nil resp_obj['uuid'], 'expected uuid for the new user'
    assert_equal inactive_user['uuid'], resp_obj['uuid']
    assert_equal inactive_user['email'], resp_obj['email'],
        'expecting inactive user email'
  end

  test "setup user with valid email and repo as input" do
    authorize_with :admin

    post :setup, {
      repo_name: 'test_repo',
      user: {email: 'foo@example.com'},
      openid_prefix: 'https://www.google.com/accounts/o8/id'
    }

    assert_response :success
    response_items = JSON.parse(@response.body)['items']
    response_object = find_obj_in_resp response_items, 'User', nil
    assert_not_nil response_object['uuid'], 'expected uuid for the new user'
    assert_equal response_object['email'], 'foo@example.com', 'expected given email'

    # four extra links; system_group, login, group and repo perms
    verify_num_links @all_links_at_start, 4
  end

  test "setup user with fake vm and expect error" do
    authorize_with :admin

    post :setup, {
      repo_name: 'test_repo',
      vm_uuid: 'no_such_vm',
      user: {email: 'foo@example.com'},
      openid_prefix: 'https://www.google.com/accounts/o8/id'
    }

    response_body = JSON.parse(@response.body)
    response_errors = response_body['errors']
    assert_not_nil response_errors, 'Expected error in response'
    assert (response_errors.first.include? "No vm found for no_such_vm"),
          'Expected RuntimeError: No vm found for no_such_vm'
  end

  test "setup user with valid email, repo and real vm as input" do
    authorize_with :admin

    post :setup, {
      repo_name: 'test_repo',
      openid_prefix: 'https://www.google.com/accounts/o8/id',
      vm_uuid: @vm_uuid,
      user: {email: 'foo@example.com'}
    }

    assert_response :success
    response_items = JSON.parse(@response.body)['items']
    response_object = find_obj_in_resp response_items, 'User', nil
    assert_not_nil response_object['uuid'], 'expected uuid for the new user'
    assert_equal response_object['email'], 'foo@example.com', 'expected given email'

    # five extra links; system_group, login, group, vm, repo
    verify_num_links @all_links_at_start, 5
  end

  test "setup user with valid email, no vm and repo as input" do
    authorize_with :admin

    post :setup, {
      user: {email: 'foo@example.com'},
      openid_prefix: 'https://www.google.com/accounts/o8/id'
    }

    assert_response :success
    response_items = JSON.parse(@response.body)['items']
    response_object = find_obj_in_resp response_items, 'User', nil
    assert_not_nil response_object['uuid'], 'expected uuid for new user'
    assert_equal response_object['email'], 'foo@example.com', 'expected given email'

    # three extra links; system_group, login, and group
    verify_num_links @all_links_at_start, 3
  end

  test "setup user with email, first name, repo name and vm uuid" do
    authorize_with :admin

    post :setup, {
      openid_prefix: 'https://www.google.com/accounts/o8/id',
      repo_name: 'test_repo',
      vm_uuid: @vm_uuid,
      user: {
        first_name: 'test_first_name',
        email: 'foo@example.com'
      }
    }

    assert_response :success
    response_items = JSON.parse(@response.body)['items']
    response_object = find_obj_in_resp response_items, 'User', nil
    assert_not_nil response_object['uuid'], 'expected uuid for new user'
    assert_equal response_object['email'], 'foo@example.com', 'expected given email'
    assert_equal 'test_first_name', response_object['first_name'],
        'expecting first name'

    # five extra links; system_group, login, group, repo and vm
    verify_num_links @all_links_at_start, 5
  end

  test "setup user twice with email and check two different objects created" do
    authorize_with :admin

    post :setup, {
      openid_prefix: 'https://www.google.com/accounts/o8/id',
      repo_name: 'test_repo',
      user: {
        email: 'foo@example.com'
      }
    }

    assert_response :success
    response_items = JSON.parse(@response.body)['items']
    response_object = find_obj_in_resp response_items, 'User', nil
    assert_not_nil response_object['uuid'], 'expected uuid for new user'
    assert_equal response_object['email'], 'foo@example.com', 'expected given email'
    # system_group, openid, group, and repo. No vm link.
    verify_num_links @all_links_at_start, 4

    # create again
    post :setup, {
      user: {email: 'foo@example.com'},
      openid_prefix: 'https://www.google.com/accounts/o8/id'
    }

    assert_response :success
    response_items = JSON.parse(@response.body)['items']
    response_object2 = find_obj_in_resp response_items, 'User', nil
    assert_not_equal response_object['uuid'], response_object2['uuid'],
        'expected same uuid as first create operation'
    assert_equal response_object['email'], 'foo@example.com', 'expected given email'

    # +1 extra login link +1 extra system_group link pointing to the new User
    verify_num_links @all_links_at_start, 6
  end

  test "setup user with openid prefix" do
    authorize_with :admin

    post :setup, {
      repo_name: 'test_repo',
      openid_prefix: 'http://www.example.com/account',
      user: {
        first_name: "in_create_test_first_name",
        last_name: "test_last_name",
        email: "foo@example.com"
      }
    }

    assert_response :success

    response_items = JSON.parse(@response.body)['items']
    created = find_obj_in_resp response_items, 'User', nil

    assert_equal 'in_create_test_first_name', created['first_name']
    assert_not_nil created['uuid'], 'expected uuid for new user'
    assert_not_nil created['email'], 'expected non-nil email'
    assert_nil created['identity_url'], 'expected no identity_url'

    # verify links
    # four new links: system_group, arvados#user, repo, and 'All users' group.
    verify_num_links @all_links_at_start, 4

    verify_link response_items, 'arvados#user', true, 'permission', 'can_login',
        created['uuid'], created['email'], 'arvados#user', false, 'User'

    verify_link response_items, 'arvados#repository', true, 'permission', 'can_write',
        'test_repo', created['uuid'], 'arvados#repository', true, 'Repository'

    verify_link response_items, 'arvados#group', true, 'permission', 'can_read',
        'All users', created['uuid'], 'arvados#group', true, 'Group'

    verify_link response_items, 'arvados#virtualMachine', false, 'permission', 'can_login',
        nil, created['uuid'], 'arvados#virtualMachine', false, 'VirtualMachine'
  end

  test "invoke setup with no openid prefix, expect error" do
    authorize_with :admin

    post :setup, {
      repo_name: 'test_repo',
      user: {
        first_name: "in_create_test_first_name",
        last_name: "test_last_name",
        email: "foo@example.com"
      }
    }

    response_body = JSON.parse(@response.body)
    response_errors = response_body['errors']
    assert_not_nil response_errors, 'Expected error in response'
    assert (response_errors.first.include? 'openid_prefix parameter is missing'),
        'Expected ArgumentError'
  end

  test "setup user with user, vm and repo and verify links" do
    authorize_with :admin

    post :setup, {
      user: {
        first_name: "in_create_test_first_name",
        last_name: "test_last_name",
        email: "foo@example.com"
      },
      vm_uuid: @vm_uuid,
      repo_name: 'test_repo',
      openid_prefix: 'https://www.google.com/accounts/o8/id'
    }

    assert_response :success

    response_items = JSON.parse(@response.body)['items']
    created = find_obj_in_resp response_items, 'User', nil

    assert_equal 'in_create_test_first_name', created['first_name']
    assert_not_nil created['uuid'], 'expected uuid for new user'
    assert_not_nil created['email'], 'expected non-nil email'
    assert_nil created['identity_url'], 'expected no identity_url'

    # five new links: system_group, arvados#user, repo, vm and 'All
    # users' group link
    verify_num_links @all_links_at_start, 5

    verify_link response_items, 'arvados#user', true, 'permission', 'can_login',
        created['uuid'], created['email'], 'arvados#user', false, 'User'

    verify_link response_items, 'arvados#repository', true, 'permission', 'can_write',
        'test_repo', created['uuid'], 'arvados#repository', true, 'Repository'

    verify_link response_items, 'arvados#group', true, 'permission', 'can_read',
        'All users', created['uuid'], 'arvados#group', true, 'Group'

    verify_link response_items, 'arvados#virtualMachine', true, 'permission', 'can_login',
        @vm_uuid, created['uuid'], 'arvados#virtualMachine', false, 'VirtualMachine'
  end

  test "create user as non admin user and expect error" do
    authorize_with :active

    post :create, {
      user: {email: 'foo@example.com'}
    }

    response_body = JSON.parse(@response.body)
    response_errors = response_body['errors']
    assert_not_nil response_errors, 'Expected error in response'
    assert (response_errors.first.include? 'PermissionDenied'),
          'Expected PermissionDeniedError'
  end

  test "setup user as non admin user and expect error" do
    authorize_with :active

    post :setup, {
      openid_prefix: 'https://www.google.com/accounts/o8/id',
      user: {email: 'foo@example.com'}
    }

    response_body = JSON.parse(@response.body)
    response_errors = response_body['errors']
    assert_not_nil response_errors, 'Expected error in response'
    assert (response_errors.first.include? 'Forbidden'),
          'Expected Forbidden error'
  end

  test "setup user in multiple steps and verify response" do
    authorize_with :admin

    post :setup, {
      openid_prefix: 'http://www.example.com/account',
      user: {
        email: "foo@example.com"
      }
    }

    assert_response :success
    response_items = JSON.parse(@response.body)['items']
    created = find_obj_in_resp response_items, 'User', nil

    assert_not_nil created['uuid'], 'expected uuid for new user'
    assert_not_nil created['email'], 'expected non-nil email'
    assert_equal created['email'], 'foo@example.com', 'expected input email'

    # three new links: system_group, arvados#user, and 'All users' group.
    verify_num_links @all_links_at_start, 3

    verify_link response_items, 'arvados#user', true, 'permission', 'can_login',
        created['uuid'], created['email'], 'arvados#user', false, 'User'

    verify_link response_items, 'arvados#group', true, 'permission', 'can_read',
        'All users', created['uuid'], 'arvados#group', true, 'Group'

    verify_link response_items, 'arvados#repository', false, 'permission', 'can_write',
        'test_repo', created['uuid'], 'arvados#repository', true, 'Repository'

    verify_link response_items, 'arvados#virtualMachine', false, 'permission', 'can_login',
        nil, created['uuid'], 'arvados#virtualMachine', false, 'VirtualMachine'

   # invoke setup with a repository
    post :setup, {
      openid_prefix: 'http://www.example.com/account',
      repo_name: 'new_repo',
      uuid: created['uuid']
    }

    assert_response :success

    response_items = JSON.parse(@response.body)['items']
    created = find_obj_in_resp response_items, 'User', nil

    assert_equal 'foo@example.com', created['email'], 'expected input email'

     # verify links
    verify_link response_items, 'arvados#group', true, 'permission', 'can_read',
        'All users', created['uuid'], 'arvados#group', true, 'Group'

    verify_link response_items, 'arvados#repository', true, 'permission', 'can_write',
        'new_repo', created['uuid'], 'arvados#repository', true, 'Repository'

    verify_link response_items, 'arvados#virtualMachine', false, 'permission', 'can_login',
        nil, created['uuid'], 'arvados#virtualMachine', false, 'VirtualMachine'

    # invoke setup with a vm_uuid
    post :setup, {
      vm_uuid: @vm_uuid,
      openid_prefix: 'http://www.example.com/account',
      user: {
        email: 'junk_email'
      },
      uuid: created['uuid']
    }

    assert_response :success

    response_items = JSON.parse(@response.body)['items']
    created = find_obj_in_resp response_items, 'User', nil

    assert_equal created['email'], 'foo@example.com', 'expected original email'

    # verify links
    verify_link response_items, 'arvados#group', true, 'permission', 'can_read',
        'All users', created['uuid'], 'arvados#group', true, 'Group'

    # since no repo name in input, we won't get any; even though user has one
    verify_link response_items, 'arvados#repository', false, 'permission', 'can_write',
        'new_repo', created['uuid'], 'arvados#repository', true, 'Repository'

    verify_link response_items, 'arvados#virtualMachine', true, 'permission', 'can_login',
        @vm_uuid, created['uuid'], 'arvados#virtualMachine', false, 'VirtualMachine'
  end

  test "setup and unsetup user" do
    authorize_with :admin

    post :setup, {
      repo_name: 'test_repo',
      vm_uuid: @vm_uuid,
      user: {email: 'foo@example.com'},
      openid_prefix: 'https://www.google.com/accounts/o8/id'
    }

    assert_response :success
    response_items = JSON.parse(@response.body)['items']
    created = find_obj_in_resp response_items, 'User', nil
    assert_not_nil created['uuid'], 'expected uuid for the new user'
    assert_equal created['email'], 'foo@example.com', 'expected given email'

    # five extra links: system_group, login, group, repo and vm
    verify_num_links @all_links_at_start, 5

    verify_link response_items, 'arvados#user', true, 'permission', 'can_login',
        created['uuid'], created['email'], 'arvados#user', false, 'User'

    verify_link response_items, 'arvados#group', true, 'permission', 'can_read',
        'All users', created['uuid'], 'arvados#group', true, 'Group'

    verify_link response_items, 'arvados#repository', true, 'permission', 'can_write',
        'test_repo', created['uuid'], 'arvados#repository', true, 'Repository'

    verify_link response_items, 'arvados#virtualMachine', true, 'permission', 'can_login',
        @vm_uuid, created['uuid'], 'arvados#virtualMachine', false, 'VirtualMachine'

    verify_link_existence created['uuid'], created['email'], true, true, true, true, false

    # now unsetup this user
    post :unsetup, uuid: created['uuid']
    assert_response :success

    created2 = JSON.parse(@response.body)
    assert_not_nil created2['uuid'], 'expected uuid for the newly created user'
    assert_equal created['uuid'], created2['uuid'], 'expected uuid not found'

    verify_link_existence created['uuid'], created['email'], false, false, false, false, false
  end

  test "unsetup active user" do
    authorize_with :active
    get :current
    assert_response :success
    active_user = JSON.parse(@response.body)
    assert_not_nil active_user['uuid'], 'expected uuid for the active user'
    assert active_user['is_active'], 'expected is_active for active user'
    assert active_user['is_invited'], 'expected is_invited for active user'

    verify_link_existence active_user['uuid'], active_user['email'],
          false, false, false, true, true

    authorize_with :admin

    # now unsetup this user
    post :unsetup, uuid: active_user['uuid']
    assert_response :success

    response_user = JSON.parse(@response.body)
    assert_not_nil response_user['uuid'], 'expected uuid for the upsetup user'
    assert_equal active_user['uuid'], response_user['uuid'], 'expected uuid not found'
    assert !response_user['is_active'], 'expected user to be inactive'
    assert !response_user['is_invited'], 'expected user to be uninvited'

    verify_link_existence response_user['uuid'], response_user['email'],
          false, false, false, false, false
  end

  def verify_num_links (original_links, expected_additional_links)
    links_now = Link.all
    assert_equal expected_additional_links, Link.all.size-original_links.size,
        "Expected #{expected_additional_links.inspect} more links"
  end

  def find_obj_in_resp (response_items, object_type, head_kind=nil)
    return_obj = nil
    response_items.each { |x|
      if !x
        next
      end

      if object_type == 'User'
        if ArvadosModel::resource_class_for_uuid(x['uuid']) == User
          return_obj = x
          break
        end
      else  # looking for a link
        if x['head_uuid'] and ArvadosModel::resource_class_for_uuid(x['head_uuid']).kind == head_kind
          return_obj = x
          break
        end
      end
    }
    return return_obj
  end

  def verify_link(response_items, link_object_name, expect_link, link_class,
        link_name, head_uuid, tail_uuid, head_kind, fetch_object, class_name)

    link = find_obj_in_resp response_items, 'Link', link_object_name

    if !expect_link
      assert_nil link, "Expected no link for #{link_object_name}"
      return
    end

    assert_not_nil link, "Expected link for #{link_object_name}"

    if fetch_object
      object = Object.const_get(class_name).where(name: head_uuid)
      assert [] != object, "expected #{class_name} with name #{head_uuid}"
      head_uuid = object.first[:uuid]
    end
    assert_equal link_class, link['link_class'],
        "did not find expected link_class for #{link_object_name}"

    assert_equal link_name, link['name'],
        "did not find expected link_name for #{link_object_name}"

    assert_equal tail_uuid, link['tail_uuid'],
        "did not find expected tail_uuid for #{link_object_name}"

    assert_equal head_kind, link['head_kind'],
        "did not find expected head_kind for #{link_object_name}"

    assert_equal head_uuid, link['head_uuid'],
        "did not find expected head_uuid for #{link_object_name}"
  end

  def verify_link_existence uuid, email, expect_oid_login_perms,
      expect_repo_perms, expect_vm_perms, expect_group_perms, expect_signatures
    # verify that all links are deleted for the user
    oid_login_perms = Link.where(tail_uuid: email,
                                 link_class: 'permission',
                                 name: 'can_login').where("head_uuid like ?", User.uuid_like_pattern)
    if expect_oid_login_perms
      assert oid_login_perms.any?, "expected oid_login_perms"
    else
      assert !oid_login_perms.any?, "expected all oid_login_perms deleted"
    end

    repo_perms = Link.where(tail_uuid: uuid,
                              link_class: 'permission',
                              name: 'can_write').where("head_uuid like ?", Repository.uuid_like_pattern)
    if expect_repo_perms
      assert repo_perms.any?, "expected repo_perms"
    else
      assert !repo_perms.any?, "expected all repo_perms deleted"
    end

    vm_login_perms = Link.where(tail_uuid: uuid,
                              link_class: 'permission',
                              name: 'can_login').where("head_uuid like ?", VirtualMachine.uuid_like_pattern)
    if expect_vm_perms
      assert vm_login_perms.any?, "expected vm_login_perms"
    else
      assert !vm_login_perms.any?, "expected all vm_login_perms deleted"
    end

    group = Group.where(name: 'All users').select do |g|
      g[:uuid].match /-f+$/
    end.first
    group_read_perms = Link.where(tail_uuid: uuid,
                             head_uuid: group[:uuid],
                             link_class: 'permission',
                             name: 'can_read')
    if expect_group_perms
      assert group_read_perms.any?, "expected all users group read perms"
    else
      assert !group_read_perms.any?, "expected all users group perm deleted"
    end

    signed_uuids = Link.where(link_class: 'signature',
                                  tail_uuid: uuid)

    if expect_signatures
      assert signed_uuids.any?, "expected signatures"
    else
      assert !signed_uuids.any?, "expected all signatures deleted"
    end

  end

  def verify_system_group_permission_link_for user_uuid
    assert_equal 1, Link.where(link_class: 'permission',
                               name: 'can_manage',
                               tail_uuid: system_group_uuid,
                               head_uuid: user_uuid).count
  end
end
