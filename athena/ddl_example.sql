-- Create a database (run once)
CREATE DATABASE IF NOT EXISTS event_etl_db;

-- Example external table over processed Parquet
-- Replace <processed-bucket> with the actual name output by Terraform
CREATE EXTERNAL TABLE IF NOT EXISTS event_etl_db.curated_events (
  -- >>> Replace columns below with your real fields <<<
  device_id        string,
  temperature      double,
  humidity         double,
  ingestion_ts     timestamp
)
PARTITIONED BY (ingestion_date date)
STORED AS PARQUET
LOCATION 's3://<processed-bucket>/curated/';

-- After new data lands, load new partitions:
MSCK REPAIR TABLE event_etl_db.curated_events;
