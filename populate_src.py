from tiled.server.app import build_app
from tiled.catalog import from_uri
from tiled.client import Context, from_context


catalog = from_uri(
    "postgresql://postgres:secret@localhost:5432/src",
    writable_storage=["file://localhost/tmp/catalog-consolidation-data"]
)
app = build_app(catalog)
with Context.from_app(app) as context:
    client = from_context(context)
    a = client.create_container("a")
    b = a.create_container("b")
    c = b.create_container("c")
    d = c.write_array([1, 2, 3], key="d")
