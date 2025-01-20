# Base stage: Install dependencies and postgresql user, group, and dirs
FROM debian:bookworm-20241223-slim AS runtime-essentials
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        libreadline-dev \
        zlib1g-dev \
        libssl-dev \
        libicu-dev \
        gnupg \
        libnss-wrapper \
        zstd \
        xz-utils \
        ca-certificates

RUN mkdir -p /usr/src/
RUN mkdir -p /usr/local/

FROM runtime-essentials AS build-base
# Install build requirements
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        git \
        curl \
        wget \
        bison \
        flex \
        lsb-release

# we can isolate the pgdocker git from the rest because we're just copying a couple
# files and there are no real dependencies.
FROM build-base AS clone-pgdocker-source
ARG PGDOCKER_TAG=32b6fcdda7f52830f42dd695e2dc2f739581756b
ARG PGDOCKER_GIT=https://github.com/docker-library/postgres.git
LABEL PGDOCKER_TAG="${PGDOCKER_TAG}"
WORKDIR /usr/src
RUN git clone ${PGDOCKER_GIT} pgdocker && cd pgdocker && git checkout ${PGDOCKER_TAG} && touch -c -d "2025-01-01 00:00:00" docker-ensure-initdb.sh docker-entrypoint.sh

# Stage 1: Clone the sources. Because pgvector depends on postgres source, and pgvectorscale depends on them both, these three are all cloned into one build image.
FROM build-base AS clone-the-source
# Set build arguments for Git tags
ARG POSTGRES_TAG=REL_17_2
ARG PGVECTOR_TAG=v0.8.0
ARG PGVECTORSCALE_TAG=0.5.1
# sometimes one has to swap out official locations for ones own
# enterprise ECR URI to avoid rate limits from CI. 
ARG POSTGRES_GIT=https://git.postgresql.org/git/postgresql.git
ARG PGVECTOR_GIT=https://github.com/pgvector/pgvector.git
ARG PGVECTORSCALE_GIT=https://github.com/timescale/pgvectorscale.git
# we export these build arguments as LABELS to allow CI builds to pull
# previously cached versions of them.
LABEL POSTGRES_TAG="${POSTGRES_TAG}"
LABEL PGVECTOR_TAG="${PGVECTOR_TAG}"
LABEL PGVECTORSCALE_TAG="${PGVECTORSCALE_TAG}"

# sometimes one has to swap out official locations for ones own
WORKDIR /usr/src

# Clone PostgreSQL repository
RUN git clone --depth 1 --branch ${POSTGRES_TAG} ${POSTGRES_GIT}
RUN git clone --depth 1 --branch ${PGVECTOR_TAG} ${PGVECTOR_GIT}
RUN git clone --depth 1 --branch ${PGVECTORSCALE_TAG} ${PGVECTORSCALE_GIT}

FROM clone-the-source AS build-from-source
ARG RUST_VERSION=1.83.0
ENV RUST_VERSION=$RUST_VERSION
LABEL RUST_VERSION $RUST_VERSION
WORKDIR /usr/src

RUN cd /usr/src/postgresql && \
    ./configure --prefix=/usr/local && \
    make -j 3 && \
    make install

RUN cd /usr/src/pgvector && \
    make && \
    make install

# we can't use the rustc from debian slim; it's ancient and doesn't work even
# for the first couple commands, and any resulting bugs aren't things the
# pgvectorscale team would want to waste time on.
#
# so, we're choosing an arbitrary version of rustup to trust.
# see https://rust-lang.github.io/rustup/installation/other.html
# and https://github.com/rust-lang/rustup
#
# TODO: bump periodically, get sick of that, and pick a better way while no
# doubt continuing to stubbornly refuse to just do `curl sh.rustup.rs | sh`
# in a containerfile, because there are rules.
ENV CARGO_HOME=/usr/local
ENV RUSTUP_HOME=/usr/local
ENV PGRX_HOME=/usr/local
RUN git clone https://github.com/rust-lang/rustup && \
        cd ./rustup/ && \
        ./rustup-init.sh -y --default-toolchain $RUST_VERSION

RUN apt-get update && apt-get install -y libclang-dev
# The installed pgrx must match that specified in the Cargo.toml of the pgvectorscale
# repository which may not be the most recent default version. We specify the
# dependency here for now, although in the long run we could scrape it out of the
# Cargo.toml. Because the correct value of this is determined by the pgvectorscale
# version, we don't add it as a separate label.
RUN cargo install --locked cargo-pgrx --version 0.12.5
WORKDIR /usr/src/pgvectorscale/pgvectorscale

RUN cargo pgrx init --pg17 pg_config
ENV RUSTFLAGS="-C target-feature=+avx2,+fma"
RUN cargo pgrx install --release
# we want to minimize cache misses and keep builds as repeatable as possible
# so the directories we're going to copy get set to a static create and modify time.
RUN find /usr/local/bin/ | xargs touch -c -d "2025-01-01 00:00:00"
RUN find /usr/local/include/ | xargs touch -c -d "2025-01-01 00:00:00"
RUN find /usr/local/lib/ | xargs touch -c -d "2025-01-01 00:00:00"
RUN find /usr/local/share/ | xargs touch -c -d "2025-01-01 00:00:00"

FROM runtime-essentials
ARG POSTGRES_USER_UID=70
ARG POSTGRES_USER_GID=70
ARG POSTGRES_USER_HOME=/var/lib/postgresql

# only copy the 4 subdirectories we need so we don't have spurious file
# differences triggering large and slow copies.
COPY --from=build-from-source /usr/local/bin/ /usr/local/bin/
COPY --from=build-from-source /usr/local/include/ /usr/local/include/
COPY --from=build-from-source /usr/local/lib/ /usr/local/lib/
COPY --from=build-from-source /usr/local/share/ /usr/local/share/
# 3 files from 2 source files. you could replace the third copy with `RUN ln ...`.
COPY --from=clone-pgdocker-source /usr/src/pgdocker/docker-entrypoint.sh /usr/local/bin/
COPY --from=clone-pgdocker-source /usr/src/pgdocker/docker-ensure-initdb.sh /usr/local/bin/
COPY --from=clone-pgdocker-source /usr/src/pgdocker/docker-ensure-initdb.sh /usr/local/bin/docker-enforce-initdb.sh

# RUN    apt-get clean && rm -rf /var/lib/apt/lists/*

# # Create PostgreSQL data directory and set permissions
RUN groupadd -r postgres --gid=$POSTGRES_USER_GID && \
        useradd -r -g postgres --uid=$POSTGRES_USER_UID \
          --home-dir=$POSTGRES_USER_HOME --shell=/bin/bash postgres && \
        install --verbose --directory --owner postgres --group postgres \
          --mode 1777 $POSTGRES_USER_HOME
ENV PGDATA /var/lib/postgresql/data
VOLUME /var/lib/postgresql/data
RUN install --verbose --directory --owner postgres --group postgres --mode 0700 /var/lib/postgresql/data
RUN install --verbose --directory --owner postgres --group postgres --mode 0700 /var/run/postgresql
RUN install --verbose --directory --owner postgres --group postgres --mode 0700 /docker-entrypoint-initdb.d
USER postgres
STOPSIGNAL SIGINT
EXPOSE 5432
ENTRYPOINT ["docker-entrypoint.sh"]
