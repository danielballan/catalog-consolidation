-- Fresh Tree Migration Script: Copy from 'src' to 'dst' database
-- Based on actual schema:
-- nodes: id, parent, key, structure_family, metadata, specs, access_blob, time_created, time_updated  
-- data_sources: id, node_id, structure_id, mimetype, parameters, management, structure_family, time_created, time_updated
-- nodes_closure: ancestor, descendant, depth

-- =============================================================================
-- CONFIGURATION - Change this to your desired graft point
-- =============================================================================
-- The node ID in dst database where src tree will be attached
\set graft_parent_id 1

-- =============================================================================
-- SETUP FOREIGN DATA WRAPPER
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

DROP SERVER IF EXISTS src_server CASCADE;

CREATE SERVER src_server
FOREIGN DATA WRAPPER postgres_fdw
OPTIONS (host 'localhost', port '5432', dbname 'src');

CREATE USER MAPPING FOR postgres
SERVER src_server
OPTIONS (user 'postgres', password 'secret');

DROP SCHEMA IF EXISTS foreign_src CASCADE;
CREATE SCHEMA foreign_src;

IMPORT FOREIGN SCHEMA public 
FROM SERVER src_server 
INTO foreign_src;

-- =============================================================================
-- CALCULATE ID OFFSETS
-- =============================================================================
DO $$
DECLARE
    max_node_id BIGINT;
    max_data_source_id BIGINT;
    max_asset_id BIGINT;
    max_revision_id BIGINT;
BEGIN
    SELECT COALESCE(MAX(id), 0) INTO max_node_id FROM nodes;
    SELECT COALESCE(MAX(id), 0) INTO max_data_source_id FROM data_sources;
    SELECT COALESCE(MAX(id), 0) INTO max_asset_id FROM assets;
    SELECT COALESCE(MAX(id), 0) INTO max_revision_id FROM revisions;

    RAISE NOTICE 'Max IDs in dst - nodes: %, data_sources: %, assets: %, revisions: %',
                 max_node_id, max_data_source_id, max_asset_id, max_revision_id;

    PERFORM set_config('migration.node_offset', max_node_id::text, false);
    PERFORM set_config('migration.data_source_offset', max_data_source_id::text, false);
    PERFORM set_config('migration.asset_offset', max_asset_id::text, false);
    PERFORM set_config('migration.revision_offset', max_revision_id::text, false);
    PERFORM set_config('migration.graft_parent', :'graft_parent_id', false);
END $$;

-- =============================================================================
-- CREATE ID MAPPING TABLES
-- =============================================================================
DROP TABLE IF EXISTS node_mapping;
CREATE TEMPORARY TABLE node_mapping (
    old_id BIGINT PRIMARY KEY,
    new_id BIGINT UNIQUE,
    new_parent BIGINT
);

DROP TABLE IF EXISTS data_source_mapping;  
CREATE TEMPORARY TABLE data_source_mapping (
    old_id BIGINT PRIMARY KEY,
    new_id BIGINT UNIQUE
);

DROP TABLE IF EXISTS asset_mapping;
CREATE TEMPORARY TABLE asset_mapping (
    old_id BIGINT PRIMARY KEY,
    new_id BIGINT UNIQUE
);

DROP TABLE IF EXISTS revision_mapping;
CREATE TEMPORARY TABLE revision_mapping (
    old_id BIGINT PRIMARY KEY,
    new_id BIGINT UNIQUE
);

-- =============================================================================
-- BUILD MAPPINGS
-- =============================================================================

-- Build node mappings
INSERT INTO node_mapping (old_id, new_id, new_parent)
SELECT 
    n.id as old_id,
    n.id + current_setting('migration.node_offset')::BIGINT as new_id,
    CASE 
        WHEN n.parent = 0 THEN current_setting('migration.graft_parent')::BIGINT  -- Children of root get graft parent
        ELSE n.parent + current_setting('migration.node_offset')::BIGINT          -- Others get mapped parent
    END as new_parent
FROM foreign_src.nodes n
WHERE n.parent IS NOT NULL;  -- EXCLUDE root node (parent IS NULL)

-- Build data_source mappings
INSERT INTO data_source_mapping (old_id, new_id)
SELECT 
    ds.id,
    ds.id + current_setting('migration.data_source_offset')::BIGINT
FROM foreign_src.data_sources ds;

-- Build asset mappings (only assets used by migrated data_sources)
INSERT INTO asset_mapping (old_id, new_id)
SELECT DISTINCT
    a.id,
    a.id + current_setting('migration.asset_offset')::BIGINT
FROM foreign_src.assets a
JOIN foreign_src.data_source_asset_association dsaa ON a.id = dsaa.asset_id
JOIN data_source_mapping dsm ON dsaa.data_source_id = dsm.old_id;

-- Build revision mappings (only revisions for migrated nodes)
INSERT INTO revision_mapping (old_id, new_id)
SELECT
    r.id,
    r.id + current_setting('migration.revision_offset')::BIGINT
FROM foreign_src.revisions r
JOIN node_mapping nm ON r.node_id = nm.old_id;

-- =============================================================================
-- SHOW MAPPING SUMMARY
-- =============================================================================
DO $$
DECLARE
    node_count INT;
    ds_count INT;
    root_count INT;
BEGIN
    SELECT COUNT(*) INTO node_count FROM node_mapping;
    SELECT COUNT(*) INTO ds_count FROM data_source_mapping;
    SELECT COUNT(*) INTO root_count FROM node_mapping WHERE new_parent = current_setting('migration.graft_parent')::BIGINT;
    
    RAISE NOTICE 'Will migrate % nodes (% direct children of root) and % data_sources', node_count, root_count, ds_count;
END $$;

-- =============================================================================
-- VALIDATE GRAFT PARENT EXISTS
-- =============================================================================
DO $$
DECLARE
    graft_id BIGINT := current_setting('migration.graft_parent')::BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = graft_id) THEN
        RAISE EXCEPTION 'Graft parent node % does not exist in dst database', graft_id;
    END IF;
    RAISE NOTICE 'Validated graft parent node %', graft_id;
END $$;

-- =============================================================================
-- MIGRATION TRANSACTION
-- =============================================================================
BEGIN;

DO $$
BEGIN 
    RAISE NOTICE 'Starting migration...'; 
END $$;

-- Migrate structures.
-- The id is a content hash, so no need to compare content.
INSERT INTO structures (id, structure)
SELECT
    src_s.id,
    src_s.structure
FROM foreign_src.structures src_s
ON CONFLICT (id) DO NOTHING;

DO $$
DECLARE
    inserted_count INT;
BEGIN
    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RAISE NOTICE 'Inserted % structures', inserted_count;
END $$;

-- Migrate nodes in hierarchical order
WITH RECURSIVE tree_order AS (
    -- Start with children of the original root (those being grafted)
    SELECT 
        nm.old_id, nm.new_id, nm.new_parent, 1 as level
    FROM node_mapping nm
    WHERE nm.new_parent = current_setting('migration.graft_parent')::BIGINT
    
    UNION ALL
    
    -- Add children level by level  
    SELECT 
        nm.old_id, nm.new_id, nm.new_parent, parent_order.level + 1
    FROM node_mapping nm
    JOIN foreign_src.nodes src_n ON src_n.id = nm.old_id  
    JOIN tree_order parent_order ON src_n.parent = parent_order.old_id
)
INSERT INTO nodes (id, parent, key, structure_family, metadata, specs, access_blob, time_created, time_updated)
SELECT 
    nm.new_id,
    nm.new_parent,
    src_n.key,
    src_n.structure_family,
    src_n.metadata,
    src_n.specs,
    src_n.access_blob,
    src_n.time_created,
    src_n.time_updated
FROM tree_order ord
JOIN node_mapping nm ON ord.old_id = nm.old_id
JOIN foreign_src.nodes src_n ON src_n.id = nm.old_id
ORDER BY ord.level, nm.new_id;

DO $$
DECLARE inserted_nodes INT;
BEGIN 
    GET DIAGNOSTICS inserted_nodes = ROW_COUNT;
    RAISE NOTICE 'Inserted % nodes', inserted_nodes;
END $$;

-- Migrate data_sources
INSERT INTO data_sources (id, node_id, structure_id, mimetype, parameters, management, structure_family, time_created, time_updated)
SELECT 
    dsm.new_id,
    nm.new_id,
    src_ds.structure_id,
    src_ds.mimetype,
    src_ds.parameters,
    src_ds.management,
    src_ds.structure_family,
    src_ds.time_created,
    src_ds.time_updated
FROM foreign_src.data_sources src_ds
JOIN data_source_mapping dsm ON src_ds.id = dsm.old_id
JOIN node_mapping nm ON src_ds.node_id = nm.old_id;

DO $$
DECLARE 
    ds_count INT;
BEGIN 
    SELECT COUNT(*) INTO ds_count FROM data_source_mapping;
    RAISE NOTICE 'Inserted % data_sources', ds_count;
END $$;

-- Migrate assets
INSERT INTO assets (id, data_uri, is_directory, hash_type, hash_content, size, time_created, time_updated)
SELECT
    am.new_id,
    src_a.data_uri,
    src_a.is_directory,
    src_a.hash_type,
    src_a.hash_content,
    src_a.size,
    src_a.time_created,
    src_a.time_updated
FROM foreign_src.assets src_a
JOIN asset_mapping am ON src_a.id = am.old_id;

-- Migrate data_source_asset_association
INSERT INTO data_source_asset_association (data_source_id, asset_id, parameter, num)
SELECT
    dsm.new_id,
    am.new_id,
    src_dsaa.parameter,
    src_dsaa.num
FROM foreign_src.data_source_asset_association src_dsaa
JOIN data_source_mapping dsm ON src_dsaa.data_source_id = dsm.old_id
JOIN asset_mapping am ON src_dsaa.asset_id = am.old_id;

-- Migrate revisions
INSERT INTO revisions (id, node_id, revision_number, metadata, specs, access_blob, time_created, time_updated)
SELECT
    rm.new_id,
    nm.new_id,
    src_r.revision_number,
    src_r.metadata,
    src_r.specs,
    src_r.access_blob,
    src_r.time_created,
    src_r.time_updated
FROM foreign_src.revisions src_r
JOIN revision_mapping rm ON src_r.id = rm.old_id
JOIN node_mapping nm ON src_r.node_id = nm.old_id;

-- =============================================================================
-- VALIDATION
-- =============================================================================
DO $$
DECLARE
    orphaned_nodes INT;
    orphaned_ds INT;
    missing_closure INT;
BEGIN
    -- Check for orphaned nodes
    SELECT COUNT(*) INTO orphaned_nodes
    FROM nodes n
    LEFT JOIN nodes p ON n.parent = p.id
    WHERE n.id IN (SELECT new_id FROM node_mapping)
      AND p.id IS NULL
      AND n.parent != current_setting('migration.graft_parent')::BIGINT;
      
    -- Check for orphaned data_sources
    SELECT COUNT(*) INTO orphaned_ds  
    FROM data_sources ds
    LEFT JOIN nodes n ON ds.node_id = n.id
    WHERE ds.id IN (SELECT new_id FROM data_source_mapping)
      AND n.id IS NULL;
      
    -- Check closure table
    SELECT COUNT(*) INTO missing_closure
    FROM node_mapping nm
    LEFT JOIN nodes_closure nc ON nc.descendant = nm.new_id
    WHERE nc.descendant IS NULL;
    
    IF orphaned_nodes > 0 THEN
        RAISE EXCEPTION 'Found % orphaned nodes', orphaned_nodes;
    END IF;
    
    IF orphaned_ds > 0 THEN  
        RAISE EXCEPTION 'Found % orphaned data_sources', orphaned_ds;
    END IF;
    
    IF missing_closure > 0 THEN
        RAISE WARNING 'Found % nodes missing from closure table', missing_closure;
    ELSE
        RAISE NOTICE 'Closure table validation passed';
    END IF;
    
    RAISE NOTICE 'Validation completed successfully';
END $$;

-- =============================================================================
-- FINAL SUMMARY  
-- =============================================================================
DO $$
DECLARE
    node_count INT;
    ds_count INT;
    max_depth INT;
BEGIN
    SELECT COUNT(*) INTO node_count FROM node_mapping;
    SELECT COUNT(*) INTO ds_count FROM data_source_mapping;
    
    SELECT MAX(depth) INTO max_depth
    FROM nodes_closure nc
    JOIN node_mapping nm ON nc.descendant = nm.new_id  
    WHERE nc.ancestor = current_setting('migration.graft_parent')::BIGINT;
    
    RAISE NOTICE '=== MIGRATION COMPLETED ===';
    RAISE NOTICE 'Migrated % nodes and % data_sources', node_count, ds_count;
    RAISE NOTICE 'Tree grafted under node % with depth %', 
                 current_setting('migration.graft_parent')::BIGINT, 
                 COALESCE(max_depth, 0);
    RAISE NOTICE 'Node ID range: % to %',
                 (SELECT MIN(new_id) FROM node_mapping),
                 (SELECT MAX(new_id) FROM node_mapping);
END $$;

COMMIT;

DO $$
BEGIN 
    RAISE NOTICE 'Migration committed successfully!'; 
END $$;
