require 'test_helper'
require 'helpers/git_test_helper'

class JobTest < ActiveSupport::TestCase
  include GitTestHelper

  BAD_COLLECTION = "#{'f' * 32}+0"

  setup do
    set_user_from_auth :active
  end

  def job_attrs merge_me={}
    # Default (valid) set of attributes, with given overrides
    {
      script: "hash",
      script_version: "master",
      repository: "foo",
    }.merge(merge_me)
  end

  test "Job without Docker image doesn't get locator" do
    job = Job.new job_attrs
    assert job.valid?, job.errors.full_messages.to_s
    assert_nil job.docker_image_locator
  end

  { 'name' => [:links, :docker_image_collection_repository, :name],
    'hash' => [:links, :docker_image_collection_hash, :name],
    'locator' => [:collections, :docker_image, :portable_data_hash],
  }.each_pair do |spec_type, (fixture_type, fixture_name, fixture_attr)|
    test "Job initialized with Docker image #{spec_type} gets locator" do
      image_spec = send(fixture_type, fixture_name).send(fixture_attr)
      job = Job.new job_attrs(runtime_constraints:
                              {'docker_image' => image_spec})
      assert job.valid?, job.errors.full_messages.to_s
      assert_equal(collections(:docker_image).portable_data_hash, job.docker_image_locator)
    end

    test "Job modified with Docker image #{spec_type} gets locator" do
      job = Job.new job_attrs
      assert job.valid?, job.errors.full_messages.to_s
      assert_nil job.docker_image_locator
      image_spec = send(fixture_type, fixture_name).send(fixture_attr)
      job.runtime_constraints['docker_image'] = image_spec
      assert job.valid?, job.errors.full_messages.to_s
      assert_equal(collections(:docker_image).portable_data_hash, job.docker_image_locator)
    end
  end

  test "removing a Docker runtime constraint removes the locator" do
    image_locator = collections(:docker_image).portable_data_hash
    job = Job.new job_attrs(runtime_constraints:
                            {'docker_image' => image_locator})
    assert job.valid?, job.errors.full_messages.to_s
    assert_equal(image_locator, job.docker_image_locator)
    job.runtime_constraints = {}
    assert job.valid?, job.errors.full_messages.to_s + "after clearing runtime constraints"
    assert_nil job.docker_image_locator
  end

  test "locate a Docker image with a repository + tag" do
    image_repo, image_tag =
      links(:docker_image_collection_tag2).name.split(':', 2)
    job = Job.new job_attrs(runtime_constraints:
                            {'docker_image' => image_repo,
                              'docker_image_tag' => image_tag})
    assert job.valid?, job.errors.full_messages.to_s
    assert_equal(collections(:docker_image).portable_data_hash, job.docker_image_locator)
  end

  test "can't locate a Docker image with a nonexistent tag" do
    image_repo = links(:docker_image_collection_repository).name
    image_tag = '__nonexistent tag__'
    job = Job.new job_attrs(runtime_constraints:
                            {'docker_image' => image_repo,
                              'docker_image_tag' => image_tag})
    assert(job.invalid?, "Job with bad Docker tag valid")
  end

  test "locate a Docker image with a partial hash" do
    image_hash = links(:docker_image_collection_hash).name[0..24]
    job = Job.new job_attrs(runtime_constraints:
                            {'docker_image' => image_hash})
    assert job.valid?, job.errors.full_messages.to_s + " with partial hash #{image_hash}"
    assert_equal(collections(:docker_image).portable_data_hash, job.docker_image_locator)
  end

  { 'name' => 'arvados_test_nonexistent',
    'hash' => 'f' * 64,
    'locator' => BAD_COLLECTION,
  }.each_pair do |spec_type, image_spec|
    test "Job validation fails with nonexistent Docker image #{spec_type}" do
      job = Job.new job_attrs(runtime_constraints:
                              {'docker_image' => image_spec})
      assert(job.invalid?, "nonexistent Docker image #{spec_type} was valid")
    end
  end

  test "Job validation fails with non-Docker Collection constraint" do
    job = Job.new job_attrs(runtime_constraints:
                            {'docker_image' => collections(:foo_file).uuid})
    assert(job.invalid?, "non-Docker Collection constraint was valid")
  end

  test "can create Job with Docker image Collection without Docker links" do
    image_uuid = collections(:unlinked_docker_image).portable_data_hash
    job = Job.new job_attrs(runtime_constraints: {"docker_image" => image_uuid})
    assert(job.valid?, "Job created with unlinked Docker image was invalid")
    assert_equal(image_uuid, job.docker_image_locator)
  end

  test "can't create Job with Docker image locator" do
    begin
      job = Job.new job_attrs(docker_image_locator: BAD_COLLECTION)
    rescue ActiveModel::MassAssignmentSecurity::Error
      # Test passes - expected attribute protection
    else
      assert_nil job.docker_image_locator
    end
  end

  test "can't assign Docker image locator to Job" do
    job = Job.new job_attrs
    begin
      Job.docker_image_locator = BAD_COLLECTION
    rescue NoMethodError
      # Test passes - expected attribute protection
    end
    assert_nil job.docker_image_locator
  end

  [
   {script_parameters: ""},
   {script_parameters: []},
   {script_parameters: {symbols: :are_not_allowed_here}},
   {runtime_constraints: ""},
   {runtime_constraints: []},
   {tasks_summary: ""},
   {tasks_summary: []},
   {script_version: "no/branch/could/ever/possibly/have/this/name"},
  ].each do |invalid_attrs|
    test "validation failures set error messages: #{invalid_attrs.to_json}" do
      # Ensure valid_attrs doesn't produce errors -- otherwise we will
      # not know whether errors reported below are actually caused by
      # invalid_attrs.
      dummy = Job.create! job_attrs

      job = Job.create job_attrs(invalid_attrs)
      assert_raises(ActiveRecord::RecordInvalid, ArgumentError,
                    "save! did not raise the expected exception") do
        job.save!
      end
      assert_not_empty job.errors, "validation failure did not provide errors"
    end
  end
end
