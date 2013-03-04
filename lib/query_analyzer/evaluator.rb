require 'rubygems'
require 'mongo'

class EvaluationResult
  def initialize(msg, level)
    @msg = msg
    @level = level
  end
  attr_accessor :msg, :level
end


class EfficiencyResult < EvaluationResult
  # Severity levels:
  WARNING = :warning
  BAD = :bad
  CRITICAL = :critical

  # Inefficiency codes (chiefly for testing purposes):
  ALL = :all
  IN = :in
  NEGATION = :negation
  WHERE = :where
  NOT = :not
  NOR = :nor
  REGEX_ANCHOR = :regex_anchor
  REGEX_CASE = :regex_case
  REGEX_BAD_END = :regex_bad_end
  SIZE = :size

  def initialize(msg, level, code)
    super(msg, level)
    @code = code
  end

  attr_accessor :code
end


class IndexResult < EvaluationResult
  # May ignore some fields or contain too many fields
  # User should consider whether create this index is worth it.
  OPTIONAL = :optional

  # Most of time it improves performance
  GOOD = :good

  # returns the index serialized as string, e.g.:
  # "{ 'price': 1, 'rating': 1, 'duration': 1 }"
  def raw_index
    elems = @index.map { |field, type|
      type_str = type == Mongo::ASCENDING ? '1' : '-1'
      "'#{field}': #{type_str}"
    }
    return "{ " + elems.join(", ") + " }"
  end

  def initialize(index, level)
    @index = index
    super("Index recommendation: #{raw_index()}", level)
  end

  attr_accessor :index
end


class Evaluator
  def initialize(addr, port)
    @addr = addr
    @port = port
  end

  def get_db(dbname)
    cl = Mongo::MongoClient.new @addr, @port
    return cl.db(dbname)
  end

  def get_coll(namespace)
    db_name, collection_name = namespace.split('.',2)
    db = get_db(db_name)
    coll = db[collection_name]
  end

  def get_index_information(namespace)
    if namespace.nil?
      return {}
    else
     return get_coll(namespace).index_information
    end
  end

  # Evaluates the whole query.
  # Returns an array of EvaluationResult objects.
  # query_hash is the decoded query json, e.g.
  # {
  #     "B" => {"$in" => [24.0, 25.0]},
  #     "A" => {"$gt" => 27.3, "$lt" => 1000.0},
  # }
  # additional arguments may be passed in the args hash:
  # :suggest_indexes => true | false
  # :sort_hash => a hash describing sorting order
  # :namespace => a collection namespace
  def evaluate_query(query_hash, args = {})
    sort_hash = args[:sort_hash] || {}
    suggest_indexes = args[:suggest_indexes]
    namespace = args[:namespace]
    if suggest_indexes.nil? then suggest_indexes = true end

    out = []

    if suggest_indexes then
        out += check_for_indexes(query_hash, sort_hash, namespace)
    end

    out += analyze_query query_hash
    return out
  end

  private

  #
  # the operator handlers follow
  # every handler returns an array of EfficiencyResult objects
  # depending on the following arguments
  # field (self explanatory)
  # operator_arg - the query arguments, specific to different operators
  #

  def handle_all (field, operator_arg)
    return [
      EfficiencyResult.new(
        %{\
In the current release queries that use the $all operator must \
scan all the documents that match the first element in the query \
array. As a result, even with an index to support the query, the \
operation may be long running, particularly when the first element \
in the array is not very selective.},
        EfficiencyResult::CRITICAL,
        EfficiencyResult::ALL)
    ]
  end

  MAX_IN_ARRAY = 2000
  def handle_in (field, operator_arg)
    result = []
    elems_no = operator_arg.count
    if elems_no > MAX_IN_ARRAY then
      result << EfficiencyResult.new(
        "$in operator with a large array (#{elems_no}) is inefficient",
        EfficiencyResult::CRITICAL,
        EfficiencyResult::IN)
    end
    return result
  end

  def handle_negation (field, operator_arg)
    return [
      EfficiencyResult.new(
        'Negation operators ($ne, $nin) are inefficient.',
        EfficiencyResult::CRITICAL,
        EfficiencyResult::NEGATION)
    ]
  end

  def handle_where (field, operator_arg)
    return [
      EfficiencyResult.new(
        'javascript is slow, you should consider redesigning your queries.',
        EfficiencyResult::CRITICAL,
        EfficiencyResult::WHERE)
    ]
  end

  def handle_multiple(field, operator_arg)
    res = []
    operator_arg.each do |query|
      res += analyze_query(query)
    end
    return res
  end

  def handle_not(field, operator_arg)
    res = [
      EfficiencyResult.new(
        'Negation operator ($not) is inefficient',
        EfficiencyResult::CRITICAL,
        EfficiencyResult::NOT)
    ]
    res += handle_single_field(field, operator_arg)
    return res
  end

  def handle_nor(field, operator_arg)
    res = [
      EfficiencyResult.new(
        'Negation operator ($nor) is inefficient',
        EfficiencyResult::CRITICAL,
        EfficiencyResult::NOR)
    ]
    res += handle_multiple(field, operator_arg)
    return res
  end

  def handle_regex(field, operator_arg)
    res = []
    regex = eval operator_arg

    if not regex.source.start_with? '^' then
      res << EfficiencyResult.new(
        'Try to change the regex so that it has an anchor for the ' +
        'beginning (i.e. ^). Otherwise the engine cannot make use of ' +
        'indexes (if there are any).',
        EfficiencyResult::BAD,
        EfficiencyResult::REGEX_ANCHOR)
    end

    if regex.casefold? then
      res << EfficiencyResult.new(
        'Case insensitive queries are inefficient. Consider keeping ' +
        "a lowercase copy of field '#{field}' in your documents.",
        EfficiencyResult::BAD,
        EfficiencyResult::REGEX_CASE)
    end

    ['.*', '.*$'].each do |bad_end|
      if regex.source.end_with? bad_end then
        res << EfficiencyResult.new(
          "Do you really need #{bad_end} at the end of your regex? "+
          'It slows down the queries.',
          EfficiencyResult::BAD,
          EfficiencyResult::REGEX_BAD_END)
      end
    end

    return res
  end

  def handle_size(field, operator_arg)
    [
      EfficiencyResult.new(
        'Queries cannot use indexes for $size portion of a query. ' +
        'Consider keeping a separate field holding the array size ' +
        'and creating an index on it.',
        EfficiencyResult::WARNING,
        EfficiencyResult::SIZE)
    ]
  end

  def empty_handle(field, operator_arg)
    []
  end
  # ====================Indexes suggestion======================

  RANGE_OPERATORS = %w{ $all $not $in $ne $nin $lt $lte $gt $gte }


  EQUAL_TYPE = 0
  SORT_TYPE = 1
  RANGE_TYPE = 2
  UNSUPPORTED_TYPE = 3

  # classify fields into four types
  # EQUAL_TYPE: e.g. "A" => "10"
  # SORT_TYPE: e.g. "orderby" => { "C" => 1.0 }
  # RANGE_TYPE: #e.g. "A" => {"$gt" : 13, "$lt" : 27}
  # UNSUPPORTED_TYPE: e.g. {"A" => { "$regex" => "acme.*corp.*$", "$options" => 'i' } }
  def classify_field!(query_hash, classified_fields)
    traverse_query query_hash do |type, key, val|
      case type
      when :multiple_queries_operator
        # e.g "$or" => [{ "A" => { "$gt" => 25.0 } }, { "b" => { "$in" => [ 1.0, 2.0, 3.0, 4.0 ] } }]
        classified_fields[UNSUPPORTED_TYPE] << key
        val.each { |sub| classify_field!(sub, classified_fields) }
      when :field_query
        #e.g. "A" => {"$gt" : 13, "$lt" : 27}
        support = true
        val.each do |op, _|
          support = false unless RANGE_OPERATORS.include? op
        end
        if support
          classified_fields[RANGE_TYPE] << key
        else
          classified_fields[UNSUPPORTED_TYPE] << key
        end
      when :field_equality
        #e.g. "A" => "10"
        classified_fields[EQUAL_TYPE] << key
      end
    end
  end

  def check_for_indexes(query_hash, sort_hash, namespace)
    #classified_fields[FieldType][FieldName]
    classified_fields = Array.new(4) {[]}
    recommendation = []

    classify_field! query_hash, classified_fields

    sort_hash.each do |key, val|
        classified_fields[SORT_TYPE] << key
    end

    # index sequence : 1.equality tests 2.sort fields 3.range filters
    # http://java.dzone.com/articles/optimizing-mongodb-compound?mz=36885-nosql
    [EQUAL_TYPE, SORT_TYPE, RANGE_TYPE].each do |i|
      classified_fields[i].each do |field|
        # if the field has not been added yet
        if recommendation.index(field) == nil
          recommendation << field
        end
      end
    end

    if recommendation.size == 0
      return []
    end

    if not needs_recommendation?(classified_fields, recommendation, namespace)
      return []
    end

    index = recommendation.map {|x| [x, Mongo::ASCENDING]}
    if classified_fields[UNSUPPORTED_TYPE].size == 0
      return [IndexResult.new(index, IndexResult::GOOD)]
    else
      return [IndexResult.new(index, IndexResult::OPTIONAL)]
    end
  end

  # Evaluate existing indexes against query. Similar to Dex(https://github.com/mongolab/dex).
  # The query is evaluated against each index according two criteria:
  # -Coverage (none, partial, full)
  #  a less granular description of fields covered.
  #  None corresponds to Fields Covered 0 and indicates the index is not used by the query.
  #  Full means the number of fields covered is equal to the number of fields in the query.
  #  Partial describes any value of fields covered value between None and Full.
  # -Order (ideal or not)
  #  describes whether the index is partially-ordered according to ideal index order: Equivalence > Sort > Range
  def generate_index_report(index, classified_fields, recommendation)
    max_equal_cnt = classified_fields[EQUAL_TYPE].length
    max_sort_cnt = max_equal_cnt + classified_fields[SORT_TYPE].length
    max_range_cnt = max_sort_cnt + classified_fields[RANGE_TYPE].length
    coverage = 'none'
    supported = true
    ideal_order = true
    query_fields_covered = 0

    index.each do |field_name,val|
      if val == '2d'
        supported = false if recommendation.include? field_name
        break
      end
      if !(recommendation.include? field_name)
        break
      end
      if query_fields_covered == 0
        coverage = 'partial'
      end
      if query_fields_covered < max_equal_cnt
        ideal_order = false if !(classified_fields[EQUAL_TYPE].include? field_name)
      elsif query_fields_covered < max_sort_cnt
        ideal_order = false if !(classified_fields[SORT_TYPE].include? field_name)
      elsif query_fields_covered < max_range_cnt
        ideal_order = false if !(classified_fields[RANGE_TYPE].include? field_name)
      end
      query_fields_covered += 1
    end
    coverage = 'full' if query_fields_covered == max_range_cnt
    return {'coverage' => coverage, 'ideal_order' => ideal_order, 'supported'=> supported}
  end

  # Return false if the existing indexes is full coverage and in ideal order OR unsupported
  # otherwise return true.
  def needs_recommendation?(classified_fields, recommendation, namespace)
    indexes = get_index_information(namespace)
    need = true
    if indexes != nil
      indexes.each do |_,index|
        index_report = generate_index_report(index['key'], classified_fields, recommendation)
        need = false if (!index_report['supported'] ||
          (index_report['coverage'] == 'full' && index_report['ideal_order']))
      end
    end
    return need
  end
  # ============================================================

  OPERATOR_HANDLERS_DISPATCH = {
    "_equality_check" => :empty_handle,

    # http://docs.mongodb.org/manual/reference/operators/

    # comparison
    "$all" => :handle_all,
    "$in" => :handle_in,
    "$ne" => :handle_negation,
    "$nin" => :handle_negation,
    # we should not check for indexes here, the other method does that:
    "$lt" => :empty_handle,
    "$lte" => :empty_handle,
    "$gt" => :empty_handle,
    "$gte" => :empty_handle,

    # logical
    "$and" => :handle_multiple,
    "$or" => :handle_multiple,
    "$nor" => :handle_nor,
    "$not" => :handle_not,

    # element
    "$exists" => :empty_handle, #TODO
    "$mod" => :empty_handle, #TODO
    "$type" => :empty_handle, #TODO

    # javascript
    "$regex" =>  :handle_regex,
    "$where" => :handle_where,

    # geospatial
    #
    # All the geospatial queries operate on a geospatial index, so they
    # should be efficient.
    "$box" => :empty_handle,
    "$near" => :empty_handle,
    "$within" => :empty_handle,
    "$nearSphere" => :empty_handle,
    "$centerSphere" => :empty_handle,
    "$center" => :empty_handle,
    "$maxDistance" => :empty_handle,
    "$polygon" => :empty_handle,
    "$uniqueDocs" => :empty_handle,

    # array
    "$elemMatch" => :empty_handle, #TODO
    "$size" => :handle_size,
  }

  # This method prepares the hash argument, so that it can be
  # handled by handle_regex method. Specifically, it changes
  # { "$regex" => "^acme.*corp", "$options" => 'i'}
  # to
  # { "$regex" => "/^acme.*corp/i" }
  #
  # if hash argument contains neither '$regex' nor '$options' field,
  # then hash remains unchanged
  def normalize_regexes hash
    options = nil
    if hash.has_key? '$options' then
      #assert that we have a 'regex' operator
      if not hash.has_key? '$regex' then
        raise '$options operator provided, but $regex not present.'
      end

      options = hash['$options']
      hash.delete('$options')
    end

    if hash.has_key? '$regex' then
      regex = "/#{hash['$regex']}/#{options}"
      hash['$regex'] = regex
    end
  end

  # handles operators for a single field, eg
  # {"$in" => [1.0, 2.0, 3.0], "$lt" => 12}
  # @param field specifies the field in the collection
  def handle_single_field(field, operators_hash)
    res = []

    normalize_regexes operators_hash

    operators_hash.each do |operator_str, val|
      method_symbol = OPERATOR_HANDLERS_DISPATCH[operator_str]
      if method_symbol.nil?
        raise "Unknown operator: '#{operator_str}'."
      end
      res += method( method_symbol ).call field, val
    end
    return res
  end

  # checks if a hash contains keys that start with a '$'
  def has_operators hash
    operators_count = 0

    hash.each do |key, val|
      if key.start_with? '$'
        operators_count += 1
      end
    end

    #XXX - what if operators_count is different than 0 and hash.size

    return operators_count > 0
  end

  # This method iterates through all query elements and yields
  # each (key, val) pair along with a symbol designating the pair's meaning.
  # This method is NOT recursive.
  def traverse_query (query_hash)
    query_hash.each do |key, val|
      if key.start_with? '$' then
        #e.g. $or => [query1, query2, ...]
        yield :multiple_queries_operator, key, val
      elsif (val.is_a? Hash) and (has_operators val)
        #e.g. "A" => {"$gt" : 13, "$lt" : 27}
        yield :field_query, key, val
      else
        #e.g. "A" => { "sub1" : 10, "sub2" : 30 }
        yield :field_equality, key, val
      end
    end
  end

  def analyze_query(query_hash)
    out = []
    traverse_query query_hash do |type, key, val|
      field = nil
      operator_hash = nil

      case type
      when :multiple_queries_operator
        operator_hash = { key => val }
      when :field_query
        field = key
        operator_hash = val
      when :field_equality
        field = key
        operator_hash = { "_equality_check" => nil }
      end
      out += handle_single_field field, operator_hash
    end
    return out
  end

end #class Evaluator
