require 'test_helper'
require "json"
require "securerandom"

ServiceAccountFilesPath = File.expand_path("../data/service_account.json", __FILE__)

class KuraIntegrationTest < Test::Unit::TestCase
  def setup
    service_account = JSON.parse(File.binread(ServiceAccountFilesPath))
    @project_id = service_account["project_id"]

    @client = Kura.client(service_account)

    # for reduce power_assert display
    def @client.inspect
      super[0, 15] + "...>"
    end
  end

  def test_dataset
    @name = "Kura_test"

    dataset = @client.dataset(@name)
    assert_nil(dataset)

    @client.insert_dataset(@name)
    dataset = @client.dataset(@name)
    assert_equal(@project_id, dataset.dataset_reference.project_id)
    assert_equal(@name, dataset.dataset_reference.dataset_id)

    power_assert do
      @client.datasets.map(&:id).include?("#{@project_id}:#{@name}")
    end

    access = @client.dataset(@name).access.map(&:to_h)
    access << {
      role: "READER",
      domain: "groovenauts.jp",
    }
    @client.patch_dataset(@name, access: access, description: "Description#1", default_table_expiration_ms: 3_600_000, friendly_name: "FriendlyName#1")
    @client.dataset(@name).tap do |d|
      assert_equal(access, d.access.map(&:to_h))
      assert_equal("Description#1", d.description)
      assert_equal("FriendlyName#1", d.friendly_name)
      assert_equal(3_600_000, d.default_table_expiration_ms.to_i)
    end

    @client.delete_dataset(@name)
    dataset = @client.dataset(@name)
    assert_nil(dataset)

    err = assert_raise(Kura::ApiError) { @client.datasets(project_id: "invalid-project-000") }
    assert_equal("notFound", err.reason)
    assert_match(/invalid-project-000/, err.message)

    err = assert_raise(Kura::ApiError) { @client.dataset("invalid:dataset") }
    assert_equal("invalid", err.reason)
    assert_match(/invalid:dataset/, err.message)

    err = assert_raise(Kura::ApiError) { @client.insert_dataset("invalid:dataset") }
    assert_equal("invalid", err.reason)
    assert_match(/invalid:dataset/, err.message)

    err = assert_raise(Kura::ApiError) { @client.delete_dataset("invalid:dataset") }
    assert_equal("invalid", err.reason)
    assert_match(/invalid:dataset/, err.message)

    err = assert_raise(Kura::ApiError) { @client.patch_dataset("invalid:dataset", description: "dummy") }
    assert_equal("invalid", err.reason)
    assert_match(/invalid:dataset/, err.message)
  ensure
    @client.delete_dataset(@name) rescue nil
  end

  def test_tables
    @client.tables("samples", project_id: "publicdata").tap do |result|
      assert_equal(7, result.size)
      assert_equal([
        "publicdata:samples.github_nested",
        "publicdata:samples.github_timeline",
        "publicdata:samples.gsod",
        "publicdata:samples.natality",
        "publicdata:samples.shakespeare",
        "publicdata:samples.trigrams",
        "publicdata:samples.wikipedia",
      ], result.map(&:id).sort)
    end

    err = assert_raise(Kura::ApiError) do
      @client.tables("nonexist")
    end
    assert_equal("notFound", err.reason)
    assert_match(/nonexist/, err.message)
  end

  def test_table
    assert_nil(@client.table("_dummy", "nonexist"))
    @client.table("samples", "github_timeline", project_id: "publicdata").tap do |tbl|
      assert_equal(tbl.table_reference.project_id, "publicdata")
      assert_equal(tbl.table_reference.dataset_id, "samples")
      assert_equal(tbl.table_reference.table_id, "github_timeline")
      assert_equal("TABLE", tbl.type)
    end

    err = assert_raise(Kura::ApiError) do
      @client.table("invalid:dataset", "table")
    end
    assert_equal("invalid", err.reason)
    assert_match(/invalid:dataset/, err.message)
  end

  def test_insert_table
    dataset = "_Kura_test"
    table = "insert_table"
    unless @client.dataset(dataset)
      @client.insert_dataset(dataset)
    end
    power_assert do
      @client.insert_table(dataset, table, schema: [{name: "n", type: "INTEGER", mode: "NULLABLE"}], friendly_name: "friend", description: "enemy")
    end
    t = @client.table(dataset, table)
    power_assert do
      t.table_reference.dataset_id == dataset
    end
    power_assert do
      t.table_reference.table_id == table
    end
    power_assert do
      t.friendly_name == "friend"
    end
    power_assert do
      t.description == "enemy"
    end
    power_assert do
      t.type == "TABLE"
    end
  ensure
    @client.delete_dataset(dataset, delete_contents: true)
  end

  def test_insert_table_view
    dataset = "_Kura_test"
    table = "insert_table"
    unless @client.dataset(dataset)
      @client.insert_dataset(dataset)
    end
    query = "SELECT COUNT(*) FROM [publicdata:samples.wikipedia];"
    power_assert do
      @client.insert_table(dataset, table, query: query)
    end
    t = @client.table(dataset, table)
    power_assert do
      t.table_reference.dataset_id == dataset
    end
    power_assert do
      t.table_reference.table_id == table
    end
    power_assert do
      t.view.query == query
    end
    power_assert do
      t.type == "VIEW"
    end
  ensure
    @client.delete_dataset(dataset, delete_contents: true)
  end

  def test_patch_table
    dataset = "_Kura_test"
    table = "patch_table"
    unless @client.dataset(dataset)
      @client.insert_dataset(dataset)
    end
    @client.insert_table(dataset, table)
    expiration = (Time.now + 3600).to_f
    expiration_ms = (expiration * 1000).to_i
    power_assert do
      @client.patch_table(dataset, table, friendly_name: "friend", description: "enemy", expiration_time: expiration)
    end
    t = @client.table(dataset, table)
    power_assert do
      t.friendly_name == "friend"
    end
    power_assert do
      t.description == "enemy"
    end
    power_assert do
      t.expiration_time.to_i == expiration_ms
    end
    power_assert do
      @client.patch_table(dataset, table, friendly_name: nil ,description: nil, expiration_time: nil)
    end
    t = @client.table(dataset, table)
    power_assert do
      t.friendly_name == nil
    end
    power_assert do
      t.description == nil
    end
    power_assert do
      t.expiration_time == nil
    end
  ensure
    @client.delete_dataset(dataset, delete_contents: true)
  end

  def test_delete_table
    assert_nil(@client.delete_table("_dummy", "nonexist"))
    err = assert_raise(Kura::ApiError) do
      @client.delete_table("invalid:dataset", "nonexist")
    end
    assert_equal("invalid", err.reason)
    assert_match(/invalid:dataset/, err.message)
  end

  def test_list_tabledata_with_invalid_dataset
    err = assert_raise(Kura::ApiError) { @client.list_tabledata("invalid:dataset", "nonexist", schema: [{"name": "f1"}]) }
    # 2016-03-02: Currently BigQuery API tabledata.list behavior changed to return notFound for invalid dataset id
    # assert_equal("invalid", err.reason)
    assert_equal("notFound", err.reason)
    assert_match(/invalid:dataset/, err.message)
  end

  def test_list_tabledata_with_empty_table
    dataset = "_Kura_test"
    table = "empty"
    unless @client.dataset(dataset)
      @client.insert_dataset(dataset)
    end
    @client.insert_table(dataset, table, schema: [{name: "a", type: "STRING", mode: "NULLABLE"}])
    power_assert do
      @client.list_tabledata(dataset, table) == { total_rows: 0, next_token: nil, rows: [] }
    end
  ensure
    @client.delete_dataset(dataset, delete_contents: true)
  end

  def test_insert_tabledata
    dataset = "_Kura_test"
    table = "insert_table"
    unless @client.dataset(dataset)
      @client.insert_dataset(dataset)
    end
    @client.insert_table(dataset, table, schema: [{name: "n", type: "INTEGER", mode: "NULLABLE"}, {name: "s", type: "STRING", mode: "NULLABLE"}])

    @client.insert_tabledata(dataset, table, [{n: 42, s: "Hello, World!"}])
    sleep 5
    job = @client.query("SELECT * from [#{dataset}.#{table}] LIMIT 100", allow_large_results: false, priority: "INTERACTIVE", wait: 100)
    dest = job.configuration.query.destination_table
    power_assert do
      @client.list_tabledata(dest.dataset_id, dest.table_id) == { total_rows: 1, next_token: nil, rows: [{"n" => "42", "s" => "Hello, World!"}] }
    end
  ensure
    @client.delete_dataset(dataset, delete_contents: true)
  end

  def test_query_with_invalid_dataset
    err = assert_raise(Kura::ApiError) { @client.query("INVALID SQL", dataset_id: "invalid:dataset", table_id: "dummy") }
    assert_equal("invalid", err.reason)
    assert_match(/invalid:dataset/, err.message)
  end

  def test_query_and_tabledata
    dataset = "_Kura_test"
    table = "Kura_query_result1"
    unless @client.dataset(dataset)
      @client.insert_dataset(dataset)
    end

    job_id = SecureRandom.uuid
    job = nil
    assert_nothing_raised do
      job = @client.query("SELECT count(*) FROM [publicdata:samples.wikipedia]", dataset_id: dataset, table_id: table, job_id: job_id, wait: 60)
    end
    power_assert do
      job.job_reference.job_id == job_id
    end

    assert_equal({next_token: nil, rows: [{"f0_"=>"313797035"}], total_rows: 1}, @client.list_tabledata(dataset, table))
    @client.delete_table(dataset, table)
  ensure
    @client.delete_dataset(dataset, delete_contents: true)
  end

  def test_query_with_user_defined_function
    dataset = "_Kura_test"
    table = "Kura_query_result_udf"
    unless @client.dataset(dataset)
      @client.insert_dataset(dataset)
    end

    q = "SELECT name, domain FROM extractUser((SELECT 'my@example.com' as email));"
    udf = <<-EOF
      function extract(row, emit) {
        emit({name: row.email.split("@")[0], domain: row.email.split("@")[1]});
      }
      bigquery.defineFunction("extractUser", ["email"], [{name: "name", type: "string"},{name: "domain", type: "string"}], extract);
    EOF

    assert_nothing_raised do
      @client.query(q, dataset_id: dataset, table_id: table, user_defined_function_resources: [udf], wait: 60)
    end

    assert_equal({next_token: nil, rows: [{"name"=>"my","domain"=>"example.com"}], total_rows: 1}, @client.list_tabledata(dataset, table))
    @client.delete_table(dataset, table)
  ensure
    @client.delete_dataset(dataset, delete_contents: true)
  end

  def test_query_with_dry_run
    dataset = "_Kura_test"
    table = "Kura_query_dry_run"
    unless @client.dataset(dataset)
      @client.insert_dataset(dataset)
    end

    q = "SELECT title FROM [publicdata:samples.wikipedia];"

    job = nil
    assert_nothing_raised do
      job = @client.query(q, dataset_id: dataset, table_id: table, dry_run: true)
    end

    assert_nil(@client.table(dataset, table))
    power_assert do
      job.statistics.query.total_bytes_billed.to_i == 0
    end
    power_assert do
      job.statistics.query.total_bytes_processed.to_i > 0
    end
  ensure
    @client.delete_dataset(dataset, delete_contents: true)
  end

  def test_media_upload
    dataset = "_Kura_test"
    table = "Kura_upload_test1"
    unless @client.dataset(dataset)
      @client.insert_dataset(dataset)
    end

    schema = [
      { name: "f1", type: "STRING", mode: "NULLABLE" },
      { name: "f2", type: "STRING", mode: "NULLABLE" },
    ]
    io = StringIO.new(<<-EOC.gsub(/^\s+/, ""))
      aaa,bbb
      ccc,ddd
    EOC
    job_id = SecureRandom.uuid
    job = nil
    assert_nothing_raised do
      job = @client.load(dataset, table, schema: schema, file: io, mode: :truncate, job_id: job_id)
      job.wait(300)
    end
    power_assert do
      job.job_reference.job_id == job_id
    end
    power_assert do
      "#{@project_id}:#{dataset}.#{table}" == @client.table(dataset, table).id
    end
    power_assert do
      @client.list_tabledata(dataset, table) == {total_rows: 2, next_token: nil, rows: [{"f1" => "aaa", "f2" => "bbb"},{"f1" => "ccc", "f2" => "ddd"}]}
    end
  ensure
    @client.delete_dataset(dataset, delete_contents: true)
  end

  default_expected = [{"f1"=>"aaa", "f2"=>"bbb"}]
  data({
    field_delimiter: [ "aaa!bbb\n", {field_delimiter: "!"}, default_expected ],
    allow_jagged_rows: [ "aaa\n", {allow_jagged_rows: true}, [{"f1"=>"aaa","f2"=>nil}] ],
    max_bad_records: [ "xxx\naaa,bbb\n", {max_bad_records: 1}, default_expected ],
    ignore_unknown_values: ["aaa,bbb,ccc\n", {ignore_unknown_values: true}, default_expected ],
    allow_quoted_newlines: [%{"aaa\naaa",bbb}, {allow_quoted_newlines: true}, [{"f1"=>"aaa\naaa", "f2"=>"bbb"}] ],
    skip_leading_rows: ["xxx,yyy\naaa,bbb\n", {skip_leading_rows: 1}, default_expected ],
    source_format: [default_expected.first.to_json+"\n", {source_format: "NEWLINE_DELIMITED_JSON"}, default_expected],
  })
  def test_load_parameters(data)
    csv, options, expected = data
    dataset = "_Kura_test"
    table = "Kura_load_parameter_#{options.keys.join("_")}_test"
    schema = [
      { name: "f1", type: "STRING", mode: "NULLABLE" },
      { name: "f2", type: "STRING", mode: "NULLABLE" },
    ]
    unless @client.dataset(dataset)
      @client.insert_dataset(dataset)
    end
    assert_nothing_raised do
      @client.load(dataset, table, schema: schema, file: StringIO.new(csv), **options, wait: 300)
    end
    power_assert do
      @client.list_tabledata(dataset, table) == {total_rows: expected.size, next_token: nil, rows: expected}
    end
  ensure
    @client.delete_dataset(dataset, delete_contents: true)
  end

  def test_cancel_job
    jobid = @client.query("SELECT COUNT(*) FROM publicdata:samples.wikipedia", allow_large_results: false, priority: "BATCH")
    job = @client.cancel_job(jobid)
    power_assert do
      # Sometimes jobs.cancel return "PENDING" job.
      job.status.state == "DONE" or job.status.state == "PENDING"
    end
    assert_raise
    err = assert_raise(Kura::ApiError) { @client.wait_job(jobid) }
    power_assert do
      err.reason == "stopped" and
      err.message =~ /Job cancel was requested./
    end
  end

  def test_batch_call
    @client.batch do
      @client.tables("samples", project_id: "publicdata") do |result, err|
        assert_nil(err)
        assert_equal(7, result.size)
        assert_equal([
          "publicdata:samples.github_nested",
          "publicdata:samples.github_timeline",
          "publicdata:samples.gsod",
          "publicdata:samples.natality",
          "publicdata:samples.shakespeare",
          "publicdata:samples.trigrams",
          "publicdata:samples.wikipedia",
        ], result.map(&:id).sort)
      end
      @client.table("samples", "github_timeline", project_id: "publicdata") do |tbl, err|
        assert_nil(err)
        assert_equal(tbl.table_reference.project_id, "publicdata")
        assert_equal(tbl.table_reference.dataset_id, "samples")
        assert_equal(tbl.table_reference.table_id, "github_timeline")
        assert_equal("TABLE", tbl.type)
      end
    end
    @client.batch do
      @client.dataset("nodataset") do |result, err|
        assert_nil(err)
        assert_nil(result)
      end
      @client.table("nodataset", "notable") do |result, err|
        assert_nil(err)
        assert_nil(result)
      end
    end
  end

  def test_batch_job_insert
    jobs = []
    @client.batch do
      @client.query("SELECT 0 as a", allow_large_results: false) do |job, err|
        jobs << job
        assert_nil(err)
      end
      @client.query("SELECT 1 as b", allow_large_results: false) do |job, err|
        jobs << job
        assert_nil(err)
      end
    end
    jobs.map! do |j|
      j = j.wait(120)
    end
    assert_equal(@client.list_tabledata(jobs[0].configuration.query.destination_table.dataset_id, jobs[0].configuration.query.destination_table.table_id), { total_rows: 1, next_token: nil, rows: [{ "a" => "0" }] })
    assert_equal(@client.list_tabledata(jobs[1].configuration.query.destination_table.dataset_id, jobs[1].configuration.query.destination_table.table_id), { total_rows: 1, next_token: nil, rows: [{ "b" => "1" }] })
  end
end if File.readable?(ServiceAccountFilesPath)
