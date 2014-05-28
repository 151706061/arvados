require 'test_helper'

class ArvadosModelTest < ActiveSupport::TestCase
  fixtures :all

  def create_with_attrs attrs
    a = Specimen.create({material: 'caloric'}.merge(attrs))
    a if a.valid?
  end

  test 'non-admin cannot assign uuid' do
    set_user_from_auth :active_trustedclient
    want_uuid = Specimen.generate_uuid
    a = create_with_attrs(uuid: want_uuid)
    assert_not_equal want_uuid, a.uuid, "Non-admin should not assign uuid."
    assert a.uuid.length==27, "Auto assigned uuid length is wrong."
  end

  test 'admin can assign valid uuid' do
    set_user_from_auth :admin_trustedclient
    want_uuid = Specimen.generate_uuid
    a = create_with_attrs(uuid: want_uuid)
    assert_equal want_uuid, a.uuid, "Admin should assign valid uuid."
    assert a.uuid.length==27, "Auto assigned uuid length is wrong."
  end

  test 'admin cannot assign empty uuid' do
    set_user_from_auth :admin_trustedclient
    a = create_with_attrs(uuid: "")
    assert_not_equal "", a.uuid, "Admin should not assign empty uuid."
    assert a.uuid.length==27, "Auto assigned uuid length is wrong."
  end

  [ {:a => 'foo'},
    {'a' => {'foo' => {:bar => 'baz'}}},
    {'a' => {'foo' => {'bar' => :baz}}},
    {'a' => {'foo' => ['bar', :baz]}},
    {'a' => {['foo', :foo] => ['bar', 'baz']}},
  ].each do |x|
    test "refuse symbol keys in serialized attribute: #{x.inspect}" do
      set_user_from_auth :admin_trustedclient
      assert_nothing_raised do
        Link.create!(link_class: 'test',
                     properties: {})
      end
      assert_raises ActiveRecord::RecordInvalid do
        Link.create!(link_class: 'test',
                     properties: x)
      end
    end
  end

  test "Stringify symbols coming from serialized attribute in database" do
    fixed = Link.find_by_uuid(links(:has_symbol_keys_in_database_somehow).uuid)
    assert_equal(["baz", "foo"], fixed.properties.keys.sort,
                 "Hash symbol keys from DB did not get stringified.")
    assert_equal(['waz', 'waz', 'waz', 1, nil, false, true],
                 fixed.properties['baz'],
                 "Array symbol values from DB did not get stringified.")
  end
end
