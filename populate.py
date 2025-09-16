from tiled.server.app import build_app
from tiled.catalog import from_uri
from tiled.client import Context, from_context
import logging
import sys
import h5py

from bluesky import RunEngine
from bluesky.callbacks.tiled_writer import TiledWriter
import logging
import bluesky.plans as bp
import numpy as np
from ophyd.sim import det
from ophyd.sim import hw
from pathlib import Path

from tiled.structures.core import StructureFamily, Spec
from tiled.structures.data_source import Asset, DataSource, Management

# Create and setup a logger
logger = logging.getLogger()
logger.setLevel(logging.INFO)
handler = logging.StreamHandler(sys.stdout)
logger.addHandler(handler)

# Initialize the catalog
catalog_src = from_uri(
    "postgresql://postgres:secret@localhost:5432/catalog_src",
    writable_storage={"filesystem": "file://localhost/tmp/catalog-consolidation-data",
                      "sql": "postgresql://postgres:secret@localhost:5432/storage"}
)
logger.info(f"Initialized Tiled catalog {catalog_src}")

# Create some external HDF5 files to reference
hdf5_data_sources = []
for i in range(3):
    file_path = Path(f"/tmp/catalog-consolidation-data/test_{i}.h5")
    with h5py.File(file_path, "w") as file:
        z = file.create_group("z")
        y = z.create_group("y")
        y.create_dataset("x", data=np.array([1, 2, 3]))
    asset = Asset(
            data_uri=f"file://localhost/{file_path}",
            is_directory=False,
            parameter="data_uris",
            num=0,
        )
    data_source = DataSource(
        mimetype="application/x-hdf5",
        assets=[asset],
        structure_family=StructureFamily.container,
        structure=None,
        parameters={"dataset": "z/y"},
        management=Management.external,
    )
    hdf5_data_sources.append(data_source)

# 1. Initialize the source catalog
with Context.from_app(build_app(catalog_src)) as context:
    RE = RunEngine()
    client = from_context(context)
    tw = TiledWriter(client)
    RE.subscribe(tw)

    # Some data from Bluesky
    for i in range(3):
        logger.info(f"Starting iteration {i}")
        ##### Internal Data Collection #####
        uid, = RE(bp.count([det], 3))
        
        #### External Data Collection #####
        Path("/tmp/catalog-consolidation-data").mkdir(parents=True, exist_ok=True)
        uid, = RE(bp.count([hw(save_path="/tmp/catalog-consolidation-data").img], 3))

    # Some hierarchical data
    a = client.create_container("a")
    b = a.create_container("b")
    c = b.create_container("c")
    d = c.write_array([1, 2, 3], key="d")
    a.update_metadata({"color": "blue"})

    # External HDF5 files
    a.new(
        structure_family=StructureFamily.container,
        data_sources=[hdf5_data_sources[0]],
        key="hdf5_0",
    )
    a.new(
        structure_family=StructureFamily.container,
        data_sources=[hdf5_data_sources[1]],
        key="hdf5_1",
    )


# 2. Initialize the destination catalog
catalog_dst = from_uri(
    "postgresql://postgres:secret@localhost:5432/catalog_dst",
    writable_storage={"filesystem": "file://localhost/tmp/catalog-consolidation-data",
                      "sql": "postgresql://postgres:secret@localhost:5432/storage"}
)
logger.info(f"Initialized Tiled catalog {catalog_dst}")

with Context.from_app(build_app(catalog_dst)) as context:
    RE = RunEngine()
    client = from_context(context)
    tw = TiledWriter(client)
    RE.subscribe(tw)

    a = client.create_container("a_dst")
    a.update_metadata({"color": "red"})

    # External HDF5 files
    a.new(
        structure_family=StructureFamily.container,
        data_sources=[hdf5_data_sources[0]],
        key="hdf5_0",
    )
    a.new(
        structure_family=StructureFamily.container,
        data_sources=[hdf5_data_sources[2]],
        key="hdf5_2",
    )

    for i in range(2):
        logger.info(f"Starting iteration {i}")
        ##### Internal Data Collection #####
        uid, = RE(bp.count([det], 3))
        
        #### External Data Collection #####
        Path("/tmp/catalog-consolidation-data").mkdir(parents=True, exist_ok=True)
        uid, = RE(bp.count([hw(save_path="/tmp/catalog-consolidation-data").img], 3))
