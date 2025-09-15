from tiled.server.app import build_app
from tiled.catalog import from_uri
from tiled.client import Context, from_context
import logging
import sys

# Create and setup a logger
logger = logging.getLogger()
logger.setLevel(logging.INFO)
handler = logging.StreamHandler(sys.stdout)
logger.addHandler(handler)

catalog_dst = from_uri(
    "postgresql://postgres:secret@localhost:5432/catalog_dst",
    writable_storage={"filesystem": "file://localhost/tmp/catalog-consolidation-data",
                      "sql": "postgresql://postgres:secret@localhost:5432/storage"}
)
app = build_app(catalog_dst)

def recursve_read(client):
    for name, child in client.items():
        logger.info(f"Reading node: {name}")
        if child.structure_family == "container":
            recursve_read(child)
        else:
            result = child.read()
            logger.info(f">            {result}")

with Context.from_app(app) as context:
    client = from_context(context)
    recursve_read(client)
