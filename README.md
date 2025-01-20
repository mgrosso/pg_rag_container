# a pg docker providing built from scratch PostgresQL and vector plugins

The aim here is to provide a container that is compatible with https://github.com/docker-library/postgres.git and which leverages it's entrypoint scripts, but which allows full control over the build process and which has no dependencies on distribution provide postgresql packages. By default, it will build and install all extensions in the postgresql git external directory, as well as `pg_vector` and `pg_vectorscale`. `citus` is a TODO item.

## why?

If you want control over your PostgresQL compile flags, or want specific versions of pgvector or pgvectorscale, or want to add other postgresql extensions, then this Dockerfile is a good starting point.

I found that when testing alternate git branches of postgresql, pgvector, or pgvectorcscale then the standard postgresql Dockerfile was difficult to extend and I ended up with compilation notes or scripts that were very specific to the host OS, which varied from laptop to laptop and AMI to AMI.

## related work

### PostgresQL obviously
PostgresQL git and the official docker container from which we copy several scripts for compatibility:
- https://git.postgresql.org/git/postgresql.git
- https://github.com/docker-library/postgres.git


### pgvector
- https://github.com/pgvector/pgvector
- https://hub.docker.com/r/pgvector/pgvector

### pgvectorscale

the recommended container for pgvecgtorscale is the timescaledb-ha container.

- https://github.com/timescale/pgvectorscale
- https://hub.docker.com/r/timescale/timescaledb-ha
