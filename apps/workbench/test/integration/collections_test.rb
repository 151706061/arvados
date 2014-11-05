require 'integration_helper'
require 'selenium-webdriver'
require 'headless'

class CollectionsTest < ActionDispatch::IntegrationTest
  setup do
    Capybara.current_driver = :rack_test
  end

  test "Can copy a collection to a project" do
    Capybara.current_driver = Capybara.javascript_driver

    collection_uuid = api_fixture('collections')['foo_file']['uuid']
    collection_name = api_fixture('collections')['foo_file']['name']
    project_uuid = api_fixture('groups')['aproject']['uuid']
    project_name = api_fixture('groups')['aproject']['name']
    visit page_with_token('active', "/collections/#{collection_uuid}")
    click_link 'Copy to project...'
    find('.selectable', text: project_name).click
    find('.modal-footer a,button', text: 'Copy').click
    wait_for_ajax
    # It should navigate to the project after copying...
    assert(page.has_text?(project_name))
    assert(page.has_text?("Copy of #{collection_name}"))
  end

  test "Collection page renders name" do
    uuid = api_fixture('collections')['foo_file']['uuid']
    coll_name = api_fixture('collections')['foo_file']['name']
    visit page_with_token('active', "/collections/#{uuid}")
    assert(page.has_text?(coll_name), "Collection page did not include name")
    # Now check that the page is otherwise normal, and the collection name
    # isn't only showing up in an error message.
    assert(page.has_link?('foo'), "Collection page did not include file link")
  end

  test "can download an entire collection with a reader token" do
    uuid = api_fixture('collections')['foo_file']['uuid']
    token = api_fixture('api_client_authorizations')['active_all_collections']['api_token']
    url_head = "/collections/download/#{uuid}/#{token}/"
    visit url_head
    # It seems that Capybara can't inspect tags outside the body, so this is
    # a very blunt approach.
    assert_no_match(/<\s*meta[^>]+\bnofollow\b/i, page.html,
                    "wget prohibited from recursing the collection page")
    # TODO: When we can test against a Keep server, actually follow links
    # and check their contents, rather than testing the href directly
    # (this is too closely tied to implementation details).
    hrefs = page.all('a').map do |anchor|
      link = anchor[:href] || ''
      if link.start_with? url_head
        link[url_head.size .. -1]
      elsif link.start_with? '/'
        nil
      else
        link
      end
    end
    assert_equal(['foo'], hrefs.compact.sort,
                 "download page did provide strictly file links")
  end

  test "can view empty collection" do
    uuid = 'd41d8cd98f00b204e9800998ecf8427e+0'
    visit page_with_token('active', "/collections/#{uuid}")
    assert page.has_text?('This collection is empty')
  end

  test "combine selected collections into new collection" do
    headless = Headless.new
    headless.start
    Capybara.current_driver = :selenium

    foo_collection = api_fixture('collections')['foo_file']
    bar_collection = api_fixture('collections')['bar_file']

    visit page_with_token('active', "/collections")

    assert(page.has_text?(foo_collection['uuid']), "Collection page did not include foo file")
    assert(page.has_text?(bar_collection['uuid']), "Collection page did not include bar file")

    within('tr', text: foo_collection['uuid']) do
      find('input[type=checkbox]').click
    end

    within('tr', text: bar_collection['uuid']) do
      find('input[type=checkbox]').click
    end

    click_button 'Selection...'
    within('.selection-action-container') do
      click_link 'Create new collection with selected collections'
    end

    # now in the newly created collection page
    assert(page.has_text?('Copy to project'), "Copy to project text not found in new collection page")
    assert(page.has_no_text?(foo_collection['name']), "Collection page did not include foo file")
    assert(page.has_text?('foo'), "Collection page did not include foo file")
    assert(page.has_no_text?(bar_collection['name']), "Collection page did not include foo file")
    assert(page.has_text?('bar'), "Collection page did not include bar file")
    assert(page.has_text?('Created new collection in your Home project'),
                          'Not found flash message that new collection is created in Home project')
    headless.stop
  end

  [
    ['active', 'foo_file', false],
    ['active', 'foo_collection_in_aproject', true],
    ['project_viewer', 'foo_file', false],
    ['project_viewer', 'foo_collection_in_aproject', false], #aproject not writable
  ].each do |user, collection, expect_collection_in_aproject|
    test "combine selected collection files into new collection #{user} #{collection} #{expect_collection_in_aproject}" do
      headless = Headless.new
      headless.start
      Capybara.current_driver = :selenium

      my_collection = api_fixture('collections')[collection]

      visit page_with_token(user, "/collections")

      # choose file from foo collection
      within('tr', text: my_collection['uuid']) do
        click_link 'Show'
      end

      # now in collection page
      find('input[type=checkbox]').click

      click_button 'Selection...'
      within('.selection-action-container') do
        click_link 'Create new collection with selected files'
      end

      # now in the newly created collection page
      assert(page.has_text?('Copy to project'), "Copy to project text not found in new collection page")
      assert(page.has_no_text?(my_collection['name']), "Collection page did not include foo file")
      assert(page.has_text?('foo'), "Collection page did not include foo file")
      if expect_collection_in_aproject
        aproject = api_fixture('groups')['aproject']
        assert page.has_text?("Created new collection in the project #{aproject['name']}"),
                              'Not found flash message that new collection is created in aproject'
      else
        assert page.has_text?("Created new collection in your Home project"),
                              'Not found flash message that new collection is created in Home project'
      end

      headless.stop
    end
  end

  test "combine selected collection files from collection subdirectory" do
    headless = Headless.new
    headless.start
    Capybara.current_driver = :selenium

    visit page_with_token('user1_with_load', "/collections/zzzzz-4zz18-filesinsubdir00")

    # now in collection page
    input_files = page.all('input[type=checkbox]')
    (0..input_files.count-1).each do |i|
      input_files[i].click
    end

    click_button 'Selection...'
    within('.selection-action-container') do
      click_link 'Create new collection with selected files'
    end

    # now in the newly created collection page
    assert(page.has_text?('file_in_subdir1'), 'file not found - file_in_subdir1')
    assert(page.has_text?('file1_in_subdir3.txt'), 'file not found - file1_in_subdir3.txt')
    assert(page.has_text?('file2_in_subdir3.txt'), 'file not found - file2_in_subdir3.txt')
    assert(page.has_text?('file1_in_subdir4.txt'), 'file not found - file1_in_subdir4.txt')
    assert(page.has_text?('file2_in_subdir4.txt'), 'file not found - file1_in_subdir4.txt')

    headless.stop
  end

  test "Collection portable data hash redirect" do
    di = api_fixture('collections')['docker_image']
    visit page_with_token('active', "/collections/#{di['portable_data_hash']}")

    # check redirection
    assert current_path.end_with?("/collections/#{di['uuid']}")
    assert page.has_text?("docker_image")
    assert page.has_text?("Activity")
    assert page.has_text?("Sharing and permissions")
  end

  test "Collection portable data hash with multiple matches" do
    pdh = api_fixture('collections')['baz_file']['portable_data_hash']
    visit page_with_token('admin', "/collections/#{pdh}")

    matches = api_fixture('collections').select {|k,v| v["portable_data_hash"] == pdh}
    assert matches.size > 1

    matches.each do |k,v|
      assert page.has_link?(v["name"]), "Page /collections/#{pdh} should contain link '#{v['name']}'"
    end
    assert page.has_no_text?("Activity")
    assert page.has_no_text?("Sharing and permissions")
  end

  test "Filtering collection files by regexp" do
    col = api_fixture('collections', 'multilevel_collection_1')
    visit page_with_token('active', "/collections/#{col['uuid']}")

    # Test when only some files match the regex
    page.find_field('file_regex').set('file[12]')
    find('button#file_regex_submit').click
    assert page.has_text?("file1")
    assert page.has_text?("file2")
    assert page.has_no_text?("file3")

    # Test all files matching the regex
    page.find_field('file_regex').set('file[123]')
    find('button#file_regex_submit').click
    assert page.has_text?("file1")
    assert page.has_text?("file2")
    assert page.has_text?("file3")

    # Test no files matching the regex
    page.find_field('file_regex').set('file9')
    find('button#file_regex_submit').click
    assert page.has_no_text?("file1")
    assert page.has_no_text?("file2")
    assert page.has_no_text?("file3")
    # make sure that we actually are looking at the collections
    # page and not e.g. a fiddlesticks
    assert page.has_text?("multilevel_collection_1")
    assert page.has_text?(col['portable_data_hash'])

    # Syntactically invalid regex
    # Page loads, but does not match any files
    page.find_field('file_regex').set('file[2')
    find('button#file_regex_submit').click
    assert page.has_text?('could not be parsed as a regular expression')
    assert page.has_no_text?("file1")
    assert page.has_no_text?("file2")
    assert page.has_no_text?("file3")
  end
end
