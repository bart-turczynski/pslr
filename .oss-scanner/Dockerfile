# Build for Anthropic's OSS Scanner (https://github.com/anthropics/oss-scanner).
# The scanner builds this with the repository as the context, then audits the
# image with no network, so everything the tests need is installed here.
FROM rocker/r-ver:4.6.1

# Debug info and frame pointers for the C/C++ sources, so gdb, valgrind and
# sanitizer output point at source lines.
RUN mkdir -p /root/.R && for v in CFLAGS CXXFLAGS CXX11FLAGS CXX14FLAGS CXX17FLAGS CXX20FLAGS; do \
      echo "$v = -g -O1 -fno-omit-frame-pointer" >> /root/.R/Makevars; done

# scanner contract: the checkout lives inside the image, at /src
COPY . /src
WORKDIR /src

# Imports and Suggests, with the system libraries they need.
RUN Rscript -e 'install.packages("pak")' \
 && Rscript -e 'pak::local_install_deps("/src", dependencies = TRUE, upgrade = FALSE)'

RUN R CMD INSTALL /src

# Smoke-test the image; failures are logged, not fatal.
RUN Rscript -e 'testthat::test_local("/src", stop_on_failure = TRUE)' \
 || echo "WARNING: tests reported failures"
