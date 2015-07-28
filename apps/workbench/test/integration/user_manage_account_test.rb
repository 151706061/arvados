require 'integration_helper'

class UserManageAccountTest < ActionDispatch::IntegrationTest
  setup do
    need_javascript
  end

  # test manage_account page
  def verify_manage_account user
    if user['is_active']
      within('.navbar-fixed-top') do
        page.find("#notifications-menu").click
        within('.dropdown-menu') do
          assert_selector 'a', text: 'My Virtual Machines'
          assert_selector 'a', text: 'My Repositories'
          assert_selector 'a', text: 'My Current Token'
          assert_selector 'a', text: 'My SSH Keys'
          find('a', text: 'My SSH Keys').click
        end
      end

      # now in My SSH Keys page
      assert page.has_text?('Add new SSH key'), 'No text - Add SSH key'
      add_and_verify_ssh_key
    else  # inactive user
      within('.navbar-fixed-top') do
        page.find("#notifications-menu").click
        within('.dropdown-menu') do
          assert page.has_no_link?('Manage profile'), 'Found link - Manage profile'
        end
      end
    end
  end

  def add_and_verify_ssh_key
      click_link 'Add new SSH key'

      within '.modal-content' do
        assert page.has_text?('Public Key'), 'No text - Public Key'
        assert page.has_button?('Cancel'), 'No button - Cancel'
        assert page.has_button?('Submit'), 'No button - Submit'

        page.find_field('public_key').set 'first test with an incorrect ssh key value'
        click_button 'Submit'
        assert page.has_text?('Public key does not appear to be a valid ssh-rsa or dsa public key'), 'No text - Public key does not appear to be a valid'

        public_key_str = api_fixture('authorized_keys')['active']['public_key']
        page.find_field('public_key').set public_key_str
        page.find_field('name').set 'added_in_test'
        click_button 'Submit'
        assert page.has_text?('Public key already exists in the database, use a different key.'), 'No text - Public key already exists'

        new_key = SSHKey.generate
        page.find_field('public_key').set new_key.ssh_public_key
        page.find_field('name').set 'added_in_test'
        click_button 'Submit'
      end

      # key must be added. look for it in the refreshed page
      assert page.has_text?('added_in_test'), 'No text - added_in_test'
  end

  [
    ['inactive', api_fixture('users')['inactive']],
    ['inactive_uninvited', api_fixture('users')['inactive_uninvited']],
    ['active', api_fixture('users')['active']],
    ['admin', api_fixture('users')['admin']],
  ].each do |token, user|
    test "test manage account for user #{token}" do
      visit page_with_token(token)
      verify_manage_account user
    end
  end

  test "pipeline notification shown even though public pipelines exist" do
    skip "created_by doesn't work that way"
    Rails.configuration.anonymous_user_token = api_fixture('api_client_authorizations')['anonymous']['api_token']
    visit page_with_token 'job_reader'
    click_link 'notifications-menu'
    assert_selector 'a', text: 'Click here to learn how to run an Arvados Crunch pipeline'
  end

  [
    ['job_reader', :ssh, :pipeline],
    ['active'],
  ].each do |user, *expect|
    test "manage account for #{user} with notifications #{expect.inspect}" do
      Rails.configuration.anonymous_user_token = false
      visit page_with_token(user)
      click_link 'notifications-menu'
      if expect.include? :ssh
        assert_selector('a', text: 'Click here to set up an SSH public key for use with Arvados')
        click_link('Click here to set up an SSH public key for use with Arvados')
        assert_selector('a', text: 'Add new SSH key')

        add_and_verify_ssh_key

        # No more SSH notification
        click_link 'notifications-menu'
        assert_no_selector('a', text: 'Click here to set up an SSH public key for use with Arvados')
      else
        assert_no_selector('a', text: 'Click here to set up an SSH public key for use with Arvados')
        assert_no_selector('a', text: 'Click here to learn how to run an Arvados Crunch pipeline')
      end

      if expect.include? :pipeline
        assert_selector('a', text: 'Click here to learn how to run an Arvados Crunch pipeline')
      end
    end
  end

  test "verify repositories for active user" do
    visit page_with_token('active', '/manage_account')

    repos = [[api_fixture('repositories')['foo'], true, true],
             [api_fixture('repositories')['repository3'], false, false],
             [api_fixture('repositories')['repository4'], true, false]]

    repos.each do |(repo, writable, sharable)|
      within('tr', text: repo['name']+'.git') do
        if sharable
          assert_selector 'a', text:'Share'
          assert_text 'writable'
        else
          assert_text repo['name']
          assert_no_selector 'a', text:'Share'
          if writable
            assert_text 'writable'
          else
            assert_text 'read-only'
          end
        end
      end
    end
  end

  test "request shell access" do
    ActionMailer::Base.deliveries = []
    visit page_with_token('spectator', '/manage_account')
    assert_text 'You do not have access to any virtual machines'
    click_link 'Send request for shell access'

    # Button text changes to "sending...", then back to normal. In the
    # test suite we can't depend on confirming the "sending..." state
    # before it goes back to normal, though.
    ## assert_selector 'a', text: 'Sending request...'
    assert_selector 'a', text: 'Send request for shell access'
    assert_text 'A request for shell access was sent'

    # verify that the email was sent
    user = api_fixture('users')['spectator']
    full_name = "#{user['first_name']} #{user['last_name']}"
    expected = "Shell account request from #{full_name} (#{user['email']}, #{user['uuid']})"
    found_email = 0
    ActionMailer::Base.deliveries.each do |email|
      if email.subject.include?(expected)
        found_email += 1
      end
    end
    assert_equal 1, found_email, "Expected email after requesting shell access"

    # Revisit the page and verify the request sent message along with
    # the request button.
    within('.navbar-fixed-top') do
      page.find("#notifications-menu").click
      within('.dropdown-menu') do
        find('a', text: 'My Virtual Machines').click
      end
    end
    assert_text 'You do not have access to any virtual machines.'
    assert_text 'A request for shell access was sent on '
    assert_selector 'a', text: 'Send request for shell access'
  end

  test "create new repository" do
    visit page_with_token("active_trustedclient", "/manage_account")
    click_on "Add new repository"
    within ".modal-dialog" do
      fill_in "Name", with: "workbenchtest"
      click_on "Create"
    end
    assert_text ":active/workbenchtest.git"
    assert_match /git@git.*:active\/workbenchtest.git/, page.text
    assert_match /https:\/\/git.*\/active\/workbenchtest.git/, page.text
  end

  [
    ['My Virtual Machines', nil, 'Host name'],
    ['My Repositories', 'Add new repository', 'It may take a minute or two before you can clone your new repository.'],
    ['My Current Token', nil, 'HISTIGNORE=$HISTIGNORE'],
    ['My SSH Keys', 'Add new SSH key', 'Click here to learn about SSH keys in Arvados.'],
  ].each do |page_name, button_name, look_for|
    test "test notification menu for page #{page_name}" do
      visit page_with_token('admin')
      within('.navbar-fixed-top') do
          page.find("#notifications-menu").click
          within('.dropdown-menu') do
            assert_selector 'a', text: page_name
            find('a', text: page_name).click
          end
      end

      if button_name
        assert_selector 'a', text: button_name
        find('a', text: button_name).click
      end

      assert page.has_text? look_for
    end
  end

  [
    ['My Virtual Machines', 'You do not have access to any virtual machines.'],
    ['My Repositories', 'You do not seem to have access to any repositories.'],
    ['My Current Token', 'HISTIGNORE=$HISTIGNORE'],
    ['My SSH Keys', 'You have not yet set up an SSH public key for use with Arvados.'],
  ].each do |page_name, look_for|
    test "test notification menu for page #{page_name} when page is empty" do
      visit page_with_token('user1_with_load')
      within ('.navbar-fixed-top') do
        page.find("#notifications-menu").click
        within('.dropdown-menu') do
          assert_selector 'a', text: page_name
          find('a', text: page_name).click
        end
      end

     assert page.has_text? look_for
    end
  end
end
