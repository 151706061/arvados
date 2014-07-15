# Mixin module providing a method to convert filters into a list of SQL
# fragments suitable to be fed to ActiveRecord #where.
#
# Expects:
#   model_class
# Operates on:
#   @objects
module RecordFilters

  # Input:
  # +filters+        array of conditions, each being [column, operator, operand]
  # +ar_table_name+  name of SQL table
  #
  # Output:
  # Hash with two keys:
  # :cond_out  array of SQL fragments for each filter expression
  # :param_out  array of values for parameter substitution in cond_out
  def record_filters filters, ar_table_name
    cond_out = []
    param_out = []

    filters.each do |filter|
      attr, operator, operand = filter
      if !filter.is_a? Array
        raise ArgumentError.new("Invalid element in filters array: #{filter.inspect} is not an array")
      elsif !operator.is_a? String
        raise ArgumentError.new("Invalid operator '#{operator}' (#{operator.class}) in filter")
      elsif !model_class.searchable_columns(operator).index attr.to_s
        raise ArgumentError.new("Invalid attribute '#{attr}' in filter")
      end
      case operator.downcase
      when '=', '<', '<=', '>', '>=', '!=', 'like'
        attr_type = model_class.attribute_column(attr).type
        operator = '<>' if operator == '!='
        if operand.is_a? String
          if attr_type == :boolean
            if not ['=', '<>'].include?(operator)
              raise ArgumentError.new("Invalid operator '#{operator}' for " \
                                      "boolean attribute '#{attr}'")
            end
            case operand.downcase
            when '1', 't', 'true', 'y', 'yes'
              operand = true
            when '0', 'f', 'false', 'n', 'no'
              operand = false
            else
              raise ArgumentError("Invalid operand '#{operand}' for " \
                                  "boolean attribute '#{attr}'")
            end
          end
          cond_out << "#{ar_table_name}.#{attr} #{operator} ?"
          if (# any operator that operates on value rather than
              # representation:
              operator.match(/[<=>]/) and (attr_type == :datetime))
            operand = Time.parse operand
          end
          param_out << operand
        elsif operand.nil? and operator == '='
          cond_out << "#{ar_table_name}.#{attr} is null"
        elsif operand.nil? and operator == '<>'
          cond_out << "#{ar_table_name}.#{attr} is not null"
        elsif (attr_type == :boolean) and ['=', '<>'].include?(operator) and
            [true, false].include?(operand)
          cond_out << "#{ar_table_name}.#{attr} #{operator} ?"
          param_out << operand
        else
          raise ArgumentError.new("Invalid operand type '#{operand.class}' "\
                                  "for '#{operator}' operator in filters")
        end
      when 'in', 'not in'
        if operand.is_a? Array
          cond_out << "#{ar_table_name}.#{attr} #{operator} (?)"
          param_out << operand
          if operator == 'not in' and not operand.include?(nil)
            # explicitly allow NULL
            cond_out[-1] = "(#{cond_out[-1]} OR #{ar_table_name}.#{attr} IS NULL)"
          end
        else
          raise ArgumentError.new("Invalid operand type '#{operand.class}' "\
                                  "for '#{operator}' operator in filters")
        end
      when 'is_a'
        operand = [operand] unless operand.is_a? Array
        cond = []
        operand.each do |op|
          cl = ArvadosModel::kind_class op
          if cl
            cond << "#{ar_table_name}.#{attr} like ?"
            param_out << cl.uuid_like_pattern
          else
            cond << "1=0"
          end
        end
        cond_out << cond.join(' OR ')
      end
    end

    {:cond_out => cond_out, :param_out => param_out}
  end

end
