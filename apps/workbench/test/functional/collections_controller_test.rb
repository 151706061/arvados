require 'test_helper'

class CollectionsControllerTest < ActionController::TestCase
  def collection_params(collection_name, file_name=nil)
    uuid = api_fixture('collections')[collection_name.to_s]['uuid']
    params = {uuid: uuid, id: uuid}
    params[:file] = file_name if file_name
    params
  end

  def expected_contents(params, token)
    unless token.is_a? String
      token = params[:api_token] || token[:arvados_api_token]
    end
    [token, params[:uuid], params[:file]].join('/')
  end

  def assert_hash_includes(actual_hash, expected_hash, msg=nil)
    expected_hash.each do |key, value|
      assert_equal(value, actual_hash[key], msg)
    end
  end

  def assert_no_session
    assert_hash_includes(session, {arvados_api_token: nil},
                         "session includes unexpected API token")
  end

  def assert_session_for_auth(client_auth)
    api_token =
      api_fixture('api_client_authorizations')[client_auth.to_s]['api_token']
    assert_hash_includes(session, {arvados_api_token: api_token},
                         "session token does not belong to #{client_auth}")
  end

  def show_collection(params, session={}, response=:success)
    params = collection_params(params) if not params.is_a? Hash
    session = session_for(session) if not session.is_a? Hash
    get(:show, params, session)
    assert_response response
  end

  # Mock the collection file reader to avoid external calls and return
  # a predictable string.
  CollectionsController.class_eval do
    def file_enumerator(opts)
      [[opts[:arvados_api_token], opts[:uuid], opts[:file]].join('/')]
    end
  end

  test "viewing a collection" do
    show_collection(:foo_file, :active)
    assert_equal([['.', 'foo', 3]], assigns(:object).files)
  end

  test "viewing a collection fetches related folders" do
    show_collection(:foo_file, :active)
    assert_includes(assigns(:folders).map(&:uuid),
                    api_fixture('groups')['afolder']['uuid'],
                    "controller did not find linked folder")
  end

  test "viewing a collection fetches related permissions" do
    show_collection(:bar_file, :active)
    assert_includes(assigns(:permissions).map(&:uuid),
                    api_fixture('links')['bar_file_readable_by_active']['uuid'],
                    "controller did not find permission link")
  end

  test "viewing a collection fetches jobs that output it" do
    show_collection(:bar_file, :active)
    assert_includes(assigns(:output_of).map(&:uuid),
                    api_fixture('jobs')['foobar']['uuid'],
                    "controller did not find output job")
  end

  test "viewing a collection fetches jobs that logged it" do
    show_collection(:baz_file, :active)
    assert_includes(assigns(:log_of).map(&:uuid),
                    api_fixture('jobs')['foobar']['uuid'],
                    "controller did not find logger job")
  end

  test "viewing a collection fetches logs about it" do
    show_collection(:foo_file, :active)
    assert_includes(assigns(:logs).map(&:uuid),
                    api_fixture('logs')['log4']['uuid'],
                    "controller did not find related log")
  end

  test "viewing collection files with a reader token" do
    params = collection_params(:foo_file)
    params[:reader_token] =
      api_fixture('api_client_authorizations')['active']['api_token']
    get(:show_file_links, params)
    assert_response :success
    assert_equal([['.', 'foo', 3]], assigns(:object).files)
    assert_no_session
  end

  test "getting a file from Keep" do
    params = collection_params(:foo_file, 'foo')
    sess = session_for(:active)
    get(:show_file, params, sess)
    assert_response :success
    assert_equal(expected_contents(params, sess), @response.body,
                 "failed to get a correct file from Keep")
  end

  test "can't get a file from Keep without permission" do
    params = collection_params(:foo_file, 'foo')
    sess = session_for(:spectator)
    get(:show_file, params, sess)
    assert_response 404
  end

  test "trying to get a nonexistent file from Keep returns a 404" do
    params = collection_params(:foo_file, 'gone')
    sess = session_for(:admin)
    get(:show_file, params, sess)
    assert_response 404
  end

  test "getting a file from Keep with a good reader token" do
    params = collection_params(:foo_file, 'foo')
    read_token = api_fixture('api_client_authorizations')['active']['api_token']
    params[:reader_token] = read_token
    get(:show_file, params)
    assert_response :success
    assert_equal(expected_contents(params, read_token), @response.body,
                 "failed to get a correct file from Keep using a reader token")
    assert_not_equal(read_token, session[:arvados_api_token],
                     "using a reader token set the session's API token")
  end

  test "trying to get from Keep with an unscoped reader token prompts login" do
    params = collection_params(:foo_file, 'foo')
    params[:reader_token] =
      api_fixture('api_client_authorizations')['active_noscope']['api_token']
    get(:show_file, params)
    assert_response :redirect
  end

  test "can get a file with an unpermissioned auth but in-scope reader token" do
    params = collection_params(:foo_file, 'foo')
    sess = session_for(:expired)
    read_token = api_fixture('api_client_authorizations')['active']['api_token']
    params[:reader_token] = read_token
    get(:show_file, params, sess)
    assert_response :success
    assert_equal(expected_contents(params, read_token), @response.body,
                 "failed to get a correct file from Keep using a reader token")
    assert_not_equal(read_token, session[:arvados_api_token],
                     "using a reader token set the session's API token")
  end
end
