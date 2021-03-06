require 'spec_helper'
require 'cgi'

$dummy_data = <<EOF
  {
  "responseHeader":{
    "status":0,
    "QTime":58,
    "params":{
      "wt":"json",
      "indent":"true",
      "q":"*:*"}},
  "response":{"numFound":1,"start":0,"docs":[
      {
        "id":"/repositories/2/resources/1",
        "title":"A Resource",
        "type":"resource",
        "suppressed":false}]
  }}
EOF

class MockHTTP

  attr_accessor :request

  def start(host, port, block)
    http = Object.new

    def http.parent=(val)
        @parent = val
    end


    def http.request(req)
      @parent.request = req
      response = Object.new

      def response.body; $dummy_data; end
      def response.code; '200'; end

      response
    end

    http.parent = self

    block.call(http)
  end

end


describe 'Solr model' do

  it "can pass a query to Solr, including params from config" do
    http = MockHTTP.new
    Net::HTTP.stub(:start) { |host, port, &block| http.start(host, port, block) }

    AppConfig[:solr_params] = {
      "bq" => proc { "title:\"#{@query_string}\"*" },
      "pf" => 'title^10',
      "ps" => 0,
    }
    query = Solr::Query.create_keyword_search("hello world").
                        pagination(1, 10).
                        set_repo_id(@repo_id).
                        set_excluded_ids(%w(alpha omega)).
                        set_record_types(['optional_record_type']).
                        highlighting

    response = Solr.search(query)

    http.request.body.should match(/hello\+world/)
    http.request.body.should match(/wt=json/)
    http.request.body.should match(/suppressed%3Afalse/)
    http.request.body.should match(/fq=types%3A%28]?%22optional_record_type/)
    http.request.body.should match(/-id%3A%28%22alpha%22\+OR\+%22omega/)
    http.request.body.should match(/hl=true/)
    http.request.body.should match(/bq=title%3A%22hello\+world%22\*/)
    http.request.body.should match(/pf=title%5E10/)
    http.request.body.should match(/ps=0/)


    response['offset_first'].should eq(1)
    response['offset_last'].should eq(1)

    response['total_hits'].should eq(1)
    response['first_page'].should eq(1)
    response['this_page'].should eq(1)
    response['last_page'].should eq(1)
    response['results'][0]['title'].should eq("A Resource")
  end

  it "adjusts date searches for the local timezone" do
    test_time = Time.parse('2000-01-01')

    advanced_query = {
      "query" => {
        "jsonmodel_type" => "date_field_query",
        "comparator" => "equal",
        "field" => "create_time",
        "value" => test_time.strftime('%Y-%m-%d'),
        "negated" => false
      }
    }

    query = Solr::Query.create_advanced_search(advanced_query)

    CGI.unescape(query.pagination(1, 10).to_solr_url.to_s).should include(test_time.utc.iso8601)
  end


  describe 'Query parsing' do

    let (:canned_query) {
      {"jsonmodel_type"=>"boolean_query",
       "op"=>"AND",
       "subqueries"=>[{"jsonmodel_type"=>"boolean_query",
                       "op"=>"AND",
                       "subqueries"=>[{"field"=>"title",
                                       "value"=>"Hornstein",
                                       "negated"=>true,
                                       "jsonmodel_type"=>"field_query",
                                       "literal"=>false}]},
                      {"jsonmodel_type"=>"boolean_query",
                       "op"=>"AND",
                       "subqueries"=>[{"jsonmodel_type"=>"boolean_query",
                                       "op"=>"AND",
                                       "subqueries"=>[{"field"=>"keyword",
                                                       "value"=>"*",
                                                       "negated"=>false,
                                                       "jsonmodel_type"=>"field_query",
                                                       "literal"=>false}]}]}]}
    }

    it "compensates for purely negative expressions by adding a match-all clause" do
      query_string = Solr::Query.construct_advanced_query_string(canned_query)

      query_string.should eq("((-title:(Hornstein) AND *:*) AND ((fullrecord:(*))))")
    end

  end

end
