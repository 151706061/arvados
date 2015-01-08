require 'test_helper'

class CollectionsApiTest < ActionDispatch::IntegrationTest
  fixtures :all

  test "should get index" do
    get "/arvados/v1/collections", {:format => :json}, auth(:active)
    assert_response :success
    assert_equal "arvados#collectionList", json_response['kind']
  end

  test "get index with filters= (empty string)" do
    get "/arvados/v1/collections", {:format => :json, :filters => ''}, auth(:active)
    assert_response :success
    assert_equal "arvados#collectionList", json_response['kind']
  end

  test "get index with invalid filters (array of strings) responds 422" do
    get "/arvados/v1/collections", {
      :format => :json,
      :filters => ['uuid', '=', 'ad02e37b6a7f45bbe2ead3c29a109b8a+54'].to_json
    }, auth(:active)
    assert_response 422
    assert_match /nvalid element.*not an array/, json_response['errors'].join(' ')
  end

  test "get index with invalid filters (unsearchable column) responds 422" do
    get "/arvados/v1/collections", {
      :format => :json,
      :filters => [['this_column_does_not_exist', '=', 'bogus']].to_json
    }, auth(:active)
    assert_response 422
    assert_match /nvalid attribute/, json_response['errors'].join(' ')
  end

  test "get index with invalid filters (invalid operator) responds 422" do
    get "/arvados/v1/collections", {
      :format => :json,
      :filters => [['uuid', ':-(', 'displeased']].to_json
    }, auth(:active)
    assert_response 422
    assert_match /nvalid operator/, json_response['errors'].join(' ')
  end

  test "get index with invalid filters (invalid operand type) responds 422" do
    get "/arvados/v1/collections", {
      :format => :json,
      :filters => [['uuid', '=', {foo: 'bar'}]].to_json
    }, auth(:active)
    assert_response 422
    assert_match /nvalid operand type/, json_response['errors'].join(' ')
  end

  test "get index with where= (empty string)" do
    get "/arvados/v1/collections", {:format => :json, :where => ''}, auth(:active)
    assert_response :success
    assert_equal "arvados#collectionList", json_response['kind']
  end

  test "controller 404 response is json" do
    get "/arvados/v1/thingsthatdonotexist", {:format => :xml}, auth(:active)
    assert_response 404
    assert_equal 1, json_response['errors'].length
    assert_equal true, json_response['errors'][0].is_a?(String)
  end

  test "object 404 response is json" do
    get "/arvados/v1/groups/zzzzz-j7d0g-o5ba971173cup4f", {}, auth(:active)
    assert_response 404
    assert_equal 1, json_response['errors'].length
    assert_equal true, json_response['errors'][0].is_a?(String)
  end

  test "store collection as json" do
    signing_opts = {
      key: Rails.configuration.blob_signing_key,
      api_token: api_token(:active),
    }
    signed_locator = Blob.sign_locator('bad42fa702ae3ea7d888fef11b46f450+44',
                                       signing_opts)
    post "/arvados/v1/collections", {
      format: :json,
      collection: "{\"manifest_text\":\". #{signed_locator} 0:44:md5sum.txt\\n\",\"portable_data_hash\":\"ad02e37b6a7f45bbe2ead3c29a109b8a+54\"}"
    }, auth(:active)
    assert_response 200
    assert_equal 'ad02e37b6a7f45bbe2ead3c29a109b8a+54', json_response['portable_data_hash']
  end

  test "store collection with manifest_text only" do
    signing_opts = {
      key: Rails.configuration.blob_signing_key,
      api_token: api_token(:active),
    }
    signed_locator = Blob.sign_locator('bad42fa702ae3ea7d888fef11b46f450+44',
                                       signing_opts)
    post "/arvados/v1/collections", {
      format: :json,
      collection: "{\"manifest_text\":\". #{signed_locator} 0:44:md5sum.txt\\n\"}"
    }, auth(:active)
    assert_response 200
    assert_equal 'ad02e37b6a7f45bbe2ead3c29a109b8a+54', json_response['portable_data_hash']
  end

  test "store collection then update name" do
    signing_opts = {
      key: Rails.configuration.blob_signing_key,
      api_token: api_token(:active),
    }
    signed_locator = Blob.sign_locator('bad42fa702ae3ea7d888fef11b46f450+44',
                                       signing_opts)
    post "/arvados/v1/collections", {
      format: :json,
      collection: "{\"manifest_text\":\". #{signed_locator} 0:44:md5sum.txt\\n\",\"portable_data_hash\":\"ad02e37b6a7f45bbe2ead3c29a109b8a+54\"}"
    }, auth(:active)
    assert_response 200
    assert_equal 'ad02e37b6a7f45bbe2ead3c29a109b8a+54', json_response['portable_data_hash']

    put "/arvados/v1/collections/#{json_response['uuid']}", {
      format: :json,
      collection: { name: "a name" }
    }, auth(:active)

    assert_response 200
    assert_equal 'ad02e37b6a7f45bbe2ead3c29a109b8a+54', json_response['portable_data_hash']
    assert_equal 'a name', json_response['name']

    get "/arvados/v1/collections/#{json_response['uuid']}", {
      format: :json,
    }, auth(:active)

    assert_response 200
    assert_equal 'ad02e37b6a7f45bbe2ead3c29a109b8a+54', json_response['portable_data_hash']
    assert_equal 'a name', json_response['name']
  end

  test "create collection, update description, and search for description" do
    signing_opts = {
      key: Rails.configuration.blob_signing_key,
      api_token: api_token(:active),
    }
    signed_locator = Blob.sign_locator('bad42fa702ae1234d999fef11b46f450+44', signing_opts)

    # create collection
    post "/arvados/v1/collections", {
      format: :json,
      collection: "{\"manifest_text\":\". #{signed_locator} 0:44:foo.txt\\n\"}"
    }, auth(:active)
    assert_response :success
    assert_equal '087e2f211aba2881c08fd8d1646522a3+51', json_response['portable_data_hash']

    # update collection's description
    put "/arvados/v1/collections/#{json_response['uuid']}", {
      format: :json,
      collection: { description: "something specific" }
    }, auth(:active)
    assert_response :success
    assert_equal 'something specific', json_response['description']
    assert_equal '087e2f211aba2881c08fd8d1646522a3+51', json_response['portable_data_hash']

    # search
    search_using_filter 'specific', 1, '087e2f211aba2881c08fd8d1646522a3+51'
    search_using_filter 'not specific enough', 0, nil
  end

  test "create collection, update manifest, and search with filename" do
    signing_opts = {
      key: Rails.configuration.blob_signing_key,
      api_token: api_token(:active),
    }
    signed_locator = Blob.sign_locator('bad42fa702ae3ea7d999fef11b46f450+44', signing_opts)

    # create collection
    post "/arvados/v1/collections", {
      format: :json,
      collection: "{\"manifest_text\":\". #{signed_locator} 0:44:my_test_file.txt\\n\"}"
    }, auth(:active)
    assert_response :success
    assert_equal true, json_response['manifest_text'].include?('my_test_file.txt')
    assert_equal '0f99f4087beb13dec46d36db9fa6cebf+60', json_response['portable_data_hash']

    created = json_response

    # search using the filename
    search_using_filter 'my_test_file.txt', 1, '0f99f4087beb13dec46d36db9fa6cebf+60'

    # update the collection's manifest text
    put "/arvados/v1/collections/#{created['uuid']}", {
      format: :json,
      collection: "{\"manifest_text\":\". #{signed_locator} 0:44:my_updated_test_file.txt\\n\"}"
    }, auth(:active)
    assert_response :success
    assert_equal created['uuid'], json_response['uuid']
    assert_equal true, json_response['manifest_text'].include?('my_updated_test_file.txt')
    assert_equal false, json_response['manifest_text'].include?('my_test_file.txt')

    # search using the new filename
    search_using_filter 'my_updated_test_file.txt', 1, '17d7d7e6f09ae17e3b580143586a1a3f+68'
    search_using_filter 'my_test_file.txt', 0, nil
    search_using_filter 'there_is_no_such_file.txt', 0, nil
  end

  def search_using_filter search_filter, expected_items, pdh
    get '/arvados/v1/collections', {
      where: { any: ['contains', search_filter] }
    }, auth(:active)
    assert_response :success
    response_items = json_response['items']
    assert_not_nil response_items
    if expected_items == 0
      assert_equal 0, json_response['items_available']
      assert_equal 0, response_items.size
    else
      assert_equal expected_items, response_items.size
      first_item = response_items.first
      assert_not_nil first_item
      assert_equal pdh, first_item['portable_data_hash']
    end
  end
end
