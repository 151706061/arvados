require 'integration_helper'

class ApplicationLayoutTest < ActionDispatch::IntegrationTest
  # These tests don't do state-changing API calls. Save some time by
  # skipping the database reset.
  reset_api_fixtures :after_each_test, false
  reset_api_fixtures :after_suite, true

  setup do
    need_javascript
  end

  def verify_homepage user, invited, has_profile
    profile_config = Rails.configuration.user_profile_form_fields

    if !user
      assert page.has_text?('Please log in'), 'Not found text - Please log in'
      assert page.has_text?('The "Log in" button below will show you a Google sign-in page'), 'Not found text - google sign in page'
      assert page.has_no_text?('My projects'), 'Found text - My projects'
      assert page.has_link?("Log in to #{Rails.configuration.site_name}"), 'Not found text - log in to'
    elsif user['is_active']
      if profile_config && !has_profile
        assert page.has_text?('Save profile'), 'No text - Save profile'
      else
        assert page.has_link?("Projects"), 'Not found link - Projects'
        page.find("#projects-menu").click
        assert_selector 'a', text: 'Search all projects'
        assert_no_selector 'a', text: 'Browse public projects'
        assert_selector 'a', text: 'Add a new project'
        assert_selector 'li[class="dropdown-header"]', text: 'My projects'
      end
    elsif invited
      assert page.has_text?('Please check the box below to indicate that you have read and accepted the user agreement'), 'Not found text - Please check the box below . . .'
    else
      assert page.has_text?('Your account is inactive'), 'Not found text - Your account is inactive'
    end

    within('.navbar-fixed-top') do
      if !user
        assert_text Rails.configuration.site_name.downcase
        assert_no_selector 'a', text: Rails.configuration.site_name.downcase
        assert page.has_link?('Log in'), 'Not found link - Log in'
      else
        # my account menu
        assert_selector 'a', text: Rails.configuration.site_name.downcase
        assert(page.has_link?("notifications-menu"), 'no user menu')
        page.find("#notifications-menu").click
        within('.dropdown-menu') do
          if user['is_active']
            assert page.has_no_link?('Not active'), 'Found link - Not active'
            assert page.has_no_link?('Sign agreements'), 'Found link - Sign agreements'

            assert_selector "a[href=\"/projects/#{user['uuid']}\"]", text: 'Home project'
            assert_selector "a[href=\"/users/#{user['uuid']}/virtual_machines\"]", text: 'Virtual machines'
            assert_selector "a[href=\"/users/#{user['uuid']}/repositories\"]", text: 'Repositories'
            assert_selector "a[href=\"/current_token\"]", text: 'Current token'
            assert_selector "a[href=\"/users/#{user['uuid']}/ssh_keys\"]", text: 'SSH keys'

            if profile_config
              assert_selector "a[href=\"/users/#{user['uuid']}/profile\"]", text: 'Manage profile'
            else
              assert_no_selector "a[href=\"/users/#{user['uuid']}/profile\"]", text: 'Manage profile'
            end
          else
            assert_no_selector 'a', text: 'Home project'
            assert page.has_no_link?('Virtual machines'), 'Found link - Virtual machines'
            assert page.has_no_link?('Repositories'), 'Found link - Repositories'
            assert page.has_no_link?('Current token'), 'Found link - Current token'
            assert page.has_no_link?('SSH keys'), 'Found link - SSH keys'
            assert page.has_no_link?('Manage profile'), 'Found link - Manage profile'
          end
          assert page.has_link?('Log out'), 'No link - Log out'
        end
      end
    end
  end

  # test the help menu
  def check_help_menu
    within('.navbar-fixed-top') do
      page.find("#arv-help").click
      within('.dropdown-menu') do
        assert_no_selector 'a', text:'Getting Started ...'
        assert_selector 'a', text:'Public Pipelines and Data sets'
        assert page.has_link?('Tutorials and User guide'), 'No link - Tutorials and User guide'
        assert page.has_link?('API Reference'), 'No link - API Reference'
        assert page.has_link?('SDK Reference'), 'No link - SDK Reference'
        assert page.has_link?('Show version / debugging info ...'), 'No link - Show version / debugging info'
        assert page.has_link?('Report a problem ...'), 'No link - Report a problem'
        # Version info and Report a problem are tested in "report_issue_test.rb"
      end
    end
  end

  def verify_system_menu user
    if user && user['is_admin']
      assert page.has_link?('system-menu'), 'No link - system menu'
      within('.navbar-fixed-top') do
        page.find("#system-menu").click
        within('.dropdown-menu') do
          assert page.has_text?('Groups'), 'No text - Groups'
          assert page.has_link?('Repositories'), 'No link - Repositories'
          assert page.has_link?('Virtual machines'), 'No link - Virtual machines'
          assert page.has_link?('SSH keys'), 'No link - SSH keys'
          assert page.has_link?('API tokens'), 'No link - API tokens'
          find('a', text: 'Users').click
        end
      end
      assert page.has_text? 'Add a new user'
    else
      assert page.has_no_link?('system-menu'), 'Found link - system menu'
    end
  end

  [
    [nil, nil, false, false],
    ['inactive', api_fixture('users')['inactive'], true, false],
    ['inactive_uninvited', api_fixture('users')['inactive_uninvited'], false, false],
    ['active', api_fixture('users')['active'], true, true],
    ['admin', api_fixture('users')['admin'], true, true],
    ['active_no_prefs', api_fixture('users')['active_no_prefs'], true, false],
    ['active_no_prefs_profile_no_getting_started_shown',
        api_fixture('users')['active_no_prefs_profile_no_getting_started_shown'], true, false],
  ].each do |token, user, invited, has_profile|

    test "visit home page for user #{token}" do
      if !token
        visit ('/')
      else
        visit page_with_token(token)
      end

      check_help_menu
      verify_homepage user, invited, has_profile
      verify_system_menu user
    end
  end

  [
    ['active', true],
    ['active_with_prefs_profile_no_getting_started_shown', false],
  ].each do |token, getting_started_shown|
    test "getting started help menu item #{getting_started_shown}" do
      Rails.configuration.enable_getting_started_popup = true

      visit page_with_token(token)

      if getting_started_shown
        within '.navbar-fixed-top' do
          find('.help-menu > a').click
          find('.help-menu .dropdown-menu a', text: 'Getting Started ...').click
        end
      end

      within '.modal-content' do
        assert_text 'Getting Started'
        assert_selector 'button:not([disabled])', text: 'Next'
        assert_no_selector 'button:not([disabled])', text: 'Prev'

        # Use Next button to enable Prev button
        click_button 'Next'
        assert_selector 'button:not([disabled])', text: 'Prev'  # Prev button is now enabled
        click_button 'Prev'
        assert_no_selector 'button:not([disabled])', text: 'Prev'  # Prev button is again disabled

        # Click Next until last page is reached and verify that it is disabled
        (0..20).each do |i|   # currently we only have 4 pages, and don't expect to have more than 20 in future
          click_button 'Next'
          begin
            find('button:not([disabled])', text: 'Next')
          rescue => e
            break
          end
        end
        assert_no_selector 'button:not([disabled])', text: 'Next'  # Next button is disabled
        assert_selector 'button:not([disabled])', text: 'Prev'     # Prev button is enabled
        click_button 'Prev'
        assert_selector 'button:not([disabled])', text: 'Next'     # Next button is now enabled

        first('button', text: 'x').click
      end
      assert_text 'Recent pipelines and processes' # seeing dashboard now
    end
  end

  test "test arvados_public_data_doc_url config unset" do
    Rails.configuration.arvados_public_data_doc_url = false

    visit page_with_token('active')
    within '.navbar-fixed-top' do
      find('.help-menu > a').click

      assert_no_selector 'a', text:'Public Pipelines and Data sets'
      assert_no_selector 'a', text:'Getting Started ...'

      assert page.has_link?('Tutorials and User guide'), 'No link - Tutorials and User guide'
      assert page.has_link?('API Reference'), 'No link - API Reference'
      assert page.has_link?('SDK Reference'), 'No link - SDK Reference'
      assert page.has_link?('Show version / debugging info ...'), 'No link - Show version / debugging info'
      assert page.has_link?('Report a problem ...'), 'No link - Report a problem'
    end
  end

  test "no SSH public key notification when shell_in_a_box_url is configured" do
    Rails.configuration.shell_in_a_box_url = 'example.com'
    visit page_with_token('job_reader')
    click_link 'notifications-menu'
    assert_no_selector 'a', text:'Click here to set up an SSH public key for use with Arvados.'
    assert_selector 'a', text:'Click here to learn how to run an Arvados Crunch pipeline'
  end

   [
    ['Repositories', nil, 's0uqq'],
    ['Virtual machines', nil, 'testvm.shell'],
    ['SSH keys', nil, 'public_key'],
    ['Links', nil, 'link_class'],
    ['Groups', nil, 'All users'],
    ['Compute nodes', nil, 'ping_secret'],
    ['Keep services', nil, 'service_ssl_flag'],
    ['Keep disks', nil, 'bytes_free'],
  ].each do |page_name, add_button_text, look_for|
    test "test system menu #{page_name} link" do
      visit page_with_token('admin')
      within('.navbar-fixed-top') do
        page.find("#system-menu").click
        within('.dropdown-menu') do
          assert_selector 'a', text: page_name
          find('a', text: page_name).click
        end
      end

      # click the add button if it exists
      if add_button_text
        assert_selector 'button', text: "Add a new #{add_button_text}"
        find('button', text: "Add a new #{add_button_text}").click
      else
        assert_no_selector 'button', text:"Add a new"
      end

      # look for unique property in the current page
      assert_text look_for
    end
  end

  [
    ['active', false],
    ['admin', true],
  ].each do |token, is_admin|
    test "visit dashboard as #{token}" do
      visit page_with_token(token)

      assert_text 'Recent pipelines and processes' # seeing dashboard now
      within('.recent-processes-actions') do
        assert page.has_link?('Run a pipeline')
        assert page.has_link?('All processes')
      end

      within('.recent-processes') do
        assert_text 'running_with_job'
        within('.row-zzzzz-d1hrv-runningpipeline') do
          assert_text 'foo'
        end

        assert_text 'zzzzz-d1hrv-twodonepipeline'
        within('.row-zzzzz-d1hrv-twodonepipeline')do
          assert_text 'No output'
        end

        assert_text 'completed container request'
        within('.row-zzzzz-xvhdp-cr4completedctr')do
          assert page.has_link? 'foo_file'
        end
      end

      within('.compute-node-actions') do
        if is_admin
          assert page.has_link?('All nodes')
        else
          assert page.has_no_link?('All nodes')
        end
      end

      within('.compute-node-summary-pane') do
        click_link 'Details'
        assert_text 'compute0'
      end
    end
  end

  [
    ['jobs', 'running_job_with_components', true],
    ['pipeline_instances', 'components_is_jobspec', false],
    ['containers', 'running', false],
    ['container_requests', 'running', true],
  ].each do |type, fixture, cancelable|
    test "cancel button for #{type}/#{fixture}" do
      if cancelable
        need_selenium 'to cancel'
      end

      obj = api_fixture(type)[fixture]
      visit page_with_token "active", "/#{type}/#{obj['uuid']}"

      assert_text 'created_at'
      if cancelable
        assert page.has_button?('Cancel'), 'No Cancel button'
        click_button 'Cancel'
        wait_for_ajax
        assert page.has_no_button?('Cancel'), 'Cancel button not expected after clicking'
      else
        assert page.has_no_button?('Cancel'), 'Cancel button not expected'
      end
    end
  end

  [
    ['jobs', 'running_job_with_components'],
    ['pipeline_instances', 'has_component_with_completed_jobs'],
    ['container_requests', 'running'],
    ['container_requests', 'completed'],
  ].each do |type, fixture|
    test "edit description for #{type}/#{fixture}" do
      obj = api_fixture(type)[fixture]
      visit page_with_token "active", "/#{type}/#{obj['uuid']}"

      within('.arv-description-as-subtitle') do
        find('.fa-pencil').click
        find('.editable-input textarea').set('*Textile description for object*')
        find('.editable-submit').click
      end
      wait_for_ajax

      # verify description
      assert page.has_no_text? '*Textile description for object*'
      assert page.has_text? 'Textile description for object'
    end
  end

  [
    ['Two Part Pipeline Template', 'part-one', 'Provide a value for the following'],
    ['Workflow with input specifications', 'this work has inputs specified', 'This container is uncommitted'],
  ].each do |template_name, preview_txt, process_txt|
    test "run a process using template #{template_name} from dashboard" do
      visit page_with_token('admin')
      assert_text 'Recent pipelines and processes' # seeing dashboard now

      within('.recent-processes-actions') do
        assert page.has_link?('All processes')
        find('a', text: 'Run a pipeline').click
      end

      # in the chooser, verify preview and click Next button
      within('.modal-dialog') do
        find('.selectable', text: template_name).click
        assert_text preview_txt
        find('.btn', text: 'Next: choose inputs').click
      end

      # in the process page now
      assert_text process_txt
    end
  end
end
