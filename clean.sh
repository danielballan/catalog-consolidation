POSTGRESQL_URI=postgresql://postgres:secret@localhost:5432 
psql ${POSTGRESQL_URI} -f clean.sql
rm -rf /tmp/catalog-consolidation-data
