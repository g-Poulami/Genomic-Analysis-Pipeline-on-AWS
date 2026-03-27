# =============================================================================
# R/utils/encryption_utils.R
# Data Encryption and Decryption Utilities
# =============================================================================

library(openssl)
library(logger)

log_appender(appender_file("logs/encryption.log"))
log_threshold(INFO)

# =============================================================================
# KMS Key Management
# =============================================================================

get_kms_key <- function(key_id, aws_region = "us-east-1") {
  """
  Retrieve KMS key details from AWS
  key_id can be ARN or alias
  """
  log_info("Retrieving KMS key: {key_id}")
  
  tryCatch({
    kms_client <- paws::kms(region = aws_region)
    
    # Describe key
    key_info <- kms_client$describe_key(KeyId = key_id)
    
    log_info("Successfully retrieved KMS key")
    return(key_info)
  }, error = function(e) {
    log_error("Failed to retrieve KMS key: {e$message}")
    stop(e)
  })
}

# =============================================================================
# Data Encryption at Rest
# =============================================================================

encrypt_sensitive_data <- function(data,
                                   kms_key_id,
                                   aws_region = "us-east-1") {
  """
  Encrypt sensitive data using AWS KMS
  """
  log_info("Encrypting sensitive data with KMS key")
  
  tryCatch({
    kms_client <- paws::kms(region = aws_region)
    
    # Convert data to bytes
    plaintext <- charToRaw(jsonlite::toJSON(data))
    
    # Encrypt using KMS
    encrypted_result <- kms_client$encrypt(
      KeyId = kms_key_id,
      Plaintext = plaintext
    )
    
    log_info("Data encrypted successfully")
    
    return(list(
      encrypted_blob = encrypted_result$CiphertextBlob,
      key_id = encrypted_result$KeyId,
      encryption_timestamp = Sys.time()
    ))
  }, error = function(e) {
    log_error("Encryption failed: {e$message}")
    stop(e)
  })
}

decrypt_sensitive_data <- function(encrypted_blob,
                                    aws_region = "us-east-1") {
  """
  Decrypt data using AWS KMS
  """
  log_info("Decrypting sensitive data")
  
  tryCatch({
    kms_client <- paws::kms(region = aws_region)
    
    # Decrypt using KMS
    decrypted_result <- kms_client$decrypt(
      CiphertextBlob = encrypted_blob
    )
    
    # Convert back to data
    plaintext <- rawToChar(decrypted_result$Plaintext)
    data <- jsonlite::fromJSON(plaintext)
    
    log_info("Data decrypted successfully")
    
    return(data)
  }, error = function(e) {
    log_error("Decryption failed: {e$message}")
    stop(e)
  })
}

# =============================================================================
# In-Transit Encryption (TLS)
# =============================================================================

setup_tls_verification <- function(ca_bundle_path = "/etc/ssl/certs/ca-bundle.crt") {
  """
  Configure TLS certificate verification
  """
  log_info("Setting up TLS verification")
  
  if (!file.exists(ca_bundle_path)) {
    log_warn("CA bundle not found at {ca_bundle_path}")
    return(FALSE)
  }
  
  # Set system certificate for HTTPS verification
  httr::set_config(httr::config(
    cainfo = ca_bundle_path,
    ssl_verifypeer = TRUE,
    ssl_verifyhost = 2
  ))
  
  log_info("TLS verification configured")
  return(TRUE)
}

# =============================================================================
# Data Anonymization
# =============================================================================

anonymize_sample_ids <- function(sample_ids,
                                  salt = NULL) {
  """
  Anonymize sample IDs using hashing
  """
  log_info("Anonymizing {length(sample_ids)} sample IDs")
  
  if (is.null(salt)) {
    salt <- paste(sample(c(letters, LETTERS, 0:9), 16), collapse = "")
    log_info("Generated random salt")
  }
  
  anonymized_ids <- sapply(sample_ids, function(id) {
    hashed <- openssl::sha256(paste0(id, salt))
    # Truncate to first 12 characters for readability
    substring(hashed, 1, 12)
  }, USE.NAMES = FALSE)
  
  return(data.frame(
    original_id = sample_ids,
    anonymized_id = anonymized_ids,
    anonymization_date = Sys.Date()
  ))
}

redact_sensitive_fields <- function(data_df,
                                    sensitive_cols = c("patient_id", "name", "email")) {
  """
  Redact sensitive columns from dataframe
  """
  log_info("Redacting sensitive fields: {paste(sensitive_cols, collapse=', ')}")
  
  for (col in intersect(sensitive_cols, names(data_df))) {
    data_df[[col]] <- "REDACTED"
  }
  
  log_info("Redaction complete")
  return(data_df)
}

# =============================================================================
# Key Rotation
# =============================================================================

schedule_key_rotation <- function(key_id,
                                   rotation_days = 90,
                                   aws_region = "us-east-1") {
  """
  Enable automatic key rotation for KMS key
  """
  log_info("Scheduling key rotation every {rotation_days} days")
  
  tryCatch({
    kms_client <- paws::kms(region = aws_region)
    
    # Enable key rotation
    kms_client$enable_key_rotation(KeyId = key_id)
    
    log_info("Key rotation enabled for {key_id}")
    return(TRUE)
  }, error = function(e) {
    log_error("Failed to enable key rotation: {e$message}")
    stop(e)
  })
}

# =============================================================================
# Secure Credential Management
# =============================================================================

load_aws_credentials_secure <- function(credentials_file = "config/aws_credentials") {
  """
  Securely load AWS credentials from file
  File should have restrictive permissions (600)
  """
  log_info("Loading AWS credentials from {credentials_file}")
  
  # Check file permissions
  file_info <- file.info(credentials_file)
  if (file_info$mode != "100600") {
    log_warn("Credentials file has non-standard permissions: {file_info$mode}")
  }
  
  credentials <- readLines(credentials_file)
  
  # Parse credentials (simple format: KEY=VALUE)
  cred_list <- list()
  for (line in credentials) {
    if (grepl("^[^=]+=.+$", line)) {
      parts <- strsplit(line, "=")[[1]]
      cred_list[[parts[1]]] <- parts[2]
    }
  }
  
  log_info("Credentials loaded successfully")
  return(cred_list)
}

# =============================================================================
# Audit Logging
# =============================================================================

audit_log_access <- function(user_id,
                             resource,
                             action,
                             timestamp = Sys.time(),
                             details = NULL,
                             db_conn = NULL) {
  """
  Log resource access for audit trail
  """
  audit_entry <- data.frame(
    user_id = user_id,
    resource = resource,
    action = action,
    timestamp = timestamp,
    details = jsonlite::toJSON(details),
    ip_address = Sys.getenv("REMOTE_ADDR"),
    stringsAsFactors = FALSE
  )
  
  # Log to file
  audit_log_file <- "logs/audit_log.csv"
  if (file.exists(audit_log_file)) {
    write.table(audit_entry, audit_log_file, 
                append = TRUE, sep = ",", row.names = FALSE, col.names = FALSE)
  } else {
    write.csv(audit_entry, audit_log_file, row.names = FALSE)
  }
  
  # Log to database if connection provided
  if (!is.null(db_conn)) {
    tryCatch({
      DBI::dbWriteTable(
        db_conn,
        "audit_log",
        audit_entry,
        append = TRUE,
        overwrite = FALSE,
        row.names = FALSE
      )
    }, error = function(e) {
      log_error("Failed to write audit log to database: {e$message}")
    })
  }
  
  log_info("Audit entry recorded: {action} on {resource} by {user_id}")
}

# =============================================================================
# Compliance Checking
# =============================================================================

check_hipaa_compliance <- function(data_df,
                                   sensitive_identifiers = c("patient_id", "ssn", "dob")) {
  """
  Check data for potential HIPAA violations
  """
  log_info("Checking HIPAA compliance")
  
  violations <- list()
  
  for (col in sensitive_identifiers) {
    if (col %in% names(data_df)) {
      if (sum(!is.na(data_df[[col]])) > 0) {
        violations[[col]] <- list(
          found = TRUE,
          n_values = sum(!is.na(data_df[[col]]))
        )
      }
    }
  }
  
  if (length(violations) > 0) {
    log_warn("HIPAA violations detected: {paste(names(violations), collapse=', ')}")
    return(list(compliant = FALSE, violations = violations))
  }
  
  log_info("Data is HIPAA compliant")
  return(list(compliant = TRUE, violations = list()))
}

# =============================================================================
# Secure File Deletion
# =============================================================================

securely_delete_file <- function(file_path,
                                 overwrite_passes = 3) {
  """
  Securely delete file by overwriting with random data
  """
  log_info("Securely deleting file: {file_path}")
  
  tryCatch({
    file_size <- file.size(file_path)
    
    for (i in 1:overwrite_passes) {
      # Overwrite with random data
      random_data <- raw(file_size)
      for (j in 1:file_size) {
        random_data[j] <- as.raw(sample(0:255, 1))
      }
      writeBin(random_data, file_path)
    }
    
    # Final overwrite with zeros
    writeBin(raw(file_size), file_path)
    
    # Delete file
    file.remove(file_path)
    
    log_info("File securely deleted")
    return(TRUE)
  }, error = function(e) {
    log_error("Secure deletion failed: {e$message}")
    return(FALSE)
  })
}
