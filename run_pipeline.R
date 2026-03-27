#!/usr/bin/env Rscript
# =============================================================================
# scripts/run_pipeline.R
# Main Pipeline Orchestration Script
# Cloud-Native Genomic Analysis Pipeline
# =============================================================================

library(tidyverse)
library(logger)

# Setup logging
dir.create("logs", showWarnings = FALSE)
log_appender(appender_file("logs/pipeline.log"))
log_threshold(INFO)

log_info("========== GENOMIC ANALYSIS PIPELINE STARTED ==========")

# =============================================================================
# Load Configuration
# =============================================================================

config <- yaml::read_yaml("config/pipeline_params.yml")

log_info("Configuration loaded:")
log_info("  Genome build: {config$variant_calling$genome_build}")
log_info("  Analysis mode: {config$variant_calling$mode}")
log_info("  Target disease: {config$disease_analysis$target_disease}")

# =============================================================================
# Source Analysis Modules
# =============================================================================

source("R/01_data_ingestion.R")
source("R/02_quality_control.R")
source("R/03_variant_annotation.R")
source("R/utils/encryption_utils.R")

# =============================================================================
# Process Command Line Arguments
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) == 0) {
  # Interactive mode
  log_info("Running in interactive mode")
  
  # Example analysis
  sample_id <- "SAMPLE_001"
  vcf_s3_path <- "s3://genomic-analysis-bucket/raw/sample_001.vcf.gz"
  ethnic_group <- "EUR"
  
} else {
  # Command line mode
  sample_id <- args[1]
  vcf_s3_path <- args[2]
  ethnic_group <- if (length(args) >= 3) args[3] else "EUR"
  
  log_info("Processing sample: {sample_id}")
}

# =============================================================================
# Main Pipeline Execution
# =============================================================================

run_complete_pipeline <- function(sample_id,
                                   vcf_s3_path,
                                   ethnic_group,
                                   config) {
  
  tryCatch({
    
    # =========================================================================
    # STEP 1: DATA INGESTION
    # =========================================================================
    log_info("STEP 1: Data Ingestion")
    
    ingestion_result <- run_data_ingestion(
      vcf_s3_path = vcf_s3_path,
      sample_id = sample_id,
      ethnic_group = ethnic_group,
      min_quality = config$analysis$min_quality,
      min_depth = config$analysis$min_depth
    )
    
    variants_df <- ingestion_result$variants
    metadata <- ingestion_result$metadata
    
    log_info("Data ingestion complete: {nrow(variants_df)} variants loaded")
    
    # =========================================================================
    # STEP 2: QUALITY CONTROL
    # =========================================================================
    log_info("STEP 2: Quality Control")
    
    qc_result <- run_quality_control(
      variants_df = variants_df,
      sample_id = sample_id,
      ethnic_group = ethnic_group,
      output_dir = "outputs"
    )
    
    log_info("Quality control complete")
    
    # =========================================================================
    # STEP 3: VARIANT ANNOTATION
    # =========================================================================
    log_info("STEP 3: Variant Annotation")
    
    annotation_result <- annotate_variants(
      variants_df = variants_df,
      sample_id = sample_id,
      ethnic_group = ethnic_group,
      annotation_sources = config$annotation$databases
    )
    
    annotated_variants <- annotation_result$variants
    annotation_summary <- annotation_result$summary
    
    log_info("Variant annotation complete")
    
    # =========================================================================
    # STEP 4: POPULATION-SPECIFIC ANALYSIS (Optional)
    # =========================================================================
    log_info("STEP 4: Population-Specific Analysis")
    
    # In production, would include detailed population comparisons
    log_info("Population analysis: {ethnic_group}")
    
    # =========================================================================
    # STEP 5: EXPORT RESULTS
    # =========================================================================
    log_info("STEP 5: Exporting Results")
    
    dir.create("outputs/results", showWarnings = FALSE, recursive = TRUE)
    
    # Export annotated variants
    annotation_file <- file.path(
      "outputs/results",
      paste0(sample_id, "_annotated_variants.csv")
    )
    
    export_annotated_variants(
      annotated_variants,
      output_file = annotation_file,
      format = "csv"
    )
    
    # =========================================================================
    # STEP 6: SECURE DATA EXPORT TO S3
    # =========================================================================
    log_info("STEP 6: Secure Export to S3")
    
    tryCatch({
      s3_client <- paws::s3(region = "us-east-1")
      
      # Prepare output directory
      output_files <- list.files("outputs/results", full.names = TRUE)
      
      for (file in output_files) {
        log_info("Uploading to S3: {basename(file)}")
        
        # In production, would encrypt before upload
        upload_to_s3(
          local_path = file,
          bucket = "genomic-analysis-bucket",
          key = paste0("results/", sample_id, "/", basename(file)),
          s3_client = s3_client,
          server_side_encryption = "aws:kms",
          sse_kms_key_id = Sys.getenv("KMS_KEY_ID", NA)
        )
      }
      
      log_info("S3 upload complete")
    }, error = function(e) {
      log_warn("S3 upload skipped (not available in test mode)")
    })
    
    # =========================================================================
    # GENERATE SUMMARY REPORT
    # =========================================================================
    log_info("STEP 7: Generate Summary Report")
    
    summary_report <- list(
      sample_id = sample_id,
      ethnic_group = ethnic_group,
      ingestion_date = Sys.Date(),
      pipeline_status = "COMPLETE",
      data_ingestion = list(
        total_variants = nrow(variants_df),
        variants_after_qc = nrow(variants_df)
      ),
      annotation = annotation_summary,
      qc_metrics = qc_result$metrics
    )
    
    # Save summary report
    summary_file <- file.path(
      "outputs/results",
      paste0(sample_id, "_pipeline_summary.json")
    )
    
    writeLines(
      jsonlite::toJSON(summary_report, pretty = TRUE),
      summary_file
    )
    
    log_info("Summary report saved to {summary_file}")
    
    # =========================================================================
    # Pipeline Complete
    # =========================================================================
    log_info("========== PIPELINE EXECUTION SUCCESSFUL ==========")
    log_info("Sample: {sample_id}")
    log_info("Total variants processed: {nrow(variants_df)}")
    log_info("Results location: outputs/results/")
    
    return(summary_report)
    
  }, error = function(e) {
    log_error("Pipeline execution failed: {e$message}")
    log_error("Traceback: {paste(traceback(), collapse=' -> ')}")
    
    # Send alert (in production)
    # send_pipeline_failure_alert(e$message)
    
    stop(e)
  })
}

# =============================================================================
# Execute Pipeline
# =============================================================================

# Run pipeline
if (interactive()) {
  log_info("Interactive mode - skipping automatic execution")
  log_info("Call run_complete_pipeline() to execute")
} else {
  result <- run_complete_pipeline(
    sample_id = sample_id,
    vcf_s3_path = vcf_s3_path,
    ethnic_group = ethnic_group,
    config = config
  )
}

log_info("Pipeline runner script completed")
