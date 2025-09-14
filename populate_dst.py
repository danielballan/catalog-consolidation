from tiled.server.app import build_app
from tiled.catalog import from_uri
from tiled.client import Context, from_context


catalog = from_uri(
    "postgresql://postgres:secret@localhost:5432/dst",
    writable_storage=["file://localhost/tmp/catalog-consolidation-data"]
)
app = build_app(catalog)
with Context.from_app(app) as context:
    client = from_context(context)
    x = client.create_container("x")
