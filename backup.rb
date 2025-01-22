#!/usr/bin/env ruby

require 'net/http'
require 'octokit'
require 'rexml/document'
require 'csv'


base_url = "https://s3-us-west-2.amazonaws.com/rubygems-dumps/"
prefix = "production/public_postgresql"

case ARGV[0]
when "list"
  response = Net::HTTP.get_response(URI.parse("#{base_url}?prefix=#{prefix}"))
  document = REXML::Document.new(response.body)
  paths = document.elements.to_a("ListBucketResult/Contents/Key").map do |element|
    element.text
  end

  puts JSON.generate(paths.reverse)
when "download"
  path = ARGV[1]
  system("curl", "--fail", "-o", "public_postgresql.tar", "#{base_url}#{path}", exception: true)
  system("tar", "xf", "public_postgresql.tar", "public_postgresql/databases/PostgreSQL.sql.gz", exception: true)
  system("gunzip", "public_postgresql/databases/PostgreSQL.sql.gz", exception: true)
  system("dropdb", "rubygems")
  system("createdb", "rubygems", exception: true)
  system("psql", "--dbname", "rubygems", "-c", "CREATE EXTENSION IF NOT EXISTS hstore;", exception: true)
  system("psql", "--dbname", "rubygems", "--echo-errors", "--file=public_postgresql/databases/PostgreSQL.sql", exception: true)
  FileUtils.rm_rf("public_postgresql")
when "dump"
  FileUtils.mkdir_p("tables")
  system("psql", "--dbname", "rubygems", "-c", <<~SQL, exception: true)
    CREATE OR REPLACE FUNCTION db_to_csv(path TEXT) RETURNS void AS $$
    declare
      tables RECORD;
      statement TEXT;
    begin
    FOR tables IN
      SELECT (table_schema || '.' || table_name) AS schema_table
      FROM information_schema.tables t INNER JOIN information_schema.schemata s
      ON s.schema_name = t.table_schema
      WHERE t.table_schema NOT IN ('pg_catalog', 'information_schema', 'configuration')
      AND t.table_type NOT IN ('VIEW')
      ORDER BY schema_table
    LOOP
      statement := 'COPY (SELECT * FROM ' || tables.schema_table || ' ORDER BY id asc) TO ''' || path || '/' || tables.schema_table || '.csv' ||''' DELIMITER '','' CSV HEADER';
      EXECUTE statement;
    END LOOP;
    return;
    end;
    $$ LANGUAGE plpgsql;
    SELECT db_to_csv('#{File.expand_path("tables")}');
  SQL
  chunk_sizes = {
    "dependencies" => 250_000,
    "gem_downloads" => 1_000_000,
    "versions" => 50_000,
  }
  Dir["tables/*.csv"].each do |file|
    puts "Splitting #{file}"

    dir = file.split(".")[-2]
    chunk_size = chunk_sizes.fetch(dir, 100_000)
    dir = File.join("tables", dir)
    FileUtils.mkdir_p(dir)

    CSV.open(file, "r") do |csv|
      header = csv.take(1).first
      csv.chunk { |row| row[0].to_i / chunk_size }.each do |index, slice|
        CSV.open("#{dir}/part_#{index}.csv", "w") do |csv|
          csv << header
          slice.each { |row| csv << row }
        end
      end
    end

    FileUtils.rm(file)
  end
when "commit"
  path = ARGV[1]
  system("git", "add", "tables", exception: true)
  date = path.split("/")[-2]
  system("git", "commit", "-m", "Update tables for #{date}", exception: true)
  system("git", "push", exception: true)
  system("git", "tag", date, exception: true)
  system("git", "push", "--tags", exception: true)
  system("gh", "release", "create", date, "public_postgresql.tar", exception: true)
else
  puts "Usage: #{$0} list"
  exit 1
end
