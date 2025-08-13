import sys
from datetime import datetime
from awsglue.utils import getResolvedOptions
from pyspark.sql import SparkSession, functions as F

args = getResolvedOptions(sys.argv, ["input_path", "output_path"])

input_path = args["input_path"]
output_path = args["output_path"]

spark = SparkSession.builder.appName("event-etl-demo").getOrCreate()

# Detect input format by extension; simple demo read
if input_path.endswith(".csv"):
    df = (spark.read
          .option("header", "true")
          .option("inferSchema", "true")  # For demo; prefer explicit schema in prod
          .csv(input_path))
else:
    df = spark.read.json(input_path)

# === Example light transforms ===
# TODO: Replace with your real schema & rules
df = (df
      .withColumn("ingestion_ts", F.current_timestamp())
      .withColumn("ingestion_date", F.to_date(F.current_timestamp()))
     )

# Write as Parquet partitioned by date
(df.write
   .mode("append")
   .partitionBy("ingestion_date")
   .parquet(output_path))

spark.stop()
