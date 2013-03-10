require 'spec_helper'

describe Evaluator do
  let(:evaluator) {
    Evaluator.new 'localhost', 27017
  }

  let(:test_coll_name) {
    "indexTest"
  }

  let(:test_coll_namespace) {
    MongoMapper.database.full_collection_name(test_coll_name)
  }

  let(:test_coll) {
    MongoMapper.database.collection(test_coll_name)
  }

  def ensureIndexQuality(query, sort_hash, index)
    #convert sort_hash into an array accepted by the Ruby driver
    sort_by = []
    sort_hash.each do |field, val|
      sort_by.append([field, val>0 ? Mongo::ASCENDING : Mongo::DESCENDING])
    end

    # performance statistics without the index
    before = test_coll.find(query).sort(sort_by).explain

    test_coll.ensure_index(index)
    index_hash = {}
    index.each { |a,b| index_hash[a] = b }
    # performance statistics with the index
    after = test_coll.find(query, :hint => index_hash).sort(sort_by).explain

    if sort_hash.size > 0
      # The server does not need to sort the outcome.
      expect(after['scanAndOrder']).to eq(nil)
    else
      # This assertion makes sure that the testcase is of good quality.
      expect(before['nscanned']).to be > before['n']
      # The number of scanned objects is improved.
      expect(after['nscanned']).to eq(after['n'])
    end

    # These statistics are useful during development.
    # I'm commenting it out to keep the rspec test suite silent. If you want to
    # uncomment it, I recommend running rspec with '--format documentation'
    #
    # printf "%20s: %s\n", "query", query
    # printf "%20s: %s\n", "sort_hash", sort_hash
    # printf "%20s: %s\n", "index", index
    # interesting = %w{nscanned nscannedObjects n indexOnly scanAndOrder cursor}
    # interesting.each do |key|
    #   printf "%20s: %8s -> %8s\n", key, before[key], after[key]
    # end
  end

  # populate database
  before :each do
    # insert some data
    names = ['Apple', 'Orange']
    artists = ['Sting', 'Frank Zappa']
    durations = [40,50,60,70]
    prices = [10,20,30]
    ratings = [6,7,8]
    c = 0

    entries = names.product(artists, durations, prices, ratings)

    entries.each do |name, artist, duration, price, rating|
      test_coll.insert({
        'name' => name,
        'artist' => artist,
        'duration' => duration,
        'price' => price,
        'rating' => rating,
        'C' => c
      })
      c += 1
    end
    test_coll.insert({ "location" => { "x" => -10, "y" => 10 } })

    # create indexes
    test_coll.ensure_index([
      ['duration', Mongo::ASCENDING],
      ['name', Mongo::ASCENDING]
    ])
    test_coll.ensure_index([
      ['duration', Mongo::ASCENDING],
      ['rating', Mongo::ASCENDING],
      ['price', Mongo::ASCENDING]
    ])
    test_coll.create_index([['location', Mongo::GEO2D]])
  end

  # clean up collection and indexes
  after :each do
    MongoMapper.database.drop_collection(test_coll_name)
  end

  def perform_query(query, expected_outcome)
    result = evaluator.evaluate_query(query, :suggest_indexes => false)
    result.map! {|er| [er.code, er.level]}
    expect(result.sort).to eq(expected_outcome.sort)
  end

  context "Given a query to evaluate:" do

    it "Parses basic equality queries." do
      perform_query(
        {
          'field1' => {
            'sub1' => 3,
            'sub2' => 'string_val',
          },
          'field2' => 99,
        },
        []
      )
    end

    it "Reports usage of $in with a large array." do
      perform_query(
        {
          'field1' => {'$gt' => 20 },
          'field2' => {'$in' => [1]*10000},
        },
        [[EfficiencyResult::IN, EfficiencyResult::CRITICAL]]
      )
    end

    it "Reports usage of $nin." do
      perform_query(
        {
          'field1' => {'$nin' => [1,2,3]},
        },
        [[EfficiencyResult::NEGATION, EfficiencyResult::CRITICAL]]
      )
    end

    it "Reports usage of $ne." do
      perform_query(
        {
          'field1' => {'$ne' => 'orange' }
        },
        [[EfficiencyResult::NEGATION, EfficiencyResult::CRITICAL]]
      )
    end

    it "Parses comparison operators." do
      perform_query(
        {
          'field1' => {'$lt' => 1},
          'field2' => {'$lte' => 2},
          'field3' => {'$gt' => {'sub1' => 2, 'sub2' => 'string' } },
          'field4' => {'$gte' => 4},
        },
        []
      )
    end

    it "Reports usage of $all." do
      perform_query(
        {
          'field1' => {'$all' => [1,2,3,4]},
        },
        [[EfficiencyResult::ALL, EfficiencyResult::CRITICAL]]
      )
    end

    it "Parses compound queries ($or, $and)." do
      for op in ['$or', '$and'] do
        perform_query(
          {
            op => [
              {'field1' => 2.15},
              {'field2' => 'red'},
              {'field3' => { '$ne' => 15 }},
              {'field4' => { 'sub1' => 1, 'sub2' => 2 }},
            ]
          },
          [[EfficiencyResult::NEGATION, EfficiencyResult::CRITICAL]]
        )
      end
    end

    it "Reports usage of $not." do
      perform_query(
        {
          'field1' => { '$not' => { '$in' => [1,2,3]*10000 } }
        },
        [[EfficiencyResult::NOT, EfficiencyResult::CRITICAL],
        [EfficiencyResult::IN, EfficiencyResult::CRITICAL]]
      )
    end

    it "Reports usage of $nor and recurses into subqueries." do
      perform_query(
        {
          '$nor' => [
            {'field1' => 2.15},
            {'field2' => 'red'},
            {'field3' => { '$ne' => 15 }},
            {'field4' => { 'sub1' => 1, 'sub2' => 2 }},
          ]
        },
        [[EfficiencyResult::NOR, EfficiencyResult::CRITICAL],
        [EfficiencyResult::NEGATION, EfficiencyResult::CRITICAL]]
      )
    end

    it "Reports inefficient regexes." do
      perform_query(
        {
          "A" => { "$regex" => "^acme.*corp", "$options" => 'i'},
        },
        [[EfficiencyResult::REGEX_CASE, EfficiencyResult::BAD]]
      )

      perform_query(
        {
          "A" => { "$regex" => "acme.*corp" },
        },
        [[EfficiencyResult::REGEX_ANCHOR, EfficiencyResult::BAD]]
      )

      perform_query(
        {
          "A" => { "$regex" => "^acme.*corp.*$" },
        },
        [[EfficiencyResult::REGEX_BAD_END, EfficiencyResult::BAD]]
      )

      perform_query(
        {
          "A" => { "$regex" => "acme.*corp.*", "$options" => 'i'},
        },
        [[EfficiencyResult::REGEX_CASE, EfficiencyResult::BAD],
        [EfficiencyResult::REGEX_BAD_END, EfficiencyResult::BAD],
        [EfficiencyResult::REGEX_ANCHOR, EfficiencyResult::BAD]]
      )
    end

    it "Reports usage of $size." do
      perform_query(
        { "field" => { "$size" => 1 } },
        [[EfficiencyResult::SIZE, EfficiencyResult::WARNING]]
      )
    end

    it "Reports usage of $where." do
      perform_query(
        {
          '$where' => 'this.credits == this.debits'
        },
        [[EfficiencyResult::WHERE, EfficiencyResult::CRITICAL]]
      )
    end

    it "Raises RuntimeError when an unknown operator is encountered." do
      query = {
        'A' => {'$brighter_than'=> '#AAFFCC'}
      }
      expect {
        evaluator.evaluate_query(query, :suggest_indexes => false)
      }.to raise_error(RuntimeError)
    end

    it "Parses geospatial queries." do
      queries = [
        { "loc" => { "$within" => { "$box" => [ [0,0], [100,100] ] } } },
        { "loc" => { "$near"=> [100,100] } },
        { "loc" => { "$nearSphere" => [0,0] } },
        { "loc" => { "$within" => { "$centerSphere" => [ [88,30], 10 / 3959 ] } } },
        { "loc" => { "$within" => { "$center" => [ [0,0], 10 ] } } },
        { "loc" => { "$near" => [100,100], "$maxDistance" => 10 } },
        { "loc" => { "$within" => { "$polygon" => [ [0,0], [3,6], [6,0]  ] } } },
        { "address.loc" => { "$within" => { "$box" => [ [0,0], [100,100] ], "$uniqueDocs" => true } } },
      ]
      queries.each do |query|
        perform_query(query, [])
      end
    end

  end # context


  context "When asked to suggest an index:" do

    it "Suggests indexes with optimal order of fields." do
      query = {
        "duration" => { "$in" => [60,70,75,85]},
        "price" => { "$gt" => 27.3}
      }
      sort_hash = { "C" => 1.0 }
      result =  evaluator.evaluate_query(query, :sort_hash => sort_hash)

      expect(result.length).to be >= 1
      expect(result[0].raw_index).to \
        eq("{ 'C': 1, 'duration': 1, 'price': 1 }")
      expect(result[0].level).to eq(IndexResult::GOOD)

      ensureIndexQuality(query, sort_hash, result[0].index)


      # example given by
      # http://java.dzone.com/articles/optimizing-mongodb-compound?mz=36885-nosql
      query = {
        "price" => { "$gte" => 14, "$lte" => 34 },
        "name" => "Orange"
      }
      sort_hash = { "rating" => -1.0 }
      result =  evaluator.evaluate_query(query, :sort_hash => sort_hash)

      expect(result.length).to be >= 1
      expect(result[0].raw_index).to \
        eq ("{ 'name': 1, 'rating': -1, 'price': 1 }")
      expect(result[0].level).to eq(IndexResult::GOOD)

      ensureIndexQuality(query, sort_hash, result[0].index)


      query = {
        '$and' => [
          {'artist' => 'Sting'},
          {'duration' => 50},
          {'price' => { '$gt' => 20 }},
          {'rating' => 6},
        ]
      }
      result = evaluator.evaluate_query(query)

      expect(result.length).to be >= 1
      expect(result[0].raw_index).to \
        eq("{ 'artist': 1, 'duration': 1, 'rating': 1, 'price': 1 }")
      expect(result[0].level).to eq(IndexResult::GOOD)
      ensureIndexQuality(query, {}, result[0].index)
    end

    it "Does not suggest indexes for fields with unsupported operators." do
      query = {
        "name" => { "$regex" => "^acme.*corp.*$" },
        "price" => { "$gt" => 27.3}
      }
      sort_hash = { "C" => 1.0 }
      result = evaluator.evaluate_query(query, :sort_hash => sort_hash)

      expect(result.length).to be >= 1
      expect(result[0].raw_index).to eq("{ 'C': 1, 'price': 1 }")
      expect(result[0].level).to eq(IndexResult::OPTIONAL)
      ensureIndexQuality(query, sort_hash, result[0].index)
    end

    it "Handles equal, range and sort operators." do
      query = { "duration" => 50, "price" => { "$gt" => 27.3, "$lt" => 97.3}}
      sort_hash = { "C" => -1.0 }
      result =  evaluator.evaluate_query(query, :sort_hash => sort_hash)

      expect(result.length).to be >= 1
      expect(result[0].raw_index).to eq("{ 'duration': 1, 'C': -1, 'price': 1 }")
      expect(result[0].level).to eq(IndexResult::GOOD)
      ensureIndexQuality(query, sort_hash, result[0].index)
    end

    it "Suggests a proper index for sorting purposes." do
      query = {}
      sort_hash = { "C" => 1.0 }
      result = evaluator.evaluate_query(query, :sort_hash => sort_hash)

      expect(result.length).to be >= 1
      expect(result[0].raw_index).to eq("{ 'C': 1 }")
      expect(result[0].level).to eq(IndexResult::GOOD)
      ensureIndexQuality(query, sort_hash, result[0].index)
    end

    it "Recommends no index for queries that do not need one." do
      query = {}
      result =  evaluator.evaluate_query(query)
      expect(result).to eq([])

      query = {"location" => { "$near" => [100,100] }}
      result =  evaluator.evaluate_query(query)
      expect(result).to eq([])
    end

    it "Recommends index which is better than existing one(coverage == none)." do
      query = { "artist" => "Sting" }
      result =  evaluator.evaluate_query(query,
        :namespace => test_coll_namespace)

      expect(result.length).to be >= 1
      expect(result[0].raw_index).to eq("{ 'artist': 1 }")
      expect(result[0].level).to eq(IndexResult::GOOD)
      ensureIndexQuality(query, {}, result[0].index)
    end

    it "Recommends index which is better than existing one(coverage == partial)." do
      query = { "artist" => "Frank Zappa", "name" => "Apple" }
      result =  evaluator.evaluate_query(query,
        :namespace => test_coll_namespace)

      expect(result.length).to be >= 1
      expect(result[0].raw_index).to eq("{ 'artist': 1, 'name': 1 }")
      expect(result[0].level).to eq(IndexResult::GOOD)
      ensureIndexQuality(query, {}, result[0].index)


      query = { "duration" => { "$gte" => 50, "$lte" => 60 }, "name" => "Apple" }
      result =  evaluator.evaluate_query(query,
        :namespace => test_coll_namespace)

      expect(result.length).to be >= 1
      expect(result[0].raw_index).to eq("{ 'name': 1, 'duration': 1 }")
      expect(result[0].level).to eq(IndexResult::GOOD)
      ensureIndexQuality(query, {}, result[0].index)
    end

    it "Recommends index which is better than existing one(coverage == full, idealorder == false)." do
      query = { "duration" => { "$gte" => 50, "$lte" => 60 }, "name" => "Orange" }
      result =  evaluator.evaluate_query(query,
        :namespace => test_coll_namespace)
      expect(result.length).to be >= 1
      expect(result[0].raw_index).to eq("{ 'name': 1, 'duration': 1 }")
      expect(result[0].level).to eq(IndexResult::GOOD)

      query = { "duration" => 50, "price" => 20 }
      result =  evaluator.evaluate_query(query,
        :namespace => test_coll_namespace)
      expect(result.length).to be >= 1
      expect(result[0].raw_index).to eq("{ 'duration': 1, 'price': 1 }")
      expect(result[0].level).to eq(IndexResult::GOOD)
      ensureIndexQuality(query, {}, result[0].index)

      query = { "duration" => { "$gte" => 50, "$lte" => 60 }, "price" => 30 }
      sort_hash = { "rating" => 1.0 }
      result =  evaluator.evaluate_query(query,
        :sort_hash => sort_hash,
        :namespace => test_coll_namespace)
      expect(result.length).to be >= 1
      expect(result[0].raw_index).to eq("{ 'price': 1, 'rating': 1, 'duration': 1 }")
      expect(result[0].level).to eq(IndexResult::GOOD)
      ensureIndexQuality(query, sort_hash, result[0].index)
    end

    it "Recommends no index which is equal to existing one." do
      query = { "duration" => 50, "name" => "Orange" }
      result =  evaluator.evaluate_query(query,
                                         :namespace => test_coll_namespace)
      expect(result).to eq([])

      query = { "price" => { "$gte" => 15, "$lte" => 30 }, "duration" => 50 }
      sort_hash = { "rating" => 1.0 }
      result =  evaluator.evaluate_query(
        query,
        :sort_hash => sort_hash,
        :namespace => test_coll_namespace)
      expect(result).to eq([])
    end

    it "Recommends no index which is a prefix of existing one" do
      query = { "duration" => 50}
      sort_hash = { "rating" => 1.0 }

      result =  evaluator.evaluate_query(
        query, :namespace => test_coll_namespace)
      expect(result).to eq([])

      result =  evaluator.evaluate_query(
        query, :sort_hash => sort_hash, :namespace => test_coll_namespace)
      expect(result).to eq([])
    end

    it "Recommends no index which is logically equal to existing one." do
      query = { "name" => "Orange", "duration" => 50}
      result =  evaluator.evaluate_query(
        query, :namespace => test_coll_namespace)
      expect(result).to eq([])
    end

    it "Recommends no index when geospatial indexes are encountered" do
      query = { "location" => [-100, 100] }
      result =  evaluator.evaluate_query(
        query, :namespace => test_coll_namespace)
      expect(result).to eq([])
    end

    it "When evaluating existing indexes, does not require " +
       "'equal and 'sort' fields to be disjoint." do
      query = { "artist" => "Sting", "rating" => 7, "duration" => 60}
      sort_hash = { "artist" => -1, "duration" => -1, "price" => 1 }

      test_coll.ensure_index([
        ['artist', Mongo::DESCENDING],
        ['rating', Mongo::ASCENDING],
        ['duration', Mongo::DESCENDING],
        ['price', Mongo::ASCENDING],
      ])

      result = evaluator.evaluate_query(query,
        :sort_hash => sort_hash,
        :namespace => test_coll_namespace)

      expect(result).to eq([])
    end

    it "Pays attention to the sorting order." do
      query = { "artist" => "Sting", "rating" => 7, "duration" => 60}
      sort_hash = { "artist" => -1, "rating" => 1.0, "duration" => -1.0, "price" => 1.0 }
      result = evaluator.evaluate_query(query,
        :sort_hash => sort_hash,
        :namespace => test_coll_namespace)

      expect(result.length).to be >= 1
      expect(result[0].raw_index).to eq("{ 'artist': -1, 'rating': 1, 'duration': -1, 'price': 1 }")
      expect(result[0].level).to eq(IndexResult::GOOD)
      ensureIndexQuality(query, sort_hash, result[0].index)
    end

  end # context

end
