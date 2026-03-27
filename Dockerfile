FROM rocker/tidyverse:4.3.0

# Install system dependencies
RUN apt-get update && apt-get install -y \
    libpq-dev \
    libssl-dev \
    libcurl4-openssl-dev \
    libxml2-dev \
    git \
    curl \
    jq \
    aws-cli \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Install BiocManager and Bioconductor packages
RUN R --slave -e 'install.packages("BiocManager", repos="http://cran.r-project.org")'
RUN R --slave -e 'BiocManager::install(c("VariantAnnotation", "Biostrings", "GenomicRanges"))'

# Install R packages for AWS and database
RUN R --slave -e 'install.packages(c(\
    "paws", \
    "DBI", \
    "RPostgres", \
    "renv", \
    "logger", \
    "yaml", \
    "jsonlite", \
    "openssl", \
    "httr", \
    "testthat", \
    "covr" \
    ), repos="http://cran.r-project.org")'

# Set working directory
WORKDIR /app

# Copy project files
COPY . /app

# Create necessary directories
RUN mkdir -p /app/logs /app/data/{raw,processed,reference} /app/outputs/{qc_plots,reports}

# Set permissions
RUN chmod -R 755 /app/scripts
RUN chmod -R 755 /app/R

# Configure AWS credentials (will be provided at runtime)
ENV AWS_DEFAULT_REGION=us-east-1

# Install renv packages
RUN Rscript -e "renv::restore()" || true

# Set entrypoint
ENTRYPOINT ["/bin/bash"]
CMD ["-c", "Rscript scripts/run_pipeline.R"]
