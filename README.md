# Cloud-Native Genomic Analysis Pipeline on AWS

A comprehensive R-based pipeline for multi-ethnic cancer mutational analysis with secure data management on AWS cloud infrastructure.

## Overview

This project implements:
- **Cloud-native architecture** on AWS (S3, EC2, Lambda, RDS)
- **Multi-ethnic cancer mutational analysis** using R
- **Secure data management** with encryption and access controls
- **Scalable workflows** for processing whole-genome and exome sequencing data
- **Containerized deployment** using Docker and AWS services

## Key Features

✅ Multi-ethnic variant calling and annotation  
✅ Population-specific allele frequency comparison  
✅ Automated VCF processing and quality control  
✅ Secure S3 integration with encryption  
✅ RDS database backend for metadata  
✅ Containerized R environment (Docker)  
✅ AWS Lambda integration for serverless workflows  
✅ Automated logging and audit trails  

## Project Structure

```
genomic_pipeline/
├── README.md
├── INSTALL.md
├── Dockerfile
├── docker-compose.yml
├── aws_config.yml
├── renv.lock
├── R/
│   ├── 01_data_ingestion.R
│   ├── 02_quality_control.R
│   ├── 03_variant_annotation.R
│   ├── 04_population_analysis.R
│   ├── 05_secure_data_export.R
│   └── utils/
│       ├── aws_s3_utils.R
│       ├── db_utils.R
│       ├── encryption_utils.R
│       └── logging_utils.R
├── scripts/
│   ├── run_pipeline.R
│   ├── lambda_handler.R
│   └── batch_processor.R
├── tests/
│   ├── test_data_ingestion.R
│   ├── test_annotation.R
│   └── test_security.R
├── data/
│   ├── raw/
│   ├── processed/
│   └── reference/
├── config/
│   ├── aws_credentials.example
│   ├── database_config.yml
│   └── pipeline_params.yml
└── outputs/
    └── reports/
```

## Prerequisites

- R >= 4.0.0
- Docker & Docker Compose
- AWS CLI configured with appropriate credentials
- PostgreSQL (for RDS)
- Git

## Quick Start

### 1. Install Dependencies

```bash
cd genomic_pipeline
# Using renv for reproducibility
Rscript -e "renv::restore()"
```

### 2. Configure AWS Credentials

```bash
cp config/aws_credentials.example config/aws_credentials
# Edit with your AWS credentials
nano config/aws_credentials
```

### 3. Build Docker Image

```bash
docker build -t genomic-pipeline:latest .
```

### 4. Run Pipeline

```bash
docker-compose up -d
Rscript scripts/run_pipeline.R
```

## Configuration Files

### aws_config.yml
```yaml
aws:
  region: us-east-1
  s3_bucket: genomic-analysis-bucket
  s3_prefix: cancer_analysis/
  
rds:
  engine: postgres
  instance_class: db.t3.medium
  allocated_storage: 100
  
security:
  encryption_key_rotation: monthly
  mfa_required: true
```

### pipeline_params.yml
```yaml
analysis:
  ethnic_groups: [EUR, AFR, EAS, SAS, AMR]
  min_depth: 30
  min_quality: 60
  
variant_calling:
  tool: gatk
  genome_build: GRCh38
  
annotation:
  databases:
    - gnomad
    - clinvar
    - cosmic
```

## Workflow Steps

### 1. Data Ingestion (`01_data_ingestion.R`)
- Reads VCF files from S3
- Validates file integrity
- Stores metadata in RDS

### 2. Quality Control (`02_quality_control.R`)
- Depth and quality filtering
- Population-specific QC metrics
- Contamination detection
- Generates QC reports

### 3. Variant Annotation (`03_variant_annotation.R`)
- Functional annotation
- Database lookups (gnomAD, ClinVar, COSMIC)
- Ethnic-specific frequency comparison
- Disease association scoring

### 4. Population Analysis (`04_population_analysis.R`)
- Multi-ethnic mutational pattern comparison
- Ancestry-adjusted allele frequencies
- Population-specific hotspots
- Statistical association analysis

### 5. Secure Data Export (`05_secure_data_export.R`)
- Anonymization of sensitive data
- Encryption of output files
- Audit trail logging
- S3 upload with versioning

## Security Features

### Data Encryption
- **At-Rest**: S3 encryption with customer-managed KMS keys
- **In-Transit**: TLS 1.2+ for all communications
- **Database**: RDS encryption enabled

### Access Control
- AWS IAM roles and policies
- S3 bucket policies with least privilege
- Database user credentials management
- API key rotation

### Compliance
- HIPAA-compliant logging
- Audit trails for all data access
- Data retention policies
- Automated backup mechanisms

### Example Security Implementation
```r
# See R/utils/encryption_utils.R for implementation
encrypt_sensitive_data(data, key_id = "arn:aws:kms:...")
audit_log_access(user_id, resource, action, timestamp)
```

## AWS Services Integration

### AWS S3
- Raw VCF file storage
- Processed results storage
- Reference genome storage

### AWS RDS
- Sample metadata
- Analysis results
- Audit logs

### AWS Lambda
- Automated pipeline triggers
- VCF validation
- Result notification

### AWS EC2
- Primary compute for heavy lifting
- Auto-scaling based on job queue

### AWS Batch
- Large-scale variant calling
- Distributed processing

## Running Analysis

### Single Sample
```r
source("scripts/run_pipeline.R")
run_genomic_pipeline(
  vcf_path = "s3://bucket/sample.vcf.gz",
  sample_id = "SAMPLE_001",
  ethnic_group = "EUR"
)
```

### Batch Processing
```bash
Rscript scripts/batch_processor.R \
  --sample_list samples.csv \
  --output_dir s3://bucket/results/
```

### AWS Lambda Trigger
```bash
aws lambda invoke \
  --function-name genomic-pipeline-trigger \
  --payload '{"vcf_key":"s3://bucket/sample.vcf.gz"}' \
  response.json
```

## Output Files

- `variant_annotations.csv` - Annotated variants
- `population_comparison.html` - Interactive plots
- `qc_report.pdf` - Quality control metrics
- `audit_log.csv` - Secure access logs

## Testing

```bash
# Run unit tests
Rscript -e "testthat::test_dir('tests')"

# Run with coverage
Rscript -e "covr::package_coverage()" 
```

## Performance Metrics

- **Processing Speed**: ~1M variants/hour on m5.2xlarge
- **Storage**: ~50GB per whole genome
- **Cost Optimization**: S3 Intelligent-Tiering for archival

## Troubleshooting

### S3 Connection Issues
```r
# Check AWS credentials
aws_creds <- get_aws_credentials()
# Verify S3 access
test_s3_connection(bucket = "genomic-analysis-bucket")
```

### Database Connection
```r
# Check RDS connectivity
test_db_connection(config_file = "config/database_config.yml")
```

### Memory Issues
- Adjust chunk size in `01_data_ingestion.R`
- Use EC2 instance with more RAM
- Consider AWS Batch for distributed processing

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Submit a pull request

## Documentation

- [AWS Setup Guide](INSTALL.md)
- [API Reference](docs/API.md)
- [Security Best Practices](docs/SECURITY.md)
- [Performance Tuning](docs/PERFORMANCE.md)

## Citation

If you use this pipeline in your research, please cite:

```bibtex
@software{genomic_pipeline_2024,
  title={Cloud-Native Genomic Analysis Pipeline on AWS},
  author={Your Name},
  year={2024},
  url={https://github.com/yourusername/genomic_pipeline}
}
```

## License

MIT License - See LICENSE file for details

## Support

For issues, questions, or contributions:
- GitHub Issues: https://github.com/yourusername/genomic_pipeline/issues
- Email: support@example.com

## Acknowledgments

Built with:
- [VariantAnnotation](https://bioconductor.org/packages/VariantAnnotation/)
- [Biostrings](https://bioconductor.org/packages/Biostrings/)
- [paws](https://github.com/paws-r/paws) - AWS SDK for R
- [tidyverse](https://www.tidyverse.org/)
