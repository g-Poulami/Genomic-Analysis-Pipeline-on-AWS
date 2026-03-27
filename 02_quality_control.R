# =============================================================================
# 02_quality_control.R
# Cloud-Native Genomic Analysis Pipeline
# Quality Control and Validation Module
# =============================================================================

library(tidyverse)
library(data.table)
library(logger)
library(ggplot2)
library(gridExtra)

log_appender(appender_file("logs/quality_control.log"))
log_threshold(INFO)

# =============================================================================
# Depth Analysis
# =============================================================================

analyze_depth_distribution <- function(variants_df, 
                                       min_depth = 30,
                                       max_depth = 500) {
  """
  Analyze sequencing depth distribution
  """
  log_info("Analyzing depth distribution")
  
  depth_stats <- variants_df %>%
    filter(!is.na(DP)) %>%
    summarise(
      n_variants = n(),
      mean_depth = mean(DP, na.rm = TRUE),
      median_depth = median(DP, na.rm = TRUE),
      sd_depth = sd(DP, na.rm = TRUE),
      min_depth = min(DP, na.rm = TRUE),
      max_depth = max(DP, na.rm = TRUE),
      pct_low_depth = 100 * sum(DP < min_depth, na.rm = TRUE) / n(),
      pct_high_depth = 100 * sum(DP > max_depth, na.rm = TRUE) / n(),
      .groups = "drop"
    )
  
  log_info("Depth stats - Mean: {round(depth_stats$mean_depth, 2)}, Median: {round(depth_stats$median_depth, 2)}")
  
  return(depth_stats)
}

# =============================================================================
# Quality Score Analysis
# =============================================================================

analyze_quality_distribution <- function(variants_df,
                                         min_quality = 60) {
  """
  Analyze QUAL score distribution
  """
  log_info("Analyzing quality score distribution")
  
  quality_stats <- variants_df %>%
    filter(!is.na(QUAL)) %>%
    summarise(
      n_variants = n(),
      mean_qual = mean(QUAL, na.rm = TRUE),
      median_qual = median(QUAL, na.rm = TRUE),
      sd_qual = sd(QUAL, na.rm = TRUE),
      min_qual = min(QUAL, na.rm = TRUE),
      max_qual = max(QUAL, na.rm = TRUE),
      pct_high_quality = 100 * sum(QUAL >= min_quality, na.rm = TRUE) / n(),
      .groups = "drop"
    )
  
  log_info("Quality stats - Mean: {round(quality_stats$mean_qual, 2)}, Median: {round(quality_stats$median_qual, 2)}")
  
  return(quality_stats)
}

# =============================================================================
# Variant Type Analysis
# =============================================================================

analyze_variant_types <- function(variants_df) {
  """
  Analyze distribution of SNVs, indels, and other variants
  """
  log_info("Analyzing variant types")
  
  variant_type_analysis <- variants_df %>%
    mutate(
      ref_length = nchar(as.character(REF)),
      alt_length = nchar(as.character(ALT)),
      variant_type = case_when(
        ref_length == alt_length & ref_length == 1 ~ "SNV",
        ref_length < alt_length ~ "Insertion",
        ref_length > alt_length ~ "Deletion",
        TRUE ~ "Complex"
      )
    ) %>%
    group_by(variant_type) %>%
    summarise(
      count = n(),
      percentage = 100 * n() / nrow(variants_df),
      .groups = "drop"
    ) %>%
    arrange(desc(count))
  
  log_info("Variant types: {paste(variant_type_analysis$variant_type, collapse=', ')}")
  
  return(variant_type_analysis)
}

# =============================================================================
# Transition/Transversion Ratio (Ts/Tv)
# =============================================================================

calculate_tstv_ratio <- function(variants_df) {
  """
  Calculate transition/transversion ratio
  Expected ~2.0 for human genome
  """
  log_info("Calculating Ts/Tv ratio")
  
  snv_df <- variants_df %>%
    filter(nchar(as.character(REF)) == 1 & nchar(as.character(ALT)) == 1)
  
  # Define transition and transversion
  transitions <- c(
    "A->G", "G->A", "C->T", "T->C"
  )
  
  transversions <- c(
    "A->C", "A->T", "G->C", "G->T",
    "C->A", "C->G", "T->A", "T->G"
  )
  
  snv_df$mut_type <- paste0(snv_df$REF, "->", snv_df$ALT)
  
  n_transitions <- sum(snv_df$mut_type %in% transitions, na.rm = TRUE)
  n_transversions <- sum(snv_df$mut_type %in% transversions, na.rm = TRUE)
  
  tstv_ratio <- if (n_transversions > 0) n_transitions / n_transversions else NA
  
  tstv_stats <- data.frame(
    transitions = n_transitions,
    transversions = n_transversions,
    tstv_ratio = tstv_ratio,
    quality_flag = if (is.na(tstv_ratio) || (tstv_ratio >= 1.8 & tstv_ratio <= 2.2)) "PASS" else "WARN"
  )
  
  log_info("Ts/Tv ratio: {round(tstv_ratio, 3)}")
  
  return(tstv_stats)
}

# =============================================================================
# Allele Frequency Analysis
# =============================================================================

analyze_allele_frequencies <- function(variants_df,
                                       ethnic_group = "EUR") {
  """
  Analyze allele frequency distribution by ethnic group
  """
  log_info("Analyzing allele frequencies for group: {ethnic_group}")
  
  # Parse genotypes and calculate allele frequencies
  af_df <- variants_df %>%
    filter(!is.na(GT)) %>%
    mutate(
      # Simple AF calculation from GT field
      # In real scenario, would use more sophisticated methods
      af_estimate = case_when(
        GT == "0/0" ~ 0,
        GT == "0/1" ~ 0.5,
        GT == "1/1" ~ 1,
        TRUE ~ NA_real_
      )
    ) %>%
    filter(!is.na(af_estimate))
  
  af_stats <- af_df %>%
    summarise(
      mean_af = mean(af_estimate, na.rm = TRUE),
      median_af = median(af_estimate, na.rm = TRUE),
      n_common = sum(af_estimate >= 0.05),
      n_rare = sum(af_estimate < 0.05 & af_estimate > 0),
      n_singleton = sum(af_estimate == 0.5),
      .groups = "drop"
    )
  
  log_info("AF stats - Mean: {round(af_stats$mean_af, 4)}, Common variants: {af_stats$n_common}")
  
  return(af_stats)
}

# =============================================================================
# Contamination Detection
# =============================================================================

detect_contamination <- function(variants_df,
                                 contamination_threshold = 0.03) {
  """
  Detect potential sample contamination
  Based on heterozygosity and allele patterns
  """
  log_info("Checking for sample contamination")
  
  # Calculate expected vs observed heterozygosity
  het_variants <- variants_df %>%
    filter(!is.na(GT)) %>%
    filter(GT == "0/1")
  
  hom_variants <- variants_df %>%
    filter(!is.na(GT)) %>%
    filter(GT %in% c("0/0", "1/1"))
  
  n_het <- nrow(het_variants)
  n_hom <- nrow(hom_variants)
  total_genotypes <- n_het + n_hom
  
  observed_heterozygosity <- if (total_genotypes > 0) n_het / total_genotypes else 0
  expected_heterozygosity <- 0.1  # Conservative estimate
  
  contamination_level <- abs(observed_heterozygosity - expected_heterozygosity) / 
                         expected_heterozygosity
  
  contamination_status <- list(
    contamination_level = contamination_level,
    is_contaminated = contamination_level > contamination_threshold,
    observed_het = observed_heterozygosity,
    n_het_variants = n_het,
    quality_flag = if (contamination_level > contamination_threshold) "FAIL" else "PASS"
  )
  
  if (contamination_status$is_contaminated) {
    log_warn("Potential contamination detected (level: {round(contamination_level, 4)})")
  } else {
    log_info("No significant contamination detected")
  }
  
  return(contamination_status)
}

# =============================================================================
# Chromosome Distribution
# =============================================================================

analyze_chromosome_distribution <- function(variants_df) {
  """
  Analyze variant distribution across chromosomes
  """
  log_info("Analyzing chromosome distribution")
  
  chr_dist <- variants_df %>%
    group_by(CHROM) %>%
    summarise(
      n_variants = n(),
      .groups = "drop"
    ) %>%
    mutate(
      percentage = 100 * n_variants / sum(n_variants)
    ) %>%
    arrange(desc(n_variants))
  
  log_info("Variants across {nrow(chr_dist)} chromosomes")
  
  return(chr_dist)
}

# =============================================================================
# Visualization Functions
# =============================================================================

create_qc_plots <- function(variants_df, output_dir = "outputs/qc_plots") {
  """
  Create comprehensive QC visualization plots
  """
  log_info("Generating QC plots")
  
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
  
  # 1. Depth distribution
  p1 <- variants_df %>%
    filter(!is.na(DP), DP < 1000) %>%
    ggplot(aes(x = DP)) +
    geom_histogram(bins = 50, fill = "#2E86AB", alpha = 0.7) +
    labs(title = "Depth Distribution",
         x = "Read Depth", y = "Count") +
    theme_minimal()
  
  # 2. Quality score distribution
  p2 <- variants_df %>%
    filter(!is.na(QUAL)) %>%
    ggplot(aes(x = QUAL)) +
    geom_histogram(bins = 50, fill = "#A23B72", alpha = 0.7) +
    labs(title = "Quality Score Distribution",
         x = "QUAL Score", y = "Count") +
    theme_minimal()
  
  # 3. Variant type pie chart
  variant_types <- analyze_variant_types(variants_df)
  p3 <- variant_types %>%
    ggplot(aes(x = "", y = count, fill = variant_type)) +
    geom_bar(stat = "identity", width = 1) +
    coord_polar("y", start = 0) +
    labs(title = "Variant Type Distribution") +
    theme_minimal() +
    theme(legend.position = "right")
  
  # 4. Chromosome distribution
  chr_dist <- analyze_chromosome_distribution(variants_df)
  p4 <- chr_dist %>%
    head(22) %>%  # Exclude sex chromosomes for clarity
    ggplot(aes(x = reorder(CHROM, -n_variants), y = n_variants)) +
    geom_bar(stat = "identity", fill = "#F18F01", alpha = 0.7) +
    labs(title = "Variants by Chromosome",
         x = "Chromosome", y = "Count") +
    theme_minimal() +
    theme(axis.text.x = element_text(angle = 45, hjust = 1))
  
  # Combine plots
  combined_plot <- gridExtra::arrangeGrob(p1, p2, p3, p4, ncol = 2)
  
  ggsave(file.path(output_dir, "qc_summary.pdf"),
         combined_plot, width = 14, height = 10)
  
  log_info("QC plots saved to {output_dir}")
  
  return(list(p1 = p1, p2 = p2, p3 = p3, p4 = p4))
}

# =============================================================================
# Comprehensive QC Report
# =============================================================================

generate_qc_report <- function(variants_df,
                               sample_id,
                               ethnic_group = "EUR",
                               output_file = NULL) {
  """
  Generate comprehensive QC report
  """
  log_info("Generating QC report for sample: {sample_id}")
  
  if (is.null(output_file)) {
    output_file <- paste0("outputs/reports/", sample_id, "_qc_report.html")
  }
  
  dir.create(dirname(output_file), showWarnings = FALSE, recursive = TRUE)
  
  # Calculate all QC metrics
  depth_stats <- analyze_depth_distribution(variants_df)
  quality_stats <- analyze_quality_distribution(variants_df)
  variant_types <- analyze_variant_types(variants_df)
  tstv_stats <- calculate_tstv_ratio(variants_df)
  af_stats <- analyze_allele_frequencies(variants_df, ethnic_group)
  contamination_stats <- detect_contamination(variants_df)
  chr_dist <- analyze_chromosome_distribution(variants_df)
  
  # Create HTML report
  html_content <- sprintf(
    "<!DOCTYPE html>
<html>
<head>
  <title>Quality Control Report - %s</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 20px; background-color: #f5f5f5; }
    .header { background-color: #2E86AB; color: white; padding: 20px; border-radius: 5px; }
    .section { background-color: white; margin: 20px 0; padding: 15px; border-radius: 5px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
    .metric { display: inline-block; margin: 10px 20px 10px 0; padding: 10px; background-color: #f9f9f9; border-left: 4px solid #2E86AB; }
    .pass { color: #27AE60; font-weight: bold; }
    .warn { color: #F39C12; font-weight: bold; }
    .fail { color: #E74C3C; font-weight: bold; }
    table { width: 100%%; border-collapse: collapse; }
    th, td { padding: 10px; text-align: left; border-bottom: 1px solid #ddd; }
    th { background-color: #f0f0f0; }
  </style>
</head>
<body>
  <div class=\"header\">
    <h1>Quality Control Report</h1>
    <p><strong>Sample ID:</strong> %s</p>
    <p><strong>Ethnic Group:</strong> %s</p>
    <p><strong>Report Date:</strong> %s</p>
  </div>
  
  <div class=\"section\">
    <h2>Summary Statistics</h2>
    <div class=\"metric\">
      <strong>Total Variants:</strong> %d
    </div>
    <div class=\"metric\">
      <strong>Mean Depth:</strong> %.2f
    </div>
    <div class=\"metric\">
      <strong>Mean Quality:</strong> %.2f
    </div>
    <div class=\"metric\">
      <strong>Ts/Tv Ratio:</strong> <span class=\"%s\">%.3f</span>
    </div>
  </div>
  
  <div class=\"section\">
    <h2>Depth Analysis</h2>
    <table>
      <tr>
        <th>Metric</th>
        <th>Value</th>
      </tr>
      <tr>
        <td>Mean Depth</td>
        <td>%.2f</td>
      </tr>
      <tr>
        <td>Median Depth</td>
        <td>%.2f</td>
      </tr>
      <tr>
        <td>Std Dev</td>
        <td>%.2f</td>
      </tr>
      <tr>
        <td>%% Low Depth (&lt;30x)</td>
        <td>%.2f%%</td>
      </tr>
    </table>
  </div>
  
  <div class=\"section\">
    <h2>Quality Analysis</h2>
    <table>
      <tr>
        <th>Metric</th>
        <th>Value</th>
      </tr>
      <tr>
        <td>Mean QUAL</td>
        <td>%.2f</td>
      </tr>
      <tr>
        <td>Median QUAL</td>
        <td>%.2f</td>
      </tr>
      <tr>
        <td>%% High Quality (&gt;60)</td>
        <td>%.2f%%</td>
      </tr>
    </table>
  </div>
  
  <div class=\"section\">
    <h2>Contamination Check</h2>
    <p><strong>Status:</strong> <span class=\"%s\">%s</span></p>
    <p><strong>Contamination Level:</strong> %.4f</p>
  </div>
  
  <div class=\"section\">
    <h2>Variant Types</h2>
    <table>
      <tr>
        <th>Type</th>
        <th>Count</th>
        <th>Percentage</th>
      </tr>
      %s
    </table>
  </div>
  
</body>
</html>",
    sample_id, sample_id, ethnic_group, format(Sys.Date(), "%Y-%m-%d"),
    nrow(variants_df),
    depth_stats$mean_depth,
    quality_stats$mean_qual,
    tstv_stats$quality_flag,
    tstv_stats$tstv_ratio,
    depth_stats$mean_depth,
    depth_stats$median_depth,
    depth_stats$sd_depth,
    depth_stats$pct_low_depth,
    quality_stats$mean_qual,
    quality_stats$median_qual,
    quality_stats$pct_high_quality,
    if (contamination_stats$quality_flag == "PASS") "pass" else "fail",
    if (contamination_stats$quality_flag == "PASS") "PASS" else "FAIL",
    contamination_stats$contamination_level,
    paste(sprintf("<tr><td>%s</td><td>%d</td><td>%.2f%%</td></tr>",
                  variant_types$variant_type,
                  variant_types$count,
                  variant_types$percentage), collapse = "")
  )
  
  # Write HTML file
  writeLines(html_content, output_file)
  
  log_info("QC report saved to {output_file}")
  
  return(list(
    file = output_file,
    metrics = list(
      depth = depth_stats,
      quality = quality_stats,
      tstv = tstv_stats,
      contamination = contamination_stats,
      variant_types = variant_types,
      af = af_stats
    )
  ))
}

# =============================================================================
# Main QC Pipeline
# =============================================================================

run_quality_control <- function(variants_df,
                                sample_id,
                                ethnic_group = "EUR",
                                output_dir = "outputs") {
  """
  Main QC pipeline orchestration
  """
  log_info("========== QUALITY CONTROL PIPELINE START ==========")
  log_info("Sample: {sample_id}")
  
  # Generate plots
  create_qc_plots(variants_df, file.path(output_dir, "qc_plots"))
  
  # Generate report
  qc_report <- generate_qc_report(
    variants_df,
    sample_id,
    ethnic_group,
    file.path(output_dir, "reports", paste0(sample_id, "_qc_report.html"))
  )
  
  log_info("========== QUALITY CONTROL PIPELINE COMPLETE ==========")
  
  return(qc_report)
}
