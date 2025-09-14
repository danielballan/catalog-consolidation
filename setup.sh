POSTGRESQL_URI=postgresql://postgres:secret@localhost:5432 
psql ${POSTGRESQL_URI} -f setup.sql
tiled catalog init ${POSTGRESQL_URI}/src
tiled catalog init ${POSTGRESQL_URI}/dst
mkdir /tmp/catalog-consolidation-data
python populate_src.py
python populate_dst.py
