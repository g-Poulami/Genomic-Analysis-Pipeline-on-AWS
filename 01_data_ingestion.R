# =============================================================================
# 01_data_ingestion.R
# Cloud-Native Genomic Analysis Pipeline
# Data Ingestion and Validation Module
# =============================================================================

library(VariantAnnotation)
library(Biostrings)
library(paws)
library(tidyverse)
library(data.table)
library(logger)

# Configure logging
log_appender(appender_file("logs/data_ingestion.log"))
log_threshold(INFO)

# =============================================================================
# Configuration
# =============================================================================

load_config <- function(config_file = "config/pipeline_params.yml") {
  config <- yaml::read_yaml(config_file)
  log_info("Configuration loaded from {config_file}")
  return(config)
}

# =============================================================================
# AWS S3 Helper Functions
# =============================================================================

initialize_s3_client <- function(region = "us-east-1") {
  s3_client <- paws::s3(region = region)
  log_info("S3 client initialized for region: {region}")
  return(s3_client)
}

download_from_s3 <- function(bucket, key, local_path, s3_client) {
  """
  Download file from S3 bucket
  """
  tryCatch({
    log_info("Downloading from S3: s3://{bucket}/{key}")
    
    # Download file
    object <- s3_client$get_object(Bucket = bucket, Key = key)
    writeBin(object$Body, local_path)
    
    log_info("Successfully downloaded to {local_path}")
    return(local_path)
  }, error = function(e) {
    log_error("S3 download failed: {e$message}")
    stop(e)
  })
}

upload_to_s3 <- function(local_path, bucket, key, s3_client, 
                         server_side_encryption = "aws:kms",
                         sse_kms_key_id = NULL) {
  """
  Upload file to S3 with encryption
  """
  tryCatch({
    log_info("Uploading to S3: s3://{bucket}/{key}")
    
    file_body <- readBin(local_path, "raw", file.size(local_path))
    
    put_args <- list(
      Bucket = bucket,
      Key = key,
      Body = file_body,
      ServerSideEncryption = server_side_encryption
    )
    
    if (!is.null(sse_kms_key_id)) {
      put_args$SSEKMSKeyId <- sse_kms_key_id
    }
    
    do.call(s3_client$put_object, put_args)
    
    log_info("Successfully uploaded to S3")
    return(paste0("s3://", bucket, "/", key))
  }, error = function(e) {
    log_error("S3 upload failed: {e$message}")
    stop(e)
  })
}

# =============================================================================
# VCF File Validation
# =============================================================================

validate_vcf_file <- function(vcf_path) {
  """
  Validate VCF file integrity and format
  """
  log_info("Validating VCF file: {vcf_path}")
  
  validation_results <- list(
    file_exists = FALSE,
    is_bgzipped = FALSE,
    has_index = FALSE,
    is_readable = FALSE,
    header_valid = FALSE
  )
  
  # Check file existence
  if (!file.exists(vcf_path)) {
    log_warn("VCF file not found: {vcf_path}")
    return(validation_results)
  }
  validation_results$file_exists <- TRUE
  
  # Check bgzip compression
  if (!grepl("\\.vcf\\.gz$", vcf_path)) {
    log_warn("VCF file is not bgzipped: {vcf_path}")
    return(validation_results)
  }
  validation_results$is_bgzipped <- TRUE
  
  # Check index
  if (!file.exists(paste0(vcf_path, ".tbi"))) {
    log_warn("VCF index (.tbi) not found: {vcf_path}.tbi")
    # Continue anyway as we can create index
  } else {
    validation_results$has_index <- TRUE
  }
  
  # Try to read header
  tryCatch({
    vcf <- VariantAnnotation::readVcf(vcf_path, genome = "GRCh38")
    validation_results$is_readable <- TRUE
    
    # Validate header
    header <- VariantAnnotation::header(vcf)
    if (length(header) > 0) {
      validation_results$header_valid <- TRUE
    }
    
    log_info("VCF validation successful")
  }, error = function(e) {
    log_error("VCF read error: {e$message}")
  })
  
  return(validation_results)
}

# =============================================================================
# VCF Reading and Processing
# =============================================================================

read_vcf_in_chunks <- function(vcf_path, chunk_size = 10000, 
                               genome = "GRCh38") {
  """
  Read VCF file in chunks to handle large files
  Yields variants in batches
  """
  log_info("Reading VCF in chunks: {vcf_path}")
  
  # Open VCF connection
  vcf_file <- VariantAnnotation::VcfFile(vcf_path, yieldSize = chunk_size)
  
  chunk_list <- list()
  chunk_num <- 0
  
  while (TRUE) {
    # Read next chunk
    vcf_chunk <- VariantAnnotation::readVcf(vcf_file, genome = genome)
    
    if (length(vcf_chunk) == 0) break
    
    chunk_num <- chunk_num + 1
    log_debug("Processed chunk {chunk_num} with {length(vcf_chunk)} variants")
    
    chunk_list[[chunk_num]] <- vcf_chunk
  }
  
  close(vcf_file)
  log_info("VCF reading complete: {chunk_num} chunks processed")
  
  return(chunk_list)
}

extract_variant_information <- function(vcf) {
  """
  Extract key variant information from VCF object
  Returns data.frame with variant details
  """
  log_debug("Extracting variant information from VCF")
  
  # Extract basic information
  variants_df <- data.frame(
    CHROM = as.character(seqnames(vcf)),
    POS = start(ranges(vcf)),
    REF = as.character(ref(vcf)),
    ALT = as.character(alt(vcf)),
    QUAL = qual(vcf),
    FILTER = as.character(filt(vcf)),
    stringsAsFactors = FALSE
  )
  
  # Extract INFO fields
  info_df <- as.data.frame(info(vcf), stringsAsFactors = FALSE)
  variants_df <- cbind(variants_df, info_df)
  
  # Extract GENOTYPES
  geno_names <- names(geno(vcf))
  
  if ("GT" %in% geno_names) {
    gt_data <- geno(vcf)$GT
    # Convert genotypes to numeric format
    variants_df$GT <- apply(gt_data, 1, function(x) {
      paste(x, collapse = ",")
    })
  }
  
  if ("DP" %in% geno_names) {
    variants_df$DP <- rowMeans(geno(vcf)$DP, na.rm = TRUE)
  }
  
  if ("GQ" %in% geno_names) {
    variants_df$GQ <- rowMeans(geno(vcf)$GQ, na.rm = TRUE)
  }
  
  return(variants_df)
}

# =============================================================================
# Quality Control Filters
# =============================================================================

apply_initial_qc_filters <- function(variants_df, 
                                     min_quality = 60,
                                     min_depth = 30) {
  """
  Apply initial quality control filters
  """
  log_info("Applying initial QC filters (QUAL >= {min_quality}, DEPTH >= {min_depth})")
  
  n_initial <- nrow(variants_df)
  
  # Filter by quality
  variants_df <- variants_df %>%
    filter(QUAL >= min_quality | is.na(QUAL)) %>%
    filter(DP >= min_depth | is.na(DP))
  
  n_filtered <- nrow(variants_df)
  n_removed <- n_initial - n_filtered
  
  log_info("QC filtering: {n_initial} -> {n_filtered} variants ({n_removed} removed)")
  
  return(variants_df)
}

# =============================================================================
# Population-Specific Metadata
# =============================================================================

extract_population_metadata <- function(vcf_path, ethnic_group = "EUR") {
  """
  Extract and organize population-specific metadata
  """
  log_info("Extracting population metadata for group: {ethnic_group}")
  
  # Extract sample names
  samples <- colnames(geno(readVcf(vcf_path, genome = "GRCh38")))
  
  metadata <- data.frame(
    sample_id = samples,
    ethnic_group = ethnic_group,
    file_path = vcf_path,
    ingestion_date = Sys.Date(),
    processing_status = "queued",
    stringsAsFactors = FALSE
  )
  
  return(metadata)
}

# =============================================================================
# Database Storage (RDS)
# =============================================================================

connect_to_database <- function(config_file = "config/database_config.yml") {
  """
  Establish connection to RDS PostgreSQL database
  """
  log_info("Connecting to RDS database")
  
  db_config <- yaml::read_yaml(config_file)
  
  conn <- DBI::dbConnect(
    RPostgres::Postgres(),
    host = db_config$rds$host,
    port = db_config$rds$port,
    user = db_config$rds$user,
    password = Sys.getenv("DB_PASSWORD"),
    dbname = db_config$rds$database
  )
  
  log_info("Successfully connected to RDS database")
  return(conn)
}

store_sample_metadata <- function(conn, metadata_df) {
  """
  Store sample metadata in RDS
  """
  log_info("Storing sample metadata in database")
  
  tryCatch({
    DBI::dbWriteTable(
      conn,
      "sample_metadata",
      metadata_df,
      append = TRUE,
      overwrite = FALSE,
      row.names = FALSE
    )
    
    log_info("Metadata stored for {nrow(metadata_df)} samples")
  }, error = function(e) {
    log_error("Database write error: {e$message}")
    stop(e)
  })
}

store_variant_data <- function(conn, variants_df, sample_id) {
  """
  Store variant data in RDS
  """
  log_info("Storing variant data for sample: {sample_id}")
  
  variants_df$sample_id <- sample_id
  variants_df$ingestion_timestamp <- Sys.time()
  
  tryCatch({
    DBI::dbWriteTable(
      conn,
      "variants",
      variants_df,
      append = TRUE,
      overwrite = FALSE,
      row.names = FALSE
    )
    
    log_info("Stored {nrow(variants_df)} variants for sample {sample_id}")
  }, error = function(e) {
    log_error("Database write error: {e$message}")
    stop(e)
  })
}

# =============================================================================
# Main Ingestion Pipeline
# =============================================================================

run_data_ingestion <- function(vcf_s3_path,
                                sample_id,
                                ethnic_group = "EUR",
                                local_temp_dir = "data/raw",
                                aws_region = "us-east-1",
                                min_quality = 60,
                                min_depth = 30) {
  """
  Main data ingestion pipeline orchestration
  """
  log_info("========== DATA INGESTION PIPELINE START ==========")
  log_info("Sample ID: {sample_id}")
  log_info("Ethnic Group: {ethnic_group}")
  log_info("S3 Path: {vcf_s3_path}")
  
  # Create temporary directory
  dir.create(local_temp_dir, showWarnings = FALSE, recursive = TRUE)
  
  # Parse S3 path
  s3_parts <- stringr::str_match(vcf_s3_path, "^s3://([^/]+)/(.+)$")
  bucket <- s3_parts[1, 2]
  key <- s3_parts[1, 3]
  
  # Initialize AWS client
  s3_client <- initialize_s3_client(region = aws_region)
  
  # Download from S3
  local_vcf_path <- file.path(local_temp_dir, basename(key))
  download_from_s3(bucket, key, local_vcf_path, s3_client)
  
  # Validate VCF
  validation <- validate_vcf_file(local_vcf_path)
  if (!validation$is_readable) {
    log_error("VCF validation failed")
    stop("Invalid VCF file")
  }
  
  # Read VCF
  vcf <- VariantAnnotation::readVcf(local_vcf_path, genome = "GRCh38")
  log_info("Loaded VCF with {length(vcf)} variants")
  
  # Extract variant information
  variants_df <- extract_variant_information(vcf)
  
  # Apply QC filters
  variants_df <- apply_initial_qc_filters(
    variants_df,
    min_quality = min_quality,
    min_depth = min_depth
  )
  
  # Extract metadata
  metadata <- data.frame(
    sample_id = sample_id,
    ethnic_group = ethnic_group,
    file_path = vcf_s3_path,
    ingestion_date = Sys.Date(),
    ingestion_timestamp = Sys.time(),
    n_variants_raw = length(vcf),
    n_variants_qc_passed = nrow(variants_df),
    processing_status = "qc_complete",
    stringsAsFactors = FALSE
  )
  
  # Connect to database and store
  conn <- connect_to_database()
  store_sample_metadata(conn, metadata)
  store_variant_data(conn, variants_df, sample_id)
  DBI::dbDisconnect(conn)
  
  # Save processed data locally
  processed_dir <- "data/processed"
  dir.create(processed_dir, showWarnings = FALSE, recursive = TRUE)
  
  saveRDS(variants_df, file.path(processed_dir, paste0(sample_id, "_variants.rds")))
  write.csv(metadata, file.path(processed_dir, paste0(sample_id, "_metadata.csv")), 
            row.names = FALSE)
  
  log_info("========== DATA INGESTION PIPELINE COMPLETE ==========")
  
  return(list(
    variants = variants_df,
    metadata = metadata,
    validation = validation
  ))
}

# =============================================================================
# Export for use in other modules
# =============================================================================

if (!interactive()) {
  # When called from command line
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) >= 2) {
    vcf_path <- args[1]
    sample_id <- args[2]
    ethnic_group <- if (length(args) >= 3) args[3] else "EUR"
    
    result <- run_data_ingestion(
      vcf_s3_path = vcf_path,
      sample_id = sample_id,
      ethnic_group = ethnic_group
    )
  }
}
